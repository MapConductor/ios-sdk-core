import Foundation

/// Tests whether `position` lies within `thresholdMeters` of the geodesic
/// (WGS84 great-circle) segment from `from` to `to`, using a ternary search for
/// the closest point.
///
/// - Returns: The closest point on the segment and the distance in meters, or
///   nil if farther than the threshold.
func geodesicPointOnLineOrNull(
    from: GeoPointProtocol,
    to: GeoPointProtocol,
    position: GeoPointProtocol,
    thresholdMeters: Double
) -> (GeoPointProtocol, Double)? {
    let totalDistance = WGS84Geodesic.computeDistanceBetween(from: from, to: to)

    if totalDistance == 0.0 {
        let distPosFrom = WGS84Geodesic.computeDistanceBetween(from: from, to: position)
        if distPosFrom <= thresholdMeters {
            return (GeoPoint(latitude: from.latitude, longitude: from.longitude, altitude: from.altitude ?? 0.0), distPosFrom)
        }
        return nil
    }

    // Ternary search for the closest point.
    var left = 0.0
    var right = 1.0
    let epsilon = 1e-6

    while right - left > epsilon {
        let m1 = left + (right - left) / 3.0
        let m2 = right - (right - left) / 3.0

        let point1 = WGS84Geodesic.interpolate(from: from, to: to, fraction: m1)
        let dist1 = WGS84Geodesic.computeDistanceBetween(from: point1, to: position)

        let point2 = WGS84Geodesic.interpolate(from: from, to: to, fraction: m2)
        let dist2 = WGS84Geodesic.computeDistanceBetween(from: point2, to: position)

        if dist1 > dist2 {
            left = m1
        } else {
            right = m2
        }
    }

    let bestFraction = (left + right) / 2.0

    // Closest point falls outside the segment.
    if bestFraction <= 0.0 || bestFraction >= 1.0 {
        let distFrom = WGS84Geodesic.computeDistanceBetween(from: from, to: position)
        let distTo = WGS84Geodesic.computeDistanceBetween(from: to, to: position)

        let actualMin = min(distFrom, distTo)
        if actualMin > thresholdMeters { return nil }

        let closest: GeoPoint = distFrom <= distTo
            ? GeoPoint(latitude: from.latitude, longitude: from.longitude, altitude: from.altitude ?? to.altitude ?? 0.0)
            : GeoPoint(latitude: to.latitude, longitude: to.longitude, altitude: to.altitude ?? from.altitude ?? 0.0)
        return (closest, actualMin)
    }

    let closestPoint = WGS84Geodesic.interpolate(from: from, to: to, fraction: bestFraction)
    let minDistance = WGS84Geodesic.computeDistanceBetween(from: closestPoint, to: position)

    if minDistance > thresholdMeters { return nil }

    let altitude: Double
    switch (from.altitude, to.altitude) {
    case let (fromAlt?, toAlt?):
        altitude = fromAlt + bestFraction * (toAlt - fromAlt)
    case let (fromAlt?, nil):
        altitude = fromAlt
    case let (nil, toAlt?):
        altitude = toAlt
    default:
        altitude = 0.0
    }

    let result = GeoPoint(latitude: closestPoint.latitude, longitude: closestPoint.longitude, altitude: altitude)
    return (result, minDistance)
}
