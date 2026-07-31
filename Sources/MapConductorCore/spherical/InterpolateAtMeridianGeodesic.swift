import Foundation

/// Performs geodesic interpolation to find the 180°/-180° meridian crossing
/// point. Uses a binary search to locate where the great-circle path crosses
/// the meridian.
func interpolateAtMeridianGeodesic(
    from: GeoPointProtocol,
    to: GeoPointProtocol
) -> GeoPoint {
    let fromLng = from.longitude

    // Determine target meridian.
    let targetMeridian = fromLng >= 0 ? 180.0 : -180.0

    // Binary search for the crossing point on the great circle.
    var low = 0.0
    var high = 1.0
    let tolerance = 1e-10
    let maxIterations = 50

    var iteration = 0
    while iteration < maxIterations && (high - low) > tolerance {
        let mid = (low + high) / 2.0
        let interpolatedPoint = Spherical.sphericalInterpolate(from: from, to: to, fraction: mid)
        let interpolatedLng = interpolatedPoint.longitude

        // Normalize longitude to handle crossing.
        let normalizedLng: Double
        if interpolatedLng > 180 {
            normalizedLng = interpolatedLng - 360
        } else if interpolatedLng <= -180 {
            normalizedLng = interpolatedLng + 360
        } else {
            normalizedLng = interpolatedLng
        }

        // Which side of the target meridian we're on.
        let onTargetSide = targetMeridian > 0 ? (normalizedLng >= 0) : (normalizedLng < 0)
        let fromOnTargetSide = targetMeridian > 0 ? (fromLng >= 0) : (fromLng < 0)

        if onTargetSide == fromOnTargetSide {
            low = mid
        } else {
            high = mid
        }

        iteration += 1
    }

    // Final interpolation at the crossing point.
    let finalFraction = (low + high) / 2.0
    let crossingPoint = Spherical.sphericalInterpolate(from: from, to: to, fraction: finalFraction)

    // Snap the longitude exactly to the target meridian.
    return GeoPoint(
        latitude: crossingPoint.latitude,
        longitude: targetMeridian,
        altitude: crossingPoint.altitude ?? 0.0
    )
}
