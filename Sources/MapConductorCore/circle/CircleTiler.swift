import Foundation

/**
 Decides which of a map's circles are drawn as tiles, keeps them registered
 with the local tile server, and tells the provider where the tiles are.

 Used the same way as ``PolylineTiler`` (``CircleController/tiler``):

 1. ``route(_:)`` with the full list on every membership change. It returns the
    ids now in tiles; the controller keeps those in its `CircleManager` (taps
    are resolved there, against the original circles) but gives the map SDK
    nothing for them, and removes any native circle it had drawn for one.
 2. ``update(_:)`` for an in-place change of a tiled circle, or ``remove(_:)``
    when the change means it can no longer be tiled (it moved onto the
    antimeridian, say).
 3. ``onTemplate`` is how the tiles reach the map: a URL template to show as a
    raster layer, or nil to remove it. A provider with a raster layer controller
    hands ``rasterLayerState(template:tileSize:)`` to its `upsert(state:)` and
    removes ``layerId`` with `removeById(_:)`. The layer stacks at the bottom of
    the circle band: over the polygons (and their tiles), under the natively
    drawn circles and the polyline tiles (``OverlayStacking/rasterKey(stateId:zIndex:)``).

 ``options`` can change while the map is up (``MapViewContent/circleTilingOptions``);
 the next ``route(_:)`` decides with the new ones. ``setOptions(_:)`` tells the
 caller whether that next route is needed.

 The iOS counterpart of js-sdk-core's and android-sdk-core's `CircleTiler`.
 */
@_spi(MapConductorDriver)
public final class CircleTiler {
    /// The id of the raster layer that shows tiled circles (js-sdk-core's `CIRCLE_TILE_LAYER_ID`).
    public static let layerId = OverlayStacking.circleTileStateId

    /// The raster layer state for tiled circles at `template`.
    public static func rasterLayerState(template: String, tileSize: Int = 256) -> RasterLayerState {
        RasterLayerState(source: .urlTemplate(template: template, tileSize: tileSize), id: layerId)
    }

    /// Called with the template to show, or nil to remove the layer, and the tile size.
    public var onTemplate: ((String?, Int) async -> Void)? {
        get { core.onTemplate }
        set { core.onTemplate = newValue }
    }

    private let optionsLock = NSLock()
    private var optionsValue: CircleTilingOptions
    /// Read by the next ``route(_:)``.
    public var options: CircleTilingOptions {
        get {
            optionsLock.lock()
            defer { optionsLock.unlock() }
            return optionsValue
        }
        set { _ = setOptions(newValue) }
    }

    let tileSet: CircleTileSet
    private let core: ShapeTiler<CircleState>

    public init(options: CircleTilingOptions = .Default) {
        optionsValue = options
        let tileSet = CircleTileSet()
        self.tileSet = tileSet
        core = ShapeTiler(
            tileSet: tileSet.core,
            id: { $0.id },
            canTile: CircleTileSet.canTile,
            vertexCount: { _ in 0 }
        )
    }

    /// Sets the options for the next ``route(_:)``; true when they changed, so
    /// the caller should route the current list again.
    @discardableResult
    public func setOptions(_ options: CircleTilingOptions) -> Bool {
        optionsLock.lock()
        defer { optionsLock.unlock() }
        guard optionsValue != options else { return false }
        optionsValue = options
        return true
    }

    /// Re-decides tiling for `data` and returns the ids drawn as tiles.
    public func route(_ data: [CircleState]) async -> Set<String> {
        let options = self.options
        return await core.route(data) { count, _ in options.shouldUseTiles(circleCount: count) }
    }

    /// The states drawn as tiles, as of the last ``route(_:)``.
    public func tiledStates() -> [CircleState] {
        core.tiledStates()
    }

    public func isTiled(_ id: String) -> Bool {
        core.isTiled(id)
    }

    func state(_ id: String) -> CircleState? { tileSet.core.source(id) }
    func visitStates(_ action: (CircleState) -> Void) { tileSet.core.visitSources(action) }

    /// An in-place change of a tiled circle; only the tiles it touches are redrawn.
    public func update(_ state: CircleState) {
        core.update(state)
    }

    /// Takes one circle out of the tiles, for a change that left it no longer
    /// ``CircleTileSet/canTile(_:)``. The controller then hands it to the map SDK.
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
