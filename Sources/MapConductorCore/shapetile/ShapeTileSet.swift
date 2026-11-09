import Foundation
import UIKit

/**
 Shapes of one map drawn as raster tiles, and their route on the local tile
 server: the part ``PolygonTileSet`` and ``PolylineTileSet`` share.

 Holds the route (registered on the first ``setStates(_:)``), the version that
 goes into every URL template (bumped by each change, so the map asks again —
 a template without it shows the old tiles forever), the in-place changes
 coalesced over ``updateCoalesceMs``, removals that empty a slot without
 renumbering the rest, and the teardown. What a state looks like in a tile is
 the caller's: it passes the conversion to ``ShapeTileRenderer/Shape``.
 */
final class ShapeTileSet<State> {
    /// In-place changes arriving within this window become one new template.
    static var updateCoalesceMs: Int { 16 }

    let routeId: String
    let tileSize = 256
    /// Called on the main thread with the template after a batch of in-place changes.
    var onTemplateChanged: ((String) -> Void)?

    let renderer: ShapeTileRenderer
    private let idOf: (State) -> String
    private let zIndexOf: (State) -> Int
    private let shapeOf: (State) -> ShapeTileRenderer.Shape?
    private let lock = NSLock()
    private var indexById: [String: Int] = [:]
    private var version = 0
    private var registered = false
    private var pending: [String: State] = [:]
    private var pendingRemovals: [Int] = []
    private var flushScheduled = false

    init(
        routePrefix: String,
        pixelRatio: Int,
        id: @escaping (State) -> String,
        zIndex: @escaping (State) -> Int,
        shape: @escaping (State) -> ShapeTileRenderer.Shape?
    ) {
        routeId = "\(routePrefix)-\(UUID().uuidString.prefix(8).lowercased())"
        renderer = ShapeTileRenderer(tileSize: 256, pixelRatio: pixelRatio)
        idOf = id
        zIndexOf = zIndex
        shapeOf = shape
    }

    deinit {
        if registered { TileServerRegistry.get().unregister(routeId: routeId) }
    }

    /// Registers `states` (replacing whatever was registered) and returns the URL
    /// template of their tiles. The states are read and projected off the
    /// calling thread.
    func setStates(_ states: [State]) async -> String? {
        cancelPending()
        let renderer = self.renderer
        let idOf = self.idOf, zIndexOf = self.zIndexOf, shapeOf = self.shapeOf
        let indexById = await Task.detached(priority: .userInitiated) { () -> [String: Int] in
            // Draw order is list order: zIndex, then the order given. Each zIndex
            // is read once: a state's properties are not free to read, and a
            // sort reads them n log n times.
            let zIndex = states.map(zIndexOf)
            let ordered = states.indices
                .sorted { zIndex[$0] != zIndex[$1] ? zIndex[$0] < zIndex[$1] : $0 < $1 }
                .map { states[$0] }
            var indexById: [String: Int] = [:]
            indexById.reserveCapacity(ordered.count)
            var shapes: [ShapeTileRenderer.Shape?] = []
            shapes.reserveCapacity(ordered.count)
            for (i, state) in ordered.enumerated() {
                indexById[idOf(state)] = i
                shapes.append(shapeOf(state))
            }
            renderer.setShapes(shapes)
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

    func has(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexById[id] != nil
    }

    /// One state changed in place. A change of zIndex reorders the list and
    /// needs ``setStates(_:)`` instead; everything else is applied here.
    func update(_ state: State) {
        let id = idOf(state)
        lock.lock()
        guard indexById[id] != nil else {
            lock.unlock()
            return
        }
        pending[id] = state
        scheduleFlushLocked()
    }

    /// Takes one shape out of the tiles. Its slot in the renderer's list is
    /// left empty, so the others keep their indices and only the tiles it was
    /// in are drawn again.
    func remove(_ id: String) {
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

    /// The URL template of the tiles as they are now, with the version in it.
    /// Read from the server each time: it moves to a new port when the app
    /// comes back from the background.
    func template() -> String {
        lock.lock()
        let version = self.version
        lock.unlock()
        return TileServerRegistry.get().urlTemplate(routeId: routeId, tileSize: tileSize, cacheKey: "v\(version)")
    }

    func dispose() {
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
        let updates = pending.compactMap { id, state -> (Int, State)? in
            indexById[id].map { ($0, state) }
        }
        let removals = pendingRemovals
        pending.removeAll()
        pendingRemovals.removeAll()
        let live = registered
        lock.unlock()
        guard live, !updates.isEmpty || !removals.isEmpty else { return }
        var changes: [(index: Int, shape: ShapeTileRenderer.Shape?)] = updates.map { (index: $0.0, shape: shapeOf($0.1)) }
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
