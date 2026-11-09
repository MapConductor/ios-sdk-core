import Foundation
import UIKit

public struct PolylineHitResult<ActualPolyline> {
    public let entity: PolylineEntity<ActualPolyline>
    public let closestPoint: GeoPointProtocol
}

private struct DistanceResult {
    let distance: Double
    let closestPoint: GeoPointProtocol
}

private enum PolylineDefaults {
    // `Settings.Default.tapTolerance` is expressed in dp on Android and in points here;
    // convert to pixels by multiplying by the screen scale, as Android does with density.
    static func tapTolerancePx(screenScale: Double = Double(UIScreen.main.scale)) -> Double {
        Double(Settings.Default.tapTolerance) * max(1.0, screenScale)
    }
}

public protocol PolylineManagerProtocol {
    associatedtype ActualPolyline

    func registerEntity(_ entity: PolylineEntity<ActualPolyline>)
    func removeEntity(_ id: String) -> PolylineEntity<ActualPolyline>?
    func getEntity(_ id: String) -> PolylineEntity<ActualPolyline>?
    func hasEntity(_ id: String) -> Bool
    func allEntities() -> [PolylineEntity<ActualPolyline>]
    func clear()

    func find(
        position: GeoPointProtocol,
        cameraPosition: MapCameraPosition?
    ) -> PolylineHitResult<ActualPolyline>?
}

public final class PolylineManager<ActualPolyline>: PolylineManagerProtocol {
    private var entities: [String: PolylineEntity<ActualPolyline>] = [:]
    /// Every entity's ``PolylineHitBounds``, side by side, for a tap to skip
    /// the lines it cannot hit without touching the entities.
    private var hitBoxes = PolylineHitBoxes()
    private var destroyed = false
    private let lock = NSLock()

    public init() {}

    private func checkNotDestroyedLocked() {
        // In-flight async work (e.g. Combine subscriptions delivering through
        // a Task) can legitimately arrive just after destroy() during provider
        // switches. destroy() clears all state, so post-destroy access is a
        // harmless no-op on empty state — log instead of crashing.
        if destroyed {
            NSLog("[MapConductor] PolylineManager accessed after destroy (ignored)")
        }
    }

    public func registerEntity(_ entity: PolylineEntity<ActualPolyline>) {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        entities[entity.state.id] = entity
        hitBoxes.set(entity.state.id, entity.hitBounds)
    }

    public func removeEntity(_ id: String) -> PolylineEntity<ActualPolyline>? {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        hitBoxes.remove(id)
        return entities.removeValue(forKey: id)
    }

    public func getEntity(_ id: String) -> PolylineEntity<ActualPolyline>? {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        return entities[id]
    }

    public func hasEntity(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        return entities[id] != nil
    }

    public func allEntities() -> [PolylineEntity<ActualPolyline>] {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        return Array(entities.values)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        entities.removeAll()
        hitBoxes = PolylineHitBoxes()
    }

    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        if destroyed { return }
        destroyed = true
        entities.removeAll()
        hitBoxes = PolylineHitBoxes()
    }

    public var isDestroyed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return destroyed
    }

    public func find(
        position: GeoPointProtocol,
        cameraPosition: MapCameraPosition?
    ) -> PolylineHitResult<ActualPolyline>? {
        let visibleRegion = cameraPosition?.visibleRegion?.bounds
        let zoom = cameraPosition?.zoom ?? 0.0
        let screenScale = max(1.0, Double(UIScreen.main.scale))
        let fingerSizePx = PolylineDefaults.tapTolerancePx(screenScale: screenScale)
        let metersPerPixel = calculateMetersPerPixel(latitude: position.latitude, zoom: zoom)

        var candidates: [(PolylineEntity<ActualPolyline>, GeoPointProtocol, Double)] = []

        // A tap hits a line within a finger of its edge: the finger plus half
        // the line's width, both converted to pixels the same way.
        let thresholdFor = { (strokeWidth: Double) in metersPerPixel * (fingerSizePx + strokeWidth / 2 * screenScale) }
        // Most lines are nowhere near the tap: they are skipped by their box,
        // and neither the entity nor its points are read.
        lock.lock()
        checkNotDestroyedLocked()
        let nearby = hitBoxes.candidates(latitude: position.latitude, longitude: position.longitude, meters: thresholdFor)
            .compactMap { entities[$0] }
        lock.unlock()

        for entity in nearby {
            let threshold = thresholdFor(entity.hitBounds.strokeWidth)
            let points = entity.state.points
            guard points.count >= 2 else { continue }
            let geodesic = entity.state.geodesic

            for index in 0..<(points.count - 1) {
                if let visibleRegion {
                    let segmentBounds = GeoRectBounds()
                    segmentBounds.extend(point: points[index])
                    segmentBounds.extend(point: points[index + 1])
                    if !visibleRegion.intersects(other: segmentBounds) { continue }
                }

                let hit: (GeoPointProtocol, Double)?
                if geodesic {
                    hit = WGS84Geodesic.pointOnLineOrNull(
                        from: points[index],
                        to: points[index + 1],
                        position: position,
                        thresholdMeters: threshold
                    )
                } else {
                    hit = Planar.pointOnLineOrNull(
                        from: points[index],
                        to: points[index + 1],
                        position: position,
                        thresholdMeters: threshold
                    )
                }

                if let hit {
                    candidates.append((entity, hit.0, hit.1))
                }
            }
        }

        guard let closest = candidates.min(by: { $0.2 < $1.2 }) else { return nil }
        return PolylineHitResult(entity: closest.0, closestPoint: closest.1)
    }
}

/// The hit boxes of a manager's lines in flat arrays (non-generic, so a tap
/// over 50,000 lines is a loop over plain values).
struct PolylineHitBoxes {
    private var ids: ContiguousArray<String> = []
    private var boxes: ContiguousArray<PolylineHitBounds> = []
    private var indexById: [String: Int] = [:]

    mutating func set(_ id: String, _ bounds: PolylineHitBounds) {
        if let i = indexById[id] {
            boxes[i] = bounds
        } else {
            indexById[id] = ids.count
            ids.append(id)
            boxes.append(bounds)
        }
    }

    mutating func remove(_ id: String) {
        guard let i = indexById.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if i != last {
            ids[i] = ids[last]
            boxes[i] = boxes[last]
            indexById[ids[i]] = i
        }
        ids.removeLast()
        boxes.removeLast()
    }

    /// Ids of the lines whose box, padded by `meters(strokeWidth)`, holds the point.
    func candidates(latitude: Double, longitude: Double, meters: (Double) -> Double) -> [String] {
        var out: [String] = []
        for i in boxes.indices {
            let box = boxes[i]
            if box.mayContain(latitude: latitude, longitude: longitude, meters: meters(box.strokeWidth)) {
                out.append(ids[i])
            }
        }
        return out
    }
}
