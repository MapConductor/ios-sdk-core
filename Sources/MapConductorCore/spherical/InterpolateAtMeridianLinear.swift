import Foundation

/// Performs linear interpolation to find the 180°/-180° meridian crossing point
/// between two points.
func interpolateAtMeridianLinear(
    from: GeoPointProtocol,
    to: GeoPointProtocol
) -> GeoPoint {
    let fromLng = from.longitude
    let toLng = to.longitude

    // Determine which meridian to interpolate to (180 or -180).
    let targetMeridian = fromLng >= 0 ? 180.0 : -180.0

    // Fraction along the segment where the meridian crossing occurs.
    let totalLngDiff = toLng - fromLng
    let meridianDiff = targetMeridian - fromLng
    let fraction = meridianDiff / totalLngDiff

    let latitude = from.latitude + fraction * (to.latitude - from.latitude)
    let altitude: Double
    switch (from.altitude, to.altitude) {
    case let (fromAlt?, toAlt?):
        altitude = fromAlt + fraction * (toAlt - fromAlt)
    case let (fromAlt?, nil):
        altitude = fromAlt
    case let (nil, toAlt?):
        altitude = toAlt
    default:
        altitude = 0.0
    }

    return GeoPoint(latitude: latitude, longitude: targetMeridian, altitude: altitude)
}
