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
final class ShapeTileSet<State: AnyObject> {
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
    /// Where a state is, for storing a large set by place (see ``CircleGeometryFile``).
    private let spatialKeyOf: ((State) -> Int)?
    /// A state's revision (it moves on every write to the state), for telling
    /// an unchanged state by identity without reading its properties. Only
    /// circles give one.
    private let revisionOf: ((State) -> UInt64)?
    private let lock = NSLock()
    private var indexById: [String: Int] = [:]
    /// The state registered in each slot; nil once it was removed. A slot left
    /// out by ``reuse(_:sortedZ:slots:registration:)`` keeps its state, so that
    /// the state can be matched to it again: ``sourceActive`` says which are drawn.
    private var sourceStates: [State?] = []
    /// Which slots are drawn; empty when all are.
    private var sourceActive: [Bool] = []
    private var sourceZ: [Int] = []
    /// Each slot's state's revision when it was registered, or
    /// ``unknownRevision`` once the slot was changed or removed. Empty without
    /// ``revisionOf``.
    private var sourceRevisions: [UInt64] = []
    private static var unknownRevision: UInt64 { .max }

    /// Called with ``lock`` held.
    private func isDrawnLocked(_ slot: Int) -> Bool {
        sourceActive.isEmpty || sourceActive[slot]
    }

    func source(_ id: String) -> State? {
        lock.lock(); defer { lock.unlock() }
        guard let index = indexById[id], isDrawnLocked(index) else { return nil }
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
        for slot in slots where Int(slot) < sourceStates.count && isDrawnLocked(Int(slot)) {
            guard let state = sourceStates[Int(slot)] else { continue }
            if seen.insert(idOf(state)).inserted { states.append(state) }
        }
        for (id, state) in pending where indexById[id] != nil && seen.insert(id).inserted {
            states.append(state)
        }
        return states
    }

    func visitSources(_ action: (State) -> Void) {
        lock.lock(); let sources = sourceStates; let active = sourceActive; lock.unlock()
        for (slot, state) in sources.enumerated() where active.isEmpty || active[slot] {
            if let state { action(state) }
        }
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
        spatialKey: ((State) -> Int)? = nil,
        revision: ((State) -> UInt64)? = nil,
        shape: @escaping (State) -> ShapeTileRenderer.Shape?
    ) {
        routeId = "\(routePrefix)-\(UUID().uuidString.prefix(8).lowercased())"
        renderer = ShapeTileRenderer(tileSize: 256, pixelRatio: pixelRatio)
        idOf = id
        zIndexOf = zIndex
        shapeOf = shape
        self.fileBackedCircles = fileBackedCircles
        spatialKeyOf = spatialKey
        revisionOf = revision
    }

    deinit {
        if registered { TileServerRegistry.get().unregister(routeId: routeId) }
    }

