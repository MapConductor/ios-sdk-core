import Foundation
import UIKit

/**
 The polygons of one map that are drawn as raster tiles, and their route on the
 local tile server.

 Provider-independent: a provider decides which polygons to tile
 (``PolygonTilingOptions/shouldUseTiles(polygonCount:vertexCount:)``,
 ``canTile(_:)``), hands them to ``setPolygons(_:)``, and shows the returned URL
 template as a raster layer. In-place changes go through ``update(_:)``; each
 batch ends in a new template (the version in it is what makes the map ask
 again), reported to ``onTemplateChanged``. Tiles the change did not touch are
 still cached by the renderer and come back without being redrawn.

 The iOS counterpart of js-sdk-core's `PolygonTileSet`. The route, version,
 coalescing and teardown are ``ShapeTileSet``'s, shared with ``PolylineTileSet``. There the polygons cross
 to a service worker as Encoded Polylines; here the renderer is in the same
 process and takes them as they are.
 */
@_spi(MapConductorDriver)
public final class PolygonTileSet {
    /// In-place changes arriving within this window become one new template.
    static let updateCoalesceMs = 16

    public var routeId: String { core.routeId }
    public var tileSize: Int { core.tileSize }
    /// Called on the main thread with the template after a batch of in-place changes.
    public var onTemplateChanged: ((String) -> Void)? {
        get { core.onTemplateChanged }
        set { core.onTemplateChanged = newValue }
    }

    let core: ShapeTileSet<PolygonState>
    var renderer: PolygonTileRenderer { core.renderer }

    public init(pixelRatio: Int = max(1, Int(UIScreen.main.scale.rounded()))) {
        core = ShapeTileSet(
            routePrefix: "polygons",
            pixelRatio: pixelRatio,
            id: { $0.id },
            zIndex: { $0.zIndex },
            shape: { ShapeTileRenderer.Shape(PolygonTileShape(state: $0)) }
        )
    }

    /// Whether a polygon can be drawn in a tile. Geodesic edges are curves the
    /// tile does not trace, and a ring spanning half the world or more crosses
    /// the antimeridian; the map SDK draws both.
    public static func canTile(_ state: PolygonState) -> Bool {
        if state.geodesic { return false }
        let points = state.points
        if points.count < 3 { return false }
        return longitudeSpan(points) < 180
    }

    static func longitudeSpan(_ points: [GeoPointProtocol]) -> Double {
        var minLng = Double.infinity, maxLng = -Double.infinity
        for p in points {
            minLng = min(minLng, p.longitude)
            maxLng = max(maxLng, p.longitude)
        }
        return maxLng - minLng
    }

    public static func vertexCount(_ states: [PolygonState]) -> Int {
        var n = 0
        for state in states {
            n += state.points.count
            for hole in state.holes { n += hole.count }
        }
        return n
    }

    /// Registers `states` (replacing whatever was registered) and returns the URL
    /// template of their tiles. The geometry is read and projected off the
    /// calling thread.
    public func setPolygons(_ states: [PolygonState]) async -> String? {
        await core.setStates(states)
    }

    public func has(_ id: String) -> Bool {
        core.has(id)
    }

    /// One polygon changed in place. A change of zIndex reorders the list and
    /// needs ``setPolygons(_:)`` instead; everything else is applied here.
    public func update(_ state: PolygonState) {
        core.update(state)
    }

    /// Takes one polygon out of the tiles. Its slot in the renderer's list is
    /// left empty, so the others keep their indices and only the tiles it was
    /// in are drawn again.
    public func remove(_ id: String) {
        core.remove(id)
    }

    /// The URL template of the tiles as they are now. Read from the server each
    /// time: it moves to a new port when the app comes back from the background.
    public func template() -> String {
        core.template()
    }

    public func dispose() {
        core.dispose()
    }
}
