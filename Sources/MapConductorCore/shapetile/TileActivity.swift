import Foundation

/// Whether a tiler is busy: taking a list (`route`) or drawing tiles for the
/// map. The collections' onAddStart / onAddEnd read it, so that an app can show
/// that the map is still drawing after a filter change or a camera move.
///
/// Counted, since tiles are drawn on several queues at once. Observers are
/// called on whichever queue made the change.
final class TileActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var observers: [UUID: (Bool) -> Void] = [:]

    var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }

    func begin() {
        lock.lock()
        count += 1
        let observers = count == 1 ? Array(self.observers.values) : []
        lock.unlock()
        for observer in observers { observer(true) }
    }

    func end() {
        lock.lock()
        guard count > 0 else {
            lock.unlock()
            return
        }
        count -= 1
        let observers = count == 0 ? Array(self.observers.values) : []
        lock.unlock()
        for observer in observers { observer(false) }
    }

    /// Calls `observer` at each change of ``active``; call the returned closure to stop.
    func observe(_ observer: @escaping (Bool) -> Void) -> () -> Void {
        let key = UUID()
        lock.lock()
        observers[key] = observer
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers[key] = nil
            self.lock.unlock()
        }
    }
}

/// A controller whose tiler can say it is busy. See ``overlayTileActivity(_:kind:)``.
protocol TileActivityProviding: AnyObject {
    /// The collection kind it draws, as in ``AddProgressRequest`` ("circles", ...).
    var tileActivityKind: String { get }
    var tileActivity: TileActivity? { get }
}

extension CircleController: TileActivityProviding {
    var tileActivityKind: String { "circles" }
    var tileActivity: TileActivity? { tiler?.activity }
}

extension PolylineController: TileActivityProviding {
    var tileActivityKind: String { "polylines" }
    var tileActivity: TileActivity? { tiler?.activity }
}

extension PolygonController: TileActivityProviding {
    var tileActivityKind: String { "polygons" }
    var tileActivity: TileActivity? { tiler?.activity }
}

/// The busy states of the map's tilers for one collection kind, through the
/// controllers the provider put in `registry`.
func overlayTileActivity(_ registry: MapServiceRegistry, kind: String) -> [TileActivity] {
    guard let controllers = registry.get(OverlayControllerRegistryKey.self)?.all() else { return [] }
    return controllers.compactMap { controller in
        guard let provider = controller as? TileActivityProviding, provider.tileActivityKind == kind else { return nil }
        return provider.tileActivity
    }
}
