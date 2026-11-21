import Foundation

/**
 The routing ``PolygonTiler`` and ``PolylineTiler`` share: which states are in
 tiles, the tile set they are registered with, and when the provider hears of
 a new template.

 Everything that is read on one thread and written on another (``route(_:)``
 runs wherever the controller's `add` runs, off the main thread, while
 ``refreshIfServerMoved()`` is called from the map's content update on the main
 thread) is read and written under ``lock``.
 */
final class ShapeTiler<State: AnyObject> {
    var onTemplate: ((String?, Int) async -> Void)?

    let tileSet: ShapeTileSet<State>
    private let idOf: (State) -> String
    private let canTile: (State) -> Bool
    private let vertexCountOf: (State) -> Int
    private let lock = NSLock()
    private var tiled: Set<String> = []
    private var states: [State] = []
    private var shownBaseUrl: String?

    init(
        tileSet: ShapeTileSet<State>,
        id: @escaping (State) -> String,
        canTile: @escaping (State) -> Bool,
        vertexCount: @escaping (State) -> Int
    ) {
        self.tileSet = tileSet
        self.idOf = id
        self.canTile = canTile
        self.vertexCountOf = vertexCount
        tileSet.onTemplateChanged = { [weak self] template in
            guard let self else { return }
            Task { await self.onTemplate?(template, self.tileSet.tileSize) }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Re-decides tiling for `data` with `shouldUseTiles(count, vertices)` and
    /// returns the ids drawn as tiles.
    func route(_ data: [State], shouldUseTiles: (Int, Int) -> Bool) async -> Set<String> {
        let activity = tileSet.renderer.activity
        activity.begin()
        defer { activity.end() }
        // A state registered and unchanged since could be tiled then and still can.
        let registered = tileSet.registeredSlots(data)
        var tileable: [State] = []
        tileable.reserveCapacity(data.count)
        var slots: [Int32] = []
        if registered != nil { slots.reserveCapacity(data.count) }
        var vertices = 0
        for (i, state) in data.enumerated() {
            let slot = registered?[i] ?? -1
            guard slot >= 0 || canTile(state) else { continue }
            tileable.append(state)
            if registered != nil { slots.append(slot) }
            vertices += vertexCountOf(state)
        }
        let useTiles = shouldUseTiles(tileable.count, vertices)
        let template = useTiles ? await tileSet.setStates(tileable, slots: registered == nil ? nil : slots) : nil
        if let template {
            let baseUrl = TileServerRegistry.get().baseUrl
            withLock {
                states = tileable
                shownBaseUrl = baseUrl
            }
            // The map starts asking for tiles here; the ids are only bookkeeping.
            await onTemplate?(template, tileSet.tileSize)
            let ids = Set(tileable.map(idOf))
            withLock { tiled = ids }
            return ids
        }
        await clear()
        return []
    }

    func tiledStates() -> [State] {
        withLock { states }
    }

    func isTiled(_ id: String) -> Bool {
        withLock { tiled.contains(id) }
    }

    func update(_ state: State) {
        tileSet.update(state)
    }

    /// Rebuild draw order without re-evaluating the native/tile threshold.
    func reorder(_ data: [State]) async {
        guard let template = await tileSet.setStates(data) else { return }
        withLock { states = data }
        await onTemplate?(template, tileSet.tileSize)
    }

    func remove(_ id: String) {
        let removed = withLock { () -> Bool in
            guard tiled.remove(id) != nil else { return false }
            states.removeAll { idOf($0) == id }
            return true
        }
        if removed { tileSet.remove(id) }
    }

    func refreshIfServerMoved() {
        let current = TileServerRegistry.get().baseUrl
        let moved = withLock { () -> Bool in
            guard !tiled.isEmpty, let shown = shownBaseUrl, shown != current else { return false }
            shownBaseUrl = current
            return true
        }
        guard moved else { return }
        let template = tileSet.template()
        Task { await onTemplate?(template, tileSet.tileSize) }
    }

    func currentTemplate() -> String? {
        withLock { tiled.isEmpty } ? nil : tileSet.template()
    }

    /// Forgets what is tiled and unregisters the route; true when anything was tiled.
    private func forget() -> Bool {
        let hadTiles = withLock { () -> Bool in
            let had = !tiled.isEmpty
            tiled = []
            states = []
            shownBaseUrl = nil
            return had
        }
        tileSet.dispose()
        return hadTiles
    }

    func dispose() {
        _ = forget()
    }

    func clear() async {
        if forget() { await onTemplate?(nil, tileSet.tileSize) }
    }
}
