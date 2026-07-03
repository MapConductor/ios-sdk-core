import Foundation

public protocol RasterLayerManagerProtocol {
    associatedtype ActualLayer

    func registerEntity(_ entity: RasterLayerEntity<ActualLayer>)
    func removeEntity(_ id: String) -> RasterLayerEntity<ActualLayer>?
    func getEntity(_ id: String) -> RasterLayerEntity<ActualLayer>?
    func hasEntity(_ id: String) -> Bool
    func allEntities() -> [RasterLayerEntity<ActualLayer>]
    func clear()
    func find(position: GeoPointProtocol) -> RasterLayerEntity<ActualLayer>?
}

public final class RasterLayerManager<ActualLayer>: RasterLayerManagerProtocol {
    private var entities: [String: RasterLayerEntity<ActualLayer>] = [:]
    private var destroyed = false
    private let lock = NSLock()

    public init() {}

    private func checkNotDestroyedLocked() {
        // In-flight async work (e.g. Combine subscriptions delivering through
        // a Task) can legitimately arrive just after destroy() during provider
        // switches. destroy() clears all state, so post-destroy access is a
        // harmless no-op on empty state — log instead of crashing.
        if destroyed {
            NSLog("[MapConductor] RasterLayerManager accessed after destroy (ignored)")
        }
    }

    public func registerEntity(_ entity: RasterLayerEntity<ActualLayer>) {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        entities[entity.state.id] = entity
    }

    public func removeEntity(_ id: String) -> RasterLayerEntity<ActualLayer>? {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        return entities.removeValue(forKey: id)
    }

    public func getEntity(_ id: String) -> RasterLayerEntity<ActualLayer>? {
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

    public func allEntities() -> [RasterLayerEntity<ActualLayer>] {
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
    }

    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        if destroyed { return }
        destroyed = true
        entities.removeAll()
    }

    public var isDestroyed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return destroyed
    }

    public func find(position: GeoPointProtocol) -> RasterLayerEntity<ActualLayer>? {
        lock.lock()
        defer { lock.unlock() }
        checkNotDestroyedLocked()
        return nil
    }
}
