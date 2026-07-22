import Foundation

/// WGS84 ellipsoid parameters. https://epsg.org/ellipsoid_7030/WGS-84.html
public enum Earth {
    /// WGS84 semi-major axis (equatorial radius) in meters.
    public static let radiusMeters: Double = 6_378_137.0

    /// Equatorial circumference (2πa) in meters.
    public static let circumferenceMeters: Double = 2.0 * Double.pi * radiusMeters

    /// WGS84 flattening f = 1 / 298.257223563.
    public static let flattening: Double = 1.0 / 298.257_223_563

    /// WGS84 semi-minor axis (polar radius) b = a(1 - f) in meters.
    public static let semiMinorAxisMeters: Double = radiusMeters * (1.0 - flattening)

    /// WGS84 first eccentricity squared e² = f(2 - f).
    public static let eccentricitySquared: Double = flattening * (2.0 - flattening)
}
