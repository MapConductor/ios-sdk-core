import Foundation
import UIKit

/**
 The polygons of one map that are drawn as raster tiles, and their route on the
 local tile server.

 Provider-independent: a provider decides which polygons to tile
 (``PolygonTilingOptions/shouldUseTiles(polygonCount:vertexCount:)``,
 ``canTile(_:)``), hands them to ``setPolygons(_:)``, and shows the returned URL
 template as a raster layer. In-place changes go through ``update(_:)``; each
 batch ends in a new template (the version in it is what makes the map ask
 again), reported to ``onTemplateChanged``. Tiles the change did not touch are
 still cached by the renderer and come back without being redrawn.

 The iOS counterpart of js-sdk-core's `PolygonTileSet`. There the polygons cross
 to a service worker as Encoded Polylines; here the renderer is in the same
 process and takes them as they are.
 */
@_spi(MapConductorDriver)
public final class PolygonTileSet {
    /// In-place changes arriving within this window become one new template.
    static let updateCoalesceMs = 16

    public let routeId = "polygons-\(UUID().uuidString.prefix(8).lowercased())"
    public let tileSize = 256
    /// Called on the main thread with the template after a batch of in-place changes.
    public var onTemplateChanged: ((String) -> Void)?

    let renderer: PolygonTileRenderer
    private let lock = NSLock()
    private var indexById: [String: Int] = [:]
    private var version = 0
    private var registered = false
    private var pending: [String: PolygonState] = [:]
    private var pendingRemovals: [Int] = []
    private var flushScheduled = false

    public init(pixelRatio: Int = max(1, Int(UIScreen.main.scale.rounded()))) {
        renderer = PolygonTileRenderer(tileSize: 256, pixelRatio: pixelRatio)
    }

    deinit {
        if registered { TileServerRegistry.get().unregister(routeId: routeId) }
    }

    /// Whether a polygon can be drawn in a tile. Geodesic edges are curves the
    /// tile does not trace, and a ring spanning half the world or more crosses
    /// the antimeridian; the map SDK draws both.
    public static func canTile(_ state: PolygonState) -> Bool {
        if state.geodesic { return false }
        let points = state.points
        if points.count < 3 { return false }
        var minLng = Double.infinity, maxLng = -Double.infinity
        for p in points {
            minLng = min(minLng, p.longitude)
            maxLng = max(maxLng, p.longitude)
        }
        return maxLng - minLng < 180
    }

    public static func vertexCount(_ states: [PolygonState]) -> Int {
        var n = 0
        for state in states {
            n += state.points.count
            for hole in state.holes { n += hole.count }
        }
        return n
    }

    /// Registers `states` (replacing whatever was registered) and returns the URL
    /// template of their tiles. The geometry is read and projected off the
    /// calling thread.
    public func setPolygons(_ states: [PolygonState]) async -> String? {
        cancelPending()
        let renderer = self.renderer
        let indexById = await Task.detached(priority: .userInitiated) { () -> [String: Int] in
            // Draw order is list order: zIndex, then the order given. Each zIndex
            // is read once: a state's properties are not free to read, and a
            // sort reads them n log n times.
            let zIndex = states.map(\.zIndex)
            let ordered = states.indices
                .sorted { zIndex[$0] != zIndex[$1] ? zIndex[$0] < zIndex[$1] : $0 < $1 }
                .map { states[$0] }
            var indexById: [String: Int] = [:]
            indexById.reserveCapacity(ordered.count)
            var shapes: [PolygonTileShape] = []
            shapes.reserveCapacity(ordered.count)
            for (i, state) in ordered.enumerated() {
                indexById[state.id] = i
                shapes.append(PolygonTileShape(state: state))
            }
            renderer.setPolygons(shapes)
            return indexById
        }.value

        let server = TileServerRegistry.get()
        server.register(routeId: routeId, provider: renderer)
        lock.lock()
        self.indexById = indexById
        registered = true
        version += 1
        lock.unlock()
        return template()
    }

    public func has(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexById[id] != nil
    }

    /// One polygon changed in place. A change of zIndex reorders the list and
    /// needs ``setPolygons(_:)`` instead; everything else is applied here.
    public func update(_ state: PolygonState) {
        lock.lock()
        guard indexById[state.id] != nil else {
            lock.unlock()
            return
        }
        pending[state.id] = state
        scheduleFlushLocked()
    }

    /// Takes one polygon out of the tiles. Its slot in the renderer's list is
    /// left empty, so the others keep their indices and only the tiles it was
    /// in are drawn again.
    public func remove(_ id: String) {
        lock.lock()
        guard let index = indexById.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        pending[id] = nil
        pendingRemovals.append(index)
        scheduleFlushLocked()
    }

    /// Called with ``lock`` held; releases it.
    private func scheduleFlushLocked() {
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.updateCoalesceMs)) { [weak self] in
                self?.flush()
            }
        }
    }

    /// The URL template of the tiles as they are now. Read from the server each
    /// time: it moves to a new port when the app comes back from the background.
    public func template() -> String {
        lock.lock()
        let version = self.version
        lock.unlock()
        return TileServerRegistry.get().urlTemplate(routeId: routeId, tileSize: tileSize, cacheKey: "v\(version)")
    }

    public func dispose() {
        cancelPending()
        lock.lock()
        let wasRegistered = registered
        registered = false
        indexById.removeAll()
        lock.unlock()
        if wasRegistered { TileServerRegistry.get().unregister(routeId: routeId) }
        renderer.clear()
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        let updates = pending.values.compactMap { state -> (Int, PolygonState)? in
            indexById[state.id].map { ($0, state) }
        }
        let removals = pendingRemovals
        pending.removeAll()
        pendingRemovals.removeAll()
        let live = registered
        lock.unlock()
        guard live, !updates.isEmpty || !removals.isEmpty else { return }
        var changes: [(index: Int, shape: PolygonTileShape?)] = updates.map { (index: $0.0, shape: PolygonTileShape(state: $0.1)) }
        for index in removals { changes.append((index: index, shape: nil)) }
        renderer.update(changes)
        lock.lock()
        version += 1
        lock.unlock()
        onTemplateChanged?(template())
    }

    private func cancelPending() {
        lock.lock()
        pending.removeAll()
        pendingRemovals.removeAll()
        lock.unlock()
    }
}
