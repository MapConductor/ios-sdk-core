import Foundation

/**
 Decides which of a map's polygons are drawn as tiles, keeps them registered
 with the local tile server, and tells the provider where the tiles are.

 Every provider's polygon controller uses it the same way (``PolygonController/tiler``):

 1. ``route(_:)`` with the full list on every membership change. It returns the
    ids now in tiles; the controller keeps those in its `PolygonManager` (taps
    are resolved there, against the original shapes) but gives the map SDK
    nothing for them, and removes any native polygon it had drawn for one.
 2. ``update(_:)`` for an in-place change of a tiled polygon, or ``remove(_:)``
    when the change means it can no longer be tiled.
 3. ``onTemplate`` is how the tiles reach the map: a URL template to show as a
    raster layer, or nil to remove it. A provider with a raster layer controller
    hands ``rasterLayerState(template:tileSize:)`` to its `upsert(state:)` and
    removes ``layerId`` with `removeById(_:)` — never through the app's own
    raster layer list, which would drop one or the other.

 The iOS counterpart of js-sdk-core's `PolygonTiler`.
 */
@_spi(MapConductorDriver)
public final class PolygonTiler {
    /// The id of the raster layer that shows tiled polygons (js-sdk-core's `POLYGON_TILE_LAYER_ID`).
    public static let layerId = "mc-polygon-tiles"

    /// The raster layer state for tiled polygons at `template`.
    public static func rasterLayerState(template: String, tileSize: Int = 256) -> RasterLayerState {
        RasterLayerState(source: .urlTemplate(template: template, tileSize: tileSize), id: layerId)
    }

    /// Called with the template to show, or nil to remove the layer, and the tile size.
    public var onTemplate: ((String?, Int) async -> Void)?
    public let options: PolygonTilingOptions

    let tileSet: PolygonTileSet
    /// What is tiled. ``route(_:)`` runs wherever the polygon controller's
    /// `add` runs (off the main thread), while ``refreshIfServerMoved()`` is
    /// called from the map's content update on the main thread: everything below
    /// is read and written under this lock.
    private let lock = NSLock()
    private var tiled: Set<String> = []
    private var states: [PolygonState] = []
    private var shownBaseUrl: String?

    public init(options: PolygonTilingOptions = .Default) {
        self.options = options
        self.tileSet = PolygonTileSet()
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

    /// Re-decides tiling for `data` and returns the ids drawn as tiles.
    public func route(_ data: [PolygonState]) async -> Set<String> {
        var tileable: [PolygonState] = []
        tileable.reserveCapacity(data.count)
        var vertices = 0
        for state in data where PolygonTileSet.canTile(state) {
            tileable.append(state)
            vertices += state.points.count
            for hole in state.holes { vertices += hole.count }
        }
        let useTiles = options.shouldUseTiles(polygonCount: tileable.count, vertexCount: vertices)
        let template = useTiles ? await tileSet.setPolygons(tileable) : nil
        if let template {
            let ids = Set(tileable.map(\.id))
            let baseUrl = TileServerRegistry.get().baseUrl
            withLock {
                tiled = ids
                states = tileable
                shownBaseUrl = baseUrl
            }
            await onTemplate?(template, tileSet.tileSize)
            return ids
        }
        let hadTiles = withLock { () -> Bool in
            let had = !tiled.isEmpty
            tiled = []
            states = []
            shownBaseUrl = nil
            return had
        }
        tileSet.dispose()
        if hadTiles { await onTemplate?(nil, tileSet.tileSize) }
        return []
    }

    /// The states drawn as tiles, as of the last ``route(_:)``.
    public func tiledStates() -> [PolygonState] {
        withLock { states }
    }

    public func isTiled(_ id: String) -> Bool {
        withLock { tiled.contains(id) }
    }

    /// An in-place change of a tiled polygon; only the tiles it touches are redrawn.
    public func update(_ state: PolygonState) {
        tileSet.update(state)
    }

    /// Takes one polygon out of the tiles, for a change that left it no longer
    /// ``PolygonTileSet/canTile(_:)``; only the tiles it was in are redrawn. The
    /// controller then hands it to the map SDK.
    public func remove(_ id: String) {
        let removed = withLock { () -> Bool in
            guard tiled.remove(id) != nil else { return false }
            states.removeAll { $0.id == id }
            return true
        }
        if removed { tileSet.remove(id) }
    }

    /// Shows the tiles again if the local tile server came back on another port
    /// (it does after the app has been in the background). Cheap enough to call
    /// on every content update, which is where the marker tiles check too.
    public func refreshIfServerMoved() {
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

    /// The current template, or nil when nothing is tiled. A provider whose map
    /// re-reads its layers (a style reload, a server that moved) asks here.
    public func currentTemplate() -> String? {
        withLock { tiled.isEmpty } ? nil : tileSet.template()
    }

    /// Unregisters the tiles without telling the provider; for a map being torn down.
    public func dispose() {
        withLock {
            tiled = []
            states = []
            shownBaseUrl = nil
        }
        tileSet.dispose()
    }

    public func clear() async {
        let hadTiles = withLock { () -> Bool in
            let had = !tiled.isEmpty
            tiled = []
            states = []
            shownBaseUrl = nil
            return had
        }
        tileSet.dispose()
        if hadTiles { await onTemplate?(nil, tileSet.tileSize) }
    }
}
