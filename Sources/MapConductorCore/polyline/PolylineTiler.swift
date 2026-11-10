import Foundation

/**
 Decides which of a map's polylines are drawn as tiles, keeps them registered
 with the local tile server, and tells the provider where the tiles are.

 Used the same way as ``PolygonTiler`` (``PolylineController/tiler``):

 1. ``route(_:)`` with the full list on every membership change. It returns the
    ids now in tiles; the controller keeps those in its `PolylineManager` (taps
    are resolved there, against the original lines) but gives the map SDK
    nothing for them, and removes any native polyline it had drawn for one.
 2. ``update(_:)`` for an in-place change of a tiled polyline, or ``remove(_:)``
    when the change means it can no longer be tiled (it became geodesic, say).
 3. ``onTemplate`` is how the tiles reach the map: a URL template to show as a
    raster layer, or nil to remove it. A provider with a raster layer controller
    hands ``rasterLayerState(template:tileSize:)`` to its `upsert(state:)` and
    removes ``layerId`` with `removeById(_:)`. The layer stacks in the polyline
    band, under the natively drawn polylines (``OverlayStacking/rasterKey(stateId:zIndex:)``).

 ``options`` can change while the map is up (``MapViewContent/polylineTilingOptions``);
 the next ``route(_:)`` decides with the new ones. ``setOptions(_:)`` tells the
 caller whether that next route is needed.

 The iOS counterpart of js-sdk-core's and android-sdk-core's `PolylineTiler`.
 */
@_spi(MapConductorDriver)
public final class PolylineTiler {
    /// The id of the raster layer that shows tiled polylines (js-sdk-core's `POLYLINE_TILE_LAYER_ID`).
    public static let layerId = "mc-polyline-tiles"

    /// The raster layer state for tiled polylines at `template`.
    public static func rasterLayerState(template: String, tileSize: Int = 256) -> RasterLayerState {
        RasterLayerState(source: .urlTemplate(template: template, tileSize: tileSize), id: layerId)
    }

    /// Called with the template to show, or nil to remove the layer, and the tile size.
    public var onTemplate: ((String?, Int) async -> Void)? {
        get { core.onTemplate }
        set { core.onTemplate = newValue }
    }

    private let optionsLock = NSLock()
    private var optionsValue: PolylineTilingOptions
    /// Read by the next ``route(_:)``.
    public var options: PolylineTilingOptions {
        get {
            optionsLock.lock()
            defer { optionsLock.unlock() }
            return optionsValue
        }
        set { _ = setOptions(newValue) }
    }

    let tileSet: PolylineTileSet
    private let core: ShapeTiler<PolylineState>

    public init(options: PolylineTilingOptions = .Default) {
        optionsValue = options
        let tileSet = PolylineTileSet()
        self.tileSet = tileSet
        core = ShapeTiler(
            tileSet: tileSet.core,
            id: { $0.id },
            canTile: PolylineTileSet.canTile,
            vertexCount: { $0.points.count }
        )
    }

    /// Sets the options for the next ``route(_:)``; true when they changed, so
    /// the caller should route the current list again.
    @discardableResult
    public func setOptions(_ options: PolylineTilingOptions) -> Bool {
        optionsLock.lock()
        defer { optionsLock.unlock() }
        guard optionsValue != options else { return false }
        optionsValue = options
        return true
    }

    /// Re-decides tiling for `data` and returns the ids drawn as tiles.
    public func route(_ data: [PolylineState]) async -> Set<String> {
        let options = self.options
        return await core.route(data) { options.shouldUseTiles(polylineCount: $0, vertexCount: $1) }
    }

    /// The states drawn as tiles, as of the last ``route(_:)``.
    public func tiledStates() -> [PolylineState] {
        core.tiledStates()
    }

    public func isTiled(_ id: String) -> Bool {
        core.isTiled(id)
    }

    /// An in-place change of a tiled polyline; only the tiles it touches are redrawn.
    public func update(_ state: PolylineState) {
        core.update(state)
    }

    /// Takes one polyline out of the tiles, for a change that left it no longer
    /// ``PolylineTileSet/canTile(_:)``. The controller then hands it to the map SDK.
    public func remove(_ id: String) {
        core.remove(id)
    }

    /// Shows the tiles again if the local tile server came back on another port.
    public func refreshIfServerMoved() {
        core.refreshIfServerMoved()
    }

    /// The current template, or nil when nothing is tiled.
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