    /// Registers `states` (replacing whatever was registered) and returns the URL
    /// template of their tiles. The states are read and projected off the
    /// calling thread.
    ///
    /// `slots` (from ``registeredSlots(_:)``, one per state) lets the states
    /// already registered and unchanged skip being read again.
    func setStates(_ states: [State], slots: [Int32]? = nil) async -> String? {
        cancelPending()
        let registration = nextRegistration()
        let renderer = self.renderer
        let idOf = self.idOf, zIndexOf = self.zIndexOf, shapeOf = self.shapeOf
        let fileBackedCircles = self.fileBackedCircles
        let spatialKeyOf = self.spatialKeyOf
        let revisionOf = self.revisionOf
        let work = Task.detached(priority: .userInitiated) { () -> Bool in
            // A filter over the registered states: all of them unchanged and in
            // the registered order, which is already the draw order.
            if fileBackedCircles, let slots, self.reuse(states, slots: slots, registration: registration) { return true }
            // Draw order is list order: zIndex, then the order given. Each zIndex
            // is read once: a state's properties are not free to read, and a
            // sort reads them n log n times.
            let zIndex = self.zIndices(states, slots: slots, zIndexOf: zIndexOf)
            // Usually already in order (the app keeps its own), and then the
            // sort is not needed.
            let inOrder = zIndex.indices.dropFirst().allSatisfy { zIndex[$0 - 1] <= zIndex[$0] }
            let order = inOrder ? Array(states.indices) : states.indices.sorted { zIndex[$0] != zIndex[$1] ? zIndex[$0] < zIndex[$1] : $0 < $1 }
            let ordered = inOrder ? states : order.map { states[$0] }
            let sortedZ = fileBackedCircles ? (inOrder ? zIndex : order.map { zIndex[$0] }) : []
            let orderedSlots = slots.map { slots in inOrder ? slots : order.map { slots[$0] } }
            if fileBackedCircles, self.reuse(ordered, sortedZ: sortedZ, slots: orderedSlots, registration: registration) { return true }
            var indexById: [String: Int] = [:]
            indexById.reserveCapacity(ordered.count)
            for (i, state) in ordered.enumerated() {
                indexById[idOf(state)] = i
            }
            let storage: ShapeTileStorage
            // Stored by place, so that a tile reads the few pages round it.
            if fileBackedCircles, ordered.count > 2_000,
               let file = try? CircleGeometryFile(
                   count: ordered.count,
                   order: spatialKeyOf.map { keyOf in CircleGeometryFile.sortedOrder(count: ordered.count) { keyOf(ordered[$0]) } },
                   shapeAt: { shapeOf(ordered[$0]) }
               ) {
                storage = ShapeTileStorage(file)
            } else {
                guard !Task.isCancelled else { return false }
                storage = ShapeTileStorage(ordered.map(shapeOf))
            }
            guard !Task.isCancelled else { return false }
            let install = renderer.prepareStorage(storage)
            return self.publish(
                registration: registration, indexById: indexById, sources: ordered.map { Optional($0) },
                sortedZ: sortedZ, revisions: revisionOf.map { ordered.map($0) } ?? [], install: install
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
        registration: Int, indexById: [String: Int], sources: [State?], sortedZ: [Int], revisions: [UInt64],
        install: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.registration == registration, !Task.isCancelled else { return false }
        install()
        let server = TileServerRegistry.get()
        server.register(routeId: routeId, provider: renderer)
        self.indexById = indexById
        self.sourceStates = sources
        self.sourceActive = []
        self.sourceZ = sortedZ
        self.sourceRevisions = revisions
        registered = true
        version += 1
        return true
    }

    /// For each of `states`, the slot it is registered in when it is the very
    /// object registered there and has not been written to since, or -1. Nil
    /// when there is nothing to match against. Reads no state's properties: a
    /// filter over hundreds of thousands of circles spent seconds reading them
    /// to find that nothing had changed.
    func registeredSlots(_ states: [State]) -> [Int32]? {
        guard let revisionOf else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard registered, sourceStates.count > 2_000, sourceRevisions.count == sourceStates.count else { return nil }
        let count = sourceStates.count
        var slots = [Int32](repeating: -1, count: states.count)
        // The list usually keeps the registered order, so the slot is found a
        // little after the last one; past that, by id.
        var next = 0
        for (i, state) in states.enumerated() {
            var slot = -1
            var k = next
            let end = min(count, next + 64)
            while k < end {
                if sourceStates[k] === state { slot = k; break }
                k += 1
            }
            if slot < 0, let byId = indexById[idOf(state)], sourceStates[byId] === state { slot = byId }
            guard slot >= 0 else { continue }
            next = slot + 1
            if sourceRevisions[slot] == revisionOf(state) { slots[i] = Int32(slot) }
        }
        return slots
    }

    /// Each state's zIndex, from its slot when it is registered and unchanged.
    private func zIndices(_ states: [State], slots: [Int32]?, zIndexOf: (State) -> Int) -> [Int] {
        guard let slots else { return states.map(zIndexOf) }
        lock.lock()
        let z = sourceZ
        lock.unlock()
        return states.indices.map { i in
            let slot = Int(slots[i])
            return slot >= 0 && slot < z.count ? z[slot] : zIndexOf(states[i])
        }
    }

    /// Shows `states` (all registered and unchanged, `slots` from
    /// ``registeredSlots(_:)``) by switching slots on and off, when they are in
    /// the registered order.
    private func reuse(_ states: [State], slots: [Int32], registration: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard registered, sourceStates.count > 2_000, self.registration == registration, !Task.isCancelled else { return false }
        var previous: Int32 = -1
        for slot in slots {
            guard slot > previous else { return false }
            previous = slot
        }
        var active = [Bool](repeating: false, count: sourceStates.count)
        for slot in slots { active[Int(slot)] = true }
        guard renderer.reuseCircleSlots(active: active) else { return false }
        sourceActive = active
        version += 1
        return true
    }

    private func reuse(_ ordered: [State], sortedZ: [Int], slots knownSlots: [Int32]?, registration: Int) -> Bool {
        guard let circles = ordered as? [CircleState] else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard registered, sourceStates.count > 2_000, self.registration == registration, !Task.isCancelled else { return false }
        var active = [Bool](repeating: false, count: sourceStates.count)
        var slots: [Int] = []
        slots.reserveCapacity(ordered.count)
        // Slots whose circle is known unchanged need no comparing with the file.
        var unchanged = [Bool](repeating: false, count: ordered.count)
        for (i, state) in ordered.enumerated() {
            let known = knownSlots.map { Int($0[i]) } ?? -1
            let slot: Int
            if known >= 0 {
                slot = known
                unchanged[i] = true
            } else {
                guard let byId = indexById[idOf(state)] else { return false }
                slot = byId
            }
            guard slot > (slots.last ?? -1), sortedZ[i] == sourceZ[slot] else { return false }
            slots.append(slot)
            active[slot] = true
        }
        guard renderer.reuseCircles(circles, slots: slots, active: active, unchanged: unchanged) else { return false }
        for (i, (state, slot)) in zip(ordered, slots).enumerated() where !unchanged[i] {
            sourceStates[slot] = state
            if !sourceRevisions.isEmpty { sourceRevisions[slot] = revisionOf?(state) ?? Self.unknownRevision }
        }
        sourceActive = active
        version += 1
        return true
    }

    func has(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexById[id].map { sourceStates[$0] != nil && isDrawnLocked($0) } ?? false
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
        let slot = indexById[id]!
        sourceStates[slot] = state
        if !sourceRevisions.isEmpty { sourceRevisions[slot] = Self.unknownRevision }
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
        if !sourceRevisions.isEmpty { sourceRevisions[index] = Self.unknownRevision }
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
        sourceActive.removeAll()
        sourceZ.removeAll()
        sourceRevisions.removeAll()
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
