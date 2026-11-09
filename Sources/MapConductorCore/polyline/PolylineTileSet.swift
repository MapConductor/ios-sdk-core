import CoreGraphics
import Foundation
import UIKit

/// One polyline as the tile renderer takes it: plain values, read from a
/// ``PolylineState`` once, so drawing never touches the state again.
struct PolylineTileShape {
    /// Flat `[lat, lng, lat, lng, ...]`, an open path.
    var points: [Double]
    var stroke: CGColor?
    /// On screen, in points.
    var strokeWidth: Double

    init(points: [Double], stroke: CGColor?, strokeWidth: Double) {
        self.points = points
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }

    init(state: PolylineState) {
        let points = state.points
        var flat = [Double]()
        flat.reserveCapacity(points.count * 2)
        for p in points {
            flat.append(p.latitude)
            flat.append(p.longitude)
        }
        self.init(points: flat, stroke: state.strokeColor.cgColor, strokeWidth: state.strokeWidth)
    }
}

/**
 The polylines of one map that are drawn as raster tiles, and their route on the
 local tile server.

 Provider-independent: a provider decides which polylines to tile
 (``PolylineTilingOptions/shouldUseTiles(polylineCount:vertexCount:)``,
 ``canTile(_:)``), hands them to ``setPolylines(_:)``, and shows the returned
 URL template as a raster layer. In-place changes go through ``update(_:)``;
 each batch ends in a new template (the version in it is what makes the map ask
 again), reported to ``onTemplateChanged``. Tiles the change did not touch are
 still cached by the renderer and come back without being redrawn.

 Line widths are on screen: a tile is drawn at the screen scale, so a 3 pt
 line is 3 pt at every zoom, as the map SDKs draw it. The route, version,
 coalescing and teardown are ``ShapeTileSet``'s, shared with ``PolygonTileSet``.

 The iOS counterpart of js-sdk-core's and android-sdk-core's `PolylineTileSet`.
 */
@_spi(MapConductorDriver)
public final class PolylineTileSet {
    public var routeId: String { core.routeId }
    public var tileSize: Int { core.tileSize }
    /// Called on the main thread with the template after a batch of in-place changes.
    public var onTemplateChanged: ((String) -> Void)? {
        get { core.onTemplateChanged }
        set { core.onTemplateChanged = newValue }
    }

    let core: ShapeTileSet<PolylineState>
    var renderer: ShapeTileRenderer { core.renderer }

    public init(pixelRatio: Int = max(1, Int(UIScreen.main.scale.rounded()))) {
        core = ShapeTileSet(
            routePrefix: "polylines",
            pixelRatio: pixelRatio,
            id: { $0.id },
            zIndex: { $0.zIndex },
            shape: { ShapeTileRenderer.Shape(PolylineTileShape(state: $0)) }
        )
    }

    /// Whether a polyline can be drawn in a tile. Geodesic segments are curves
    /// the tile does not trace, and a line spanning half the world or more
    /// crosses the antimeridian; the map SDK draws both. A line needs two points.
    public static func canTile(_ state: PolylineState) -> Bool {
        if state.geodesic { return false }
        let points = state.points
        if points.count < 2 { return false }
        return PolygonTileSet.longitudeSpan(points) < 180
    }

    public static func vertexCount(_ states: [PolylineState]) -> Int {
        var n = 0
        for state in states { n += state.points.count }
        return n
    }

    /// Registers `states` (replacing whatever was registered) and returns the URL
    /// template of their tiles. The geometry is read and projected off the
    /// calling thread.
    public func setPolylines(_ states: [PolylineState]) async -> String? {
        await core.setStates(states)
    }

    public func has(_ id: String) -> Bool {
        core.has(id)
    }

    /// One polyline changed in place. A change of zIndex reorders the list and
    /// needs ``setPolylines(_:)`` instead; everything else is applied here.
    public func update(_ state: PolylineState) {
        core.update(state)
    }

    /// Takes one polyline out of the tiles; only the tiles it was in are drawn again.
    public func remove(_ id: String) {
        core.remove(id)
    }

    /// The URL template of the tiles as they are now, with the version in it.
    public func template() -> String {
        core.template()
    }

    public func dispose() {
        core.dispose()
    }
}
