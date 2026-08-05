import Foundation

/// The straight-line ("planar") line model: edges are straight lines in lat/lng
/// space (equirectangular), not great circles or geodesics. Mirrors the path-op
/// surface of the earth-model calculators so callers can pick a model by type —
/// e.g. `(geodesic ? WGS84Geodesic.self : Planar.self).createInterpolatePoints(...)`.
public enum Planar {
    /// Straight lat/lng interpolation (handles antimeridian crossing).
    public static func interpolate(
        from: GeoPointProtocol,
        to: GeoPointProtocol,
        fraction: Double
    ) -> GeoPoint {
        let interpolatedAltitude = interpolateAltitude(from: from, to: to, fraction: fraction)
        let interpolatedLatitude = from.latitude + fraction * (to.latitude - from.latitude)

        let fromLng = from.longitude
        let toLng = to.longitude
        let directDiff = toLng - fromLng
        let crossMeridianDiff: Double
        if directDiff > 180 {
            crossMeridianDiff = directDiff - 360
        } else if directDiff < -180 {
            crossMeridianDiff = directDiff + 360
        } else {
            crossMeridianDiff = directDiff
        }
        let interpolatedLongitude = fromLng + fraction * crossMeridianDiff

        return GeoPoint(
            latitude: interpolatedLatitude,
            longitude: normalizeLng(interpolatedLongitude),
            altitude: interpolatedAltitude
        )
    }

    /// Densify a path by inserting points along straight lat/lng lines.
    public static func createInterpolatePoints(
        _ points: [GeoPointProtocol],
        maxSegmentLength: Double = 10_000.0
    ) -> [GeoPointProtocol] {
        densifyAlongStraightLine(points, maxSegmentLength: maxSegmentLength)
    }

    /// Closest point on the straight segment within `thresholdMeters`, or nil.
    public static func pointOnLineOrNull(
        from: GeoPointProtocol,
        to: GeoPointProtocol,
        position: GeoPointProtocol,
        thresholdMeters: Double
    ) -> (GeoPointProtocol, Double)? {
        linearPointOnLineOrNull(from: from, to: to, position: position, thresholdMeters: thresholdMeters)
    }

    private static func normalizeLng(_ lng: Double) -> Double {
        (((lng + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)) - 180.0
    }

    private static func interpolateAltitude(from: GeoPointProtocol, to: GeoPointProtocol, fraction: Double) -> Double {
        switch (from.altitude, to.altitude) {
        case let (f?, t?): return f + fraction * (t - f)
        case let (f?, nil): return f
        case let (nil, t?): return t
        default: return 0.0
        }
    }
}
