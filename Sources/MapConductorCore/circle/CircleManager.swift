import Foundation

public protocol CircleManagerProtocol {
    associatedtype ActualCircle

    func registerEntity(_ entity: CircleEntity<ActualCircle>)
    func removeEntity(_ id: String) -> CircleEntity<ActualCircle>?
    func getEntity(_ id: String) -> CircleEntity<ActualCircle>?
    func hasEntity(_ id: String) -> Bool
    func allEntities() -> [CircleEntity<ActualCircle>]
    func clear()
    func find(position: GeoPointProtocol) -> CircleEntity<ActualCircle>?
}

public final class CircleManager<ActualCircle>: CircleManagerProtocol {
    private var entities: [String: CircleEntity<ActualCircle>] = [:]
    private var tiledSource: CircleTiler?
    private var destroyed = false
    private let lock = NSLock()

    public init() {}

    func setTiledSource(_ source: CircleTiler?) {
        lock.lock(); tiledSource = source; lock.unlock()
    }

    private func checkNotDestroyedLocked() {
        // In-flight async work (e.g. Combine subscriptions delivering through
        // a Task) can legitimately arrive just after destroy() during provider
        // switches. destroy() clears all state, so post-destroy access is a
        // harmless no-op on empty state — log instead of crashing.
        if destroyed {
            NSLog("[MapConductor] CircleManager accessed after destroy (ignored)")
        }
    }

    public func registerEntity(_ entity: CircleEntity<ActualCircle>) {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        if entity.circle == nil, tiledSource?.isTiled(entity.state.id) == true {
            entities[entity.state.id] = nil
            return
        }
        entities[entity.state.id] = entity
    }

    public func removeEntity(_ id: String) -> CircleEntity<ActualCircle>? {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        if let entity = entities.removeValue(forKey: id) { return entity }
        guard let source = tiledSource, let state = source.state(id) else { return nil }
        source.remove(id)
        return CircleEntity(circle: nil, state: state)
    }

    public func getEntity(_ id: String) -> CircleEntity<ActualCircle>? {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        return entities[id] ?? tiledSource?.state(id).map { CircleEntity(circle: nil, state: $0) }
    }

    public func hasEntity(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        return entities[id] != nil || tiledSource?.isTiled(id) == true
    }

    public func allEntities() -> [CircleEntity<ActualCircle>] {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        var result = Array(entities.values)
        tiledSource?.visitStates { state in
            if entities[state.id] == nil { result.append(CircleEntity(circle: nil, state: state)) }
        }
        return result
    }

    /// The circles the map SDK draws (each has a native `circle`), without the
    /// tiled ones ``allEntities()`` also lists. What a renderer that redraws
    /// from the manager reads: listing the tiled ones makes an entity per tiled
    /// circle, seconds at hundreds of thousands.
    @_spi(MapConductorDriver)
    public func nativeEntities() -> [CircleEntity<ActualCircle>] {
        lock.lock(); defer { lock.unlock() }
        return Array(entities.values)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        entities.removeAll()
        tiledSource = nil
    }

    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        if destroyed { return }
        destroyed = true
        entities.removeAll()
        tiledSource = nil
    }

    public var isDestroyed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return destroyed
    }

    /// The circle a tap at `position` hits, without the outline (the camera is unknown).
    public func find(position: GeoPointProtocol) -> CircleEntity<ActualCircle>? {
        find(position: position, cameraPosition: nil)
    }

    /// The circle a tap at `position` hits, tiled or drawn natively alike.
    ///
    /// A clickable circle is hit within its radius plus half its outline (the
    /// outline is drawn centred on the edge; its width is on screen, turned
    /// into metres at the camera's zoom, and taken as 0 without a camera). No
    /// finger tolerance is added: among small circles close together it would
    /// pick the neighbour. Of several, the highest effective zIndex wins (a
    /// circle without one gets the automatic zIndex it is drawn with), then the
    /// one whose centre is closest. js-sdk-core's and android-sdk-core's
    /// `CircleManager.find` decide the same way.
    public func find(position: GeoPointProtocol, cameraPosition: MapCameraPosition?) -> CircleEntity<ActualCircle>? {
        let metersPerPoint = cameraPosition.map {
            calculateMetersPerPixel(latitude: position.latitude, zoom: $0.zoom)
        } ?? 0
        // The distance on the sphere is at least the difference of latitudes.
        let metersPerDegree = Earth.radiusMeters * .pi / 180
        var best: CircleEntity<ActualCircle>?
        var bestState: CircleState?
        var bestZIndex = Int.min
        var bestDistance = Double.infinity
        lock.lock()
        checkNotDestroyedLocked()
        let candidates = Array(entities.values)
        let source = tiledSource
        let nativeIds = Set(entities.keys)
        lock.unlock()
        func consider(_ state: CircleState, hit: CircleHitValues, entity: CircleEntity<ActualCircle>?) {
            guard hit.clickable else { return }
            let reach = hit.radiusMeters + metersPerPoint * max(hit.strokeWidth, 0) / 2
            guard reach.isFinite, reach >= 0 else { return }
            if abs(hit.latitude - position.latitude) * metersPerDegree > reach * (1 + 1e-9) + 1e-6 { return }
            let distance = haversineDistance(
                fromLatitude: hit.latitude, fromLongitude: hit.longitude,
                toLatitude: position.latitude, toLongitude: position.longitude
            )
            guard distance <= reach else { return }
            if hit.zIndex > bestZIndex || (hit.zIndex == bestZIndex && distance < bestDistance) {
                best = entity
                bestState = state
                bestZIndex = hit.zIndex
                bestDistance = distance
            }
        }
        for entity in candidates { consider(entity.state, hit: entity.hit, entity: entity) }
        // Tiled circles: only those near the tap, found through the tiles' index.
        // Reading every state here took over a second at 700k circles.
        for state in source?.states(near: position.latitude, position.longitude, metersPerPoint: metersPerPoint) ?? []
        where !nativeIds.contains(state.id) {
            consider(state, hit: CircleHitValues(state), entity: nil)
        }
        return best ?? bestState.map { CircleEntity(circle: nil, state: $0) }
    }

    private func haversineDistance(
        fromLatitude: Double, fromLongitude: Double, toLatitude: Double, toLongitude: Double
    ) -> Double {
        let lat1 = deg2rad(fromLatitude)
        let lon1 = deg2rad(fromLongitude)
        let lat2 = deg2rad(toLatitude)
        let lon2 = deg2rad(toLongitude)

        let dLat = lat2 - lat1
        let dLon = lon2 - lon1

        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return Earth.radiusMeters * c
    }

    private func deg2rad(_ deg: Double) -> Double {
        deg * Double.pi / 180.0
    }
}
