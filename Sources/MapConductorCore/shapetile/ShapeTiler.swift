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
final class ShapeTiler<State> {
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
        var tileable: [State] = []
        tileable.reserveCapacity(data.count)
        var vertices = 0
        for state in data where canTile(state) {
            tileable.append(state)
            vertices += vertexCountOf(state)
        }
        let useTiles = shouldUseTiles(tileable.count, vertices)
        let template = useTiles ? await tileSet.setStates(tileable) : nil
        if let template {
            let ids = Set(tileable.map(idOf))
            let baseUrl = TileServerRegistry.get().baseUrl
            withLock {
                tiled = ids
                states = tileable
                shownBaseUrl = baseUrl
            }
            await onTemplate?(template, tileSet.tileSize)
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
