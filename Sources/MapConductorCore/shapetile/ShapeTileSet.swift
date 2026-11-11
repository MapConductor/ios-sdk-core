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
    /// Where ``flush()`` runs: off the main thread, since redrawing the changed
    /// shapes (and, past a few thousand changes, rewriting a circle file of
    /// hundreds of thousands of records) took 150 ms there. Serial, so batches
    /// reach the renderer in order.
    private let flushQueue = DispatchQueue(label: "mapconductor.shapetile.flush", qos: .userInitiated)
    /// Called on the main thread with the template after a batch of in-place changes.
    var onTemplateChanged: ((String) -> Void)?

    let renderer: ShapeTileRenderer
    private let idOf: (State) -> String
    private let zIndexOf: (State) -> Int
    private let shapeOf: (State) -> ShapeTileRenderer.Shape?
    private let fileBackedCircles: Bool
    private let lock = NSLock()
    private var indexById: [String: Int] = [:]
    private var sourceStates: [State?] = []
    private var sourceZ: [Int] = []

    func source(_ id: String) -> State? {
        lock.lock(); defer { lock.unlock() }
        guard let index = indexById[id] else { return nil }
        return sourceStates[index]
    }

    /// The registered states whose shape's box meets the given one (Web Mercator),
    /// as of now: changes still waiting for ``flush()`` are included, since their
    /// shape in the renderer may be the old one.
    func sources(minX: Double, minY: Double, maxX: Double, maxY: Double) -> [State] {
        let slots = renderer.candidates(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        lock.lock()
        defer { lock.unlock() }
        var states: [State] = []
        var seen = Set<String>()
        for slot in slots where Int(slot) < sourceStates.count {
            guard let state = sourceStates[Int(slot)] else { continue }
            if seen.insert(idOf(state)).inserted { states.append(state) }
        }
        for (id, state) in pending where indexById[id] != nil && seen.insert(id).inserted {
            states.append(state)
        }
        return states
    }

    func visitSources(_ action: (State) -> Void) {
        lock.lock(); let sources = sourceStates; lock.unlock()
        for state in sources { if let state { action(state) } }
    }
    private var version = 0
    private var registration = 0
    private var registered = false
    private var pending: [String: State] = [:]
    private var pendingRemovals: [Int] = []
    private var flushScheduled = false

    init(
        routePrefix: String,
        pixelRatio: Int,
        id: @escaping (State) -> String,
        zIndex: @escaping (State) -> Int,
        fileBackedCircles: Bool = false,
        shape: @escaping (State) -> ShapeTileRenderer.Shape?
    ) {
        routeId = "\(routePrefix)-\(UUID().uuidString.prefix(8).lowercased())"
        renderer = ShapeTileRenderer(tileSize: 256, pixelRatio: pixelRatio)
        idOf = id
        zIndexOf = zIndex
        shapeOf = shape
        self.fileBackedCircles = fileBackedCircles
    }

    deinit {
        if registered { TileServerRegistry.get().unregister(routeId: routeId) }
    }

    /// Registers `states` (replacing whatever was registered) and returns the URL
    /// template of their tiles. The states are read and projected off the
    /// calling thread.
    func setStates(_ states: [State]) async -> String? {
        cancelPending()
        let registration = nextRegistration()
        let renderer = self.renderer
        let idOf = self.idOf, zIndexOf = self.zIndexOf, shapeOf = self.shapeOf
        let fileBackedCircles = self.fileBackedCircles
        let work = Task.detached(priority: .userInitiated) { () -> Bool in
            // Draw order is list order: zIndex, then the order given. Each zIndex
            // is read once: a state's properties are not free to read, and a
            // sort reads them n log n times.
            let zIndex = states.map(zIndexOf)
            let order = states.indices.sorted { zIndex[$0] != zIndex[$1] ? zIndex[$0] < zIndex[$1] : $0 < $1 }
            let ordered = order.map { states[$0] }
            let sortedZ = fileBackedCircles ? order.map { zIndex[$0] } : []
            if fileBackedCircles, self.reuse(ordered, sortedZ: sortedZ, registration: registration) { return true }
            var indexById: [String: Int] = [:]
            indexById.reserveCapacity(ordered.count)
            for (i, state) in ordered.enumerated() {
                indexById[idOf(state)] = i
            }
            let storage: ShapeTileStorage
            if fileBackedCircles, ordered.count > 2_000,
               let file = try? CircleGeometryFile(count: ordered.count, shapeAt: { shapeOf(ordered[$0]) }) {
                storage = ShapeTileStorage(file)
            } else {
                guard !Task.isCancelled else { return false }
                storage = ShapeTileStorage(ordered.map(shapeOf))
            }
            guard !Task.isCancelled else { return false }
            let install = renderer.prepareStorage(storage)
            return self.publish(
                registration: registration, indexById: indexById, sources: ordered.map { Optional($0) },
                sortedZ: sortedZ, install: install
            )
        }
        let published = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        return published ? template() : nil
    }

    private func nextRegistration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        registration += 1
        return registration
    }

    private func publish(
        registration: Int, indexById: [String: Int], sources: [State?], sortedZ: [Int], install: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.registration == registration, !Task.isCancelled else { return false }
        install()
        let server = TileServerRegistry.get()
        server.register(routeId: routeId, provider: renderer)
        self.indexById = indexById
        self.sourceStates = sources
        self.sourceZ = sortedZ
        registered = true
        version += 1
        return true
    }

    private func reuse(_ ordered: [State], sortedZ: [Int], registration: Int) -> Bool {
        guard let circles = ordered as? [CircleState] else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard registered, sourceStates.count > 2_000, self.registration == registration, !Task.isCancelled else { return false }
        var active = [Bool](repeating: false, count: sourceStates.count)
        var slots: [Int] = []
        slots.reserveCapacity(ordered.count)
        for (i, state) in ordered.enumerated() {
            guard let slot = indexById[idOf(state)], slot > (slots.last ?? -1),
                  sortedZ[i] == sourceZ[slot] else { return false }
            slots.append(slot)
            active[slot] = true
        }
        guard renderer.reuseCircles(circles, slots: slots, active: active) else { return false }
        for i in sourceStates.indices where !active[i] { sourceStates[i] = nil }
        for (state, slot) in zip(ordered, slots) { sourceStates[slot] = state }
        version += 1
        return true
    }

    func has(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexById[id].map { sourceStates[$0] != nil } ?? false
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
        sourceStates[indexById[id]!] = state
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
        sourceStates[index] = nil
        pendingRemovals.append(index)
        scheduleFlushLocked()
    }

    /// Called with ``lock`` held; releases it.
    private func scheduleFlushLocked() {
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule {
            flushQueue.asyncAfter(deadline: .now() + .milliseconds(Self.updateCoalesceMs)) { [weak self] in
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
        registration += 1
        let wasRegistered = registered
        registered = false
        indexById.removeAll()
        sourceStates.removeAll()
        sourceZ.removeAll()
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
        let template = template()
        // onTemplateChanged is documented to run on the main thread.
        DispatchQueue.main.async { [weak self] in self?.onTemplateChanged?(template) }
    }

    private func cancelPending() {
        lock.lock()
        pending.removeAll()
        pendingRemovals.removeAll()
        lock.unlock()
    }
}
