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
    // The raw difference exceeds 180° for an antimeridian-crossing segment (the
    // only case this function is called for), so unwrap it to the short-way
    // signed span; otherwise the fraction comes out negative and the latitude is
    // extrapolated in the wrong direction.
    let directDiff = toLng - fromLng
    let totalLngDiff: Double
    if directDiff > 180.0 {
        totalLngDiff = directDiff - 360.0
    } else if directDiff < -180.0 {
        totalLngDiff = directDiff + 360.0
    } else {
        totalLngDiff = directDiff
    }
    let meridianDiff = targetMeridian - fromLng
    let fraction = totalLngDiff == 0.0 ? 0.0 : min(1.0, max(0.0, meridianDiff / totalLngDiff))

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
