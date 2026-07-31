import Foundation

/// Thin compatibility layer.
///
/// The implementations that used to live here duplicated other modules: the
/// Vincenty inverse solution duplicated ``GeographicLibCalculator`` (which
/// additionally provides a spherical fallback when the iteration fails to
/// converge), and `computeHeading` / `interpolate` duplicated the spherical
/// formulas in ``Spherical``. The public API is preserved by delegating.
public enum WGS84Geodesic {
    /// WGS84 ellipsoid distance (Vincenty), compatible with Google Maps
    /// geodesic calculations.
    public static func computeDistanceBetween(
        from: GeoPointProtocol,
        to: GeoPointProtocol
    ) -> Double {
        GeographicLibCalculator.computeDistanceBetween(from: from, to: to)
    }

    /// Heading from one point to another, in degrees clockwise from North
    /// within the range (-180, 180].
    public static func computeHeading(
        from: GeoPointProtocol,
        to: GeoPointProtocol
    ) -> Double {
        Spherical.computeHeading(from: from, to: to)
    }

    /// Spherical linear interpolation (Slerp) between two points.
    public static func interpolate(
        from: GeoPointProtocol,
        to: GeoPointProtocol,
        fraction: Double
    ) -> GeoPoint {
        Spherical.sphericalInterpolate(from: from, to: to, fraction: fraction)
    }
}
