import CoreGraphics
import Foundation

/**
 How ``ShapeTileRenderer`` draws a circle: the circle part of the shared
 renderer, as ``PolylineTileShape`` and ``PolygonTileShape`` are for the others
 (android-sdk-core's `CircleTilePainter`, js-sdk-core's tile-sw.js circles).

 Per zoom (the world `scale` points wide), from the centre and the extent of
 the native 128-gon (north, south and east of the centre):

 - **Dot**: under one point across. One point at the floored centre, in the
   fill colour when it is visible and in the outline colour otherwise (a
   polygon's dot).
 - **Arc**: north and south radii within a quarter of a point of the east one.
   A true circle of the east radius. Every circle of a city at every zoom.
 - **Ring**: otherwise (kilometre circles zoomed in, high latitudes). The native
   ``circleToRing(center:radiusMeters:geodesic:segments:)`` 128-gon, snapped to
   the zoom's pixel grid, repeats dropped, Douglas-Peucker at half a point, as a
   polygon's ring.

 The fill is nonzero; the outline is drawn centred on the edge, `strokeWidth`
 points wide (half of it outside), and not at all under 4 points across, as
 for a polygon.
 */
enum CircleTilePainter {
    /// A circle in Web Mercator units ([0, 1]), plus what the Ring needs.
    final class Geometry {
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
        let geodesic: Bool
        let x: Double, y: Double
        let northY: Double, southY: Double, westX: Double, eastX: Double

        private let ringLock = NSLock()
        private var cachedRing: [Double]?

        /// The spherical 128-gon and projection do not change with zoom.
        var mercatorRing: [Double] {
            ringLock.lock()
            defer { ringLock.unlock() }
            if let cachedRing { return cachedRing }
            let ring = circleToRing(
                center: GeoPoint(latitude: latitude, longitude: longitude),
                radiusMeters: radiusMeters, geodesic: geodesic
            )
            var flat: [Double] = []
            flat.reserveCapacity(ring.count * 2)
            for point in ring { flat.append(point.latitude); flat.append(point.longitude) }
            let projected = ShapeTileRenderer.toMercator(flat)
            cachedRing = projected
            return projected
        }

        convenience init?(_ shape: CircleTileShape) {
            guard let b = shape.bounds else { return nil }
            let m = ShapeTileRenderer.toMercator([
                shape.latitude, shape.longitude,
                b.north, b.east,
                b.south, b.west,
            ])
            self.init(latitude: shape.latitude, longitude: shape.longitude, radiusMeters: shape.radiusMeters,
                      geodesic: shape.geodesic, x: m[0], y: m[1], northY: m[3], southY: m[5], westX: m[4], eastX: m[2])
        }

        init(latitude: Double, longitude: Double, radiusMeters: Double, geodesic: Bool,
             x: Double, y: Double, northY: Double, southY: Double, westX: Double, eastX: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.radiusMeters = radiusMeters
            self.geodesic = geodesic
            self.x = x; self.y = y
            self.northY = northY; self.southY = southY
            self.westX = westX; self.eastX = eastX
        }
    }

    /// Below this difference (points) between the east radius and the north or
    /// south one, the circle is drawn as a true circle.
    static let arcTolerancePx = 0.25

    /// Classify tiny circles before constructing a projected shape or hash key.
    /// -2 is a normal circle; -1 is a dot outside this tile.
    static func subpixelSlot(_ p: ShapeTileRenderer.Shape, scale: Double, originX: Double, originY: Double, tileSize: Int) -> Int {
        guard let c = p.circle else { return -2 }
        let radius = max(c.eastX - c.x, c.y - c.northY, c.southY - c.y) * scale
        guard radius < 0.5 else { return -2 }
        let x = floor(c.x * scale) - originX
        let y = floor(c.y * scale) - originY
        guard x >= 0, x < Double(tileSize), y >= 0, y < Double(tileSize) else { return -1 }
        return Int(y) * tileSize + Int(x)
    }

    static func simplify(_ p: ShapeTileRenderer.Shape, scale: Double) -> ShapeTileRenderer.Simplified {
        guard let c = p.circle else { return .none }
        let cx = c.x * scale, cy = c.y * scale
        let rx = (c.eastX - c.x) * scale
        let ryN = (c.y - c.northY) * scale
        let ryS = (c.southY - c.y) * scale
        let size = max(rx, ryN, ryS)
        if size < 0.5 {
            return .dot(floor(cx), floor(cy))
        }
        let outlined = 2 * size >= ShapeTileRenderer.minOutlinedPx
        if max(abs(ryN - rx), abs(ryS - rx)) <= arcTolerancePx {
            return .arc(cx, cy, rx, outlined: outlined)
        }
        guard let simplified = ShapeTileRenderer.simplifyRing(c.mercatorRing, scale: scale) else {
            return .arc(cx, cy, rx, outlined: outlined)
        }
        return .rings([simplified], outlined: outlined)
    }

    /// Draws an Arc at tile coordinates (points); true when anything was drawn.
    static func drawArc(
        _ p: ShapeTileRenderer.Shape, in context: CGContext,
        cx: Double, cy: Double, radius: Double, outlined: Bool
    ) -> Bool {
        let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        var drew = false
        if let fill = p.fill {
            context.setFillColor(fill)
            context.fillEllipse(in: rect)
            drew = true
        }
        if outlined, let stroke = p.stroke {
            context.setStrokeColor(stroke)
            context.setLineWidth(CGFloat(p.strokeWidth))
            context.strokeEllipse(in: rect)
            drew = true
        }
        return drew
    }
}
