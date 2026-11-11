import CoreGraphics
import Foundation
import UIKit

/// One circle as the tile renderer takes it: plain values, read from a
/// ``CircleState`` once, so drawing never touches the state again.
struct CircleTileShape {
    /// Degrees; the longitude in [-180, 180].
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var geodesic: Bool
    var fill: CGColor?
    var stroke: CGColor?
    /// On screen, in points.
    var strokeWidth: Double

    init(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        geodesic: Bool,
        fill: CGColor?,
        stroke: CGColor?,
        strokeWidth: Double
    ) {
        self.latitude = latitude
        self.longitude = normalizeLngDegrees(longitude)
        self.radiusMeters = radiusMeters
        self.geodesic = geodesic
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }

    init(state: CircleState) {
        let center = state.center
        self.init(
            latitude: center.latitude,
            longitude: center.longitude,
            radiusMeters: state.radiusMeters,
            geodesic: state.geodesic,
            fill: state.fillColor.cgColor,
            stroke: state.strokeColor.cgColor,
            strokeWidth: state.strokeWidth
        )
    }

    /// The circle's extent in degrees, from the same formulas as the native
    /// 128-gon (``circleToRing(center:radiusMeters:geodesic:segments:)``); it
    /// does not depend on the zoom. nil when the circle has no extent.
    var bounds: (north: Double, south: Double, west: Double, east: Double, polar: Bool)? {
        CircleTileShape.bounds(latitude: latitude, longitude: longitude, radiusMeters: radiusMeters, geodesic: geodesic)
    }

    static func bounds(
        latitude: Double, longitude: Double, radiusMeters: Double, geodesic: Bool
    ) -> (north: Double, south: Double, west: Double, east: Double, polar: Bool)? {
        guard radiusMeters > 0, radiusMeters.isFinite, latitude.isFinite, longitude.isFinite else { return nil }
        let phi = latitude * .pi / 180
        let dLat: Double, dLng: Double
        var polar = false
        if geodesic {
            // Spherical.computeOffset's sphere.
            let delta = radiusMeters / Earth.radiusMeters
            dLat = delta * 180 / .pi
            let ratio = sin(delta) / cos(phi)
            // The circle holds a pole: its longitudes go all the way round.
            if !(ratio < 1) || delta >= .pi / 2 { polar = true }
            dLng = asin(min(1, ratio)) * 180 / .pi
        } else {
            let metersPerDegree = Earth.circumferenceMeters / 360
            dLat = radiusMeters / metersPerDegree
            dLng = radiusMeters / (metersPerDegree * max(cos(phi), 1e-6))
        }
        return (latitude + dLat, latitude - dLat, longitude - dLng, longitude + dLng, polar)
    }
}

/**
 The circles of one map that are drawn as raster tiles, and their route on the
 local tile server.

 Provider-independent: a provider decides which circles to tile
 (``CircleTilingOptions/shouldUseTiles(circleCount:)``, ``canTile(_:)``), hands
 them to ``setCircles(_:)``, and shows the returned URL template as a raster
 layer. In-place changes go through ``update(_:)``; each batch ends in a new
 template (the version in it is what makes the map ask again), reported to
 ``onTemplateChanged``. Tiles the change did not touch are still cached by the
 renderer and come back without being redrawn.

 A circle's radius is on the ground (metres), so it grows with the zoom as the
 native circle does; its outline width is on screen (points). It is drawn as
 the native circle is: the same 128-gon where the Mercator projection bends it,
 a true circle where it does not (the two differ by under a quarter of a point).
 The route, version, coalescing and teardown are ``ShapeTileSet``'s, shared
 with ``PolygonTileSet`` and ``PolylineTileSet``.

 The iOS counterpart of js-sdk-core's and android-sdk-core's `CircleTileSet`.
 */
@_spi(MapConductorDriver)
public final class CircleTileSet {
    public var routeId: String { core.routeId }
    public var tileSize: Int { core.tileSize }
    /// Called on the main thread with the template after a batch of in-place changes.
    public var onTemplateChanged: ((String) -> Void)? {
        get { core.onTemplateChanged }
        set { core.onTemplateChanged = newValue }
    }

    let core: ShapeTileSet<CircleState>
    var renderer: ShapeTileRenderer { core.renderer }

    public init(pixelRatio: Int = max(1, Int(UIScreen.main.scale.rounded()))) {
        core = ShapeTileSet(
            routePrefix: "circles",
            pixelRatio: pixelRatio,
            id: { $0.id },
            zIndex: CircleTileSet.effectiveZIndex,
            fileBackedCircles: true,
            shape: { ShapeTileRenderer.Shape(CircleTileShape(state: $0)) }
        )
    }

    /// The zIndex a circle is drawn and hit at: its own, or the one
    /// ``CircleManager`` gives a circle without one (from its centre). The tiles
    /// are drawn in this order so they overlap as the native circles do.
    public static func effectiveZIndex(_ state: CircleState) -> Int {
        if let zIndex = state.zIndex { return zIndex }
        return automaticZIndex(state.center)
    }

    static func automaticZIndex(_ center: GeoPointProtocol) -> Int {
        let value = -center.latitude * 1_000_000.0 - center.longitude
        guard value.isFinite else { return 0 }
        return Int(value.rounded())
    }

    /// Whether a circle can be drawn in a tile: a positive, finite radius, and
    /// clear of the poles (and the edge of the Mercator world) and of the
    /// antimeridian. The map SDK draws the rest.
    public static func canTile(_ state: CircleState) -> Bool {
        let center = state.center
        return canTile(
            latitude: center.latitude, longitude: center.longitude,
            radiusMeters: state.radiusMeters, geodesic: state.geodesic
        )
    }

    static func canTile(latitude: Double, longitude: Double, radiusMeters: Double, geodesic: Bool) -> Bool {
        guard let b = CircleTileShape.bounds(
            latitude: latitude, longitude: normalizeLngDegrees(longitude),
            radiusMeters: radiusMeters, geodesic: geodesic
        ) else { return false }
        return !b.polar
            && b.north < ShapeTileRenderer.maxLatitude && b.south > -ShapeTileRenderer.maxLatitude
            && b.west > -180 && b.east < 180
    }

    /// Registers `states` (replacing whatever was registered) and returns the URL
    /// template of their tiles. The circles are read and projected off the
    /// calling thread.
    public func setCircles(_ states: [CircleState]) async -> String? {
        await core.setStates(states)
    }

    public func has(_ id: String) -> Bool {
        core.has(id)
    }

    /// One circle changed in place. A change of zIndex reorders the list and
    /// needs ``setCircles(_:)`` instead; everything else is applied here.
    public func update(_ state: CircleState) {
        core.update(state)
    }

    /// Takes one circle out of the tiles; only the tiles it was in are drawn again.
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
