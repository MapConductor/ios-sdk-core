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

 The iOS counterpart of js-sdk-core's `PolygonTiler`. The routing itself is
 ``ShapeTiler``'s, shared with ``PolylineTiler``.
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
    public var onTemplate: ((String?, Int) async -> Void)? {
        get { core.onTemplate }
        set { core.onTemplate = newValue }
    }
    public let options: PolygonTilingOptions

    let tileSet: PolygonTileSet
    private let core: ShapeTiler<PolygonState>

    public init(options: PolygonTilingOptions = .Default) {
        self.options = options
        let tileSet = PolygonTileSet()
        self.tileSet = tileSet
        core = ShapeTiler(
            tileSet: tileSet.core,
            id: { $0.id },
            canTile: PolygonTileSet.canTile,
            vertexCount: { state in state.holes.reduce(state.points.count) { $0 + $1.count } }
        )
    }

    /// Re-decides tiling for `data` and returns the ids drawn as tiles.
    public func route(_ data: [PolygonState]) async -> Set<String> {
        let options = self.options
        return await core.route(data) { options.shouldUseTiles(polygonCount: $0, vertexCount: $1) }
    }

    /// The states drawn as tiles, as of the last ``route(_:)``.
    public func tiledStates() -> [PolygonState] {
        core.tiledStates()
    }

    public func isTiled(_ id: String) -> Bool {
        core.isTiled(id)
    }

    /// An in-place change of a tiled polygon; only the tiles it touches are redrawn.
    public func update(_ state: PolygonState) {
        core.update(state)
    }

    /// Takes one polygon out of the tiles, for a change that left it no longer
    /// ``PolygonTileSet/canTile(_:)``; only the tiles it was in are redrawn. The
    /// controller then hands it to the map SDK.
    public func remove(_ id: String) {
        core.remove(id)
    }

    /// Shows the tiles again if the local tile server came back on another port
    /// (it does after the app has been in the background). Cheap enough to call
    /// on every content update, which is where the marker tiles check too.
    public func refreshIfServerMoved() {
        core.refreshIfServerMoved()
    }

    /// The current template, or nil when nothing is tiled. A provider whose map
    /// re-reads its layers (a style reload, a server that moved) asks here.
    public func currentTemplate() -> String? {
        core.currentTemplate()
    }

    /// Unregisters the tiles without telling the provider; for a map being torn down.
    public func dispose() {
        core.dispose()
    }

    public func clear() async {
        await core.clear()
    }
}
