import Foundation

/// Tests whether `position` lies within `thresholdMeters` of the straight
/// (planar) segment from `from` to `to`. The earth's curvature is ignored and
/// longitudes are unwrapped along the shorter path (handles ±180° crossings).
///
/// - Returns: The closest point on the segment and the distance in meters, or
///   nil if farther than the threshold.
func isPointOnLinearLine(
    from: GeoPointProtocol,
    to: GeoPointProtocol,
    position: GeoPointProtocol,
    thresholdMeters: Double
) -> (GeoPointProtocol, Double)? {
    // --- Unwrap longitude (take the shorter path). ---
    let fromLng = from.longitude
    let toLng = to.longitude
    let directDiff = toLng - fromLng
    let crossMeridianDiff: Double
    if directDiff > 180.0 {
        crossMeridianDiff = directDiff - 360.0
    } else if directDiff < -180.0 {
        crossMeridianDiff = directDiff + 360.0
    } else {
        crossMeridianDiff = directDiff
    }
    let toLngUnwrapped = fromLng + crossMeridianDiff

    // Unwrap `position` relative to `from` (keep within ±180°).
    func unwrapLngRelative(baseLng: Double, targetLng: Double) -> Double {
        var diff = targetLng - baseLng
        while diff > 180.0 { diff -= 360.0 }
        while diff < -180.0 { diff += 360.0 }
        return baseLng + diff
    }
    let posLngUnwrapped = unwrapLngRelative(baseLng: fromLng, targetLng: position.longitude)

    // --- Lat/lng → planar (meters) approximation. ---
    let lat0Rad = deg2rad((from.latitude + to.latitude) / 2.0)
    let metersPerDegLat = 111_132.954
    let metersPerDegLng = metersPerDegLat * cos(lat0Rad)

    func toMetersPoint(lat: Double, lng: Double) -> (x: Double, y: Double) {
        (x: lng * metersPerDegLng, y: lat * metersPerDegLat)
    }

    let a = toMetersPoint(lat: from.latitude, lng: fromLng)
    let b = toMetersPoint(lat: to.latitude, lng: toLngUnwrapped)
    let pp = toMetersPoint(lat: position.latitude, lng: posLngUnwrapped)

    let segmentVectorX = b.x - a.x
    let segmentVectorY = b.y - a.y
    let pointVectorX = pp.x - a.x
    let pointVectorY = pp.y - a.y
    let segmentLengthSquared = segmentVectorX * segmentVectorX + segmentVectorY * segmentVectorY

    // --- Degenerate: from == to, judged by point distance. ---
    if segmentLengthSquared == 0.0 {
        let deltaX = pp.x - a.x
        let deltaY = pp.y - a.y
        let d = sqrt(deltaX * deltaX + deltaY * deltaY)
        if d > thresholdMeters { return nil }

        let alt = from.altitude ?? to.altitude ?? 0.0
        return (
            GeoPoint(latitude: from.latitude, longitude: normalizeLng(fromLng), altitude: alt),
            d
        )
    }

    // --- Projection onto the segment (closest point). ---
    let t = max(0.0, min(1.0, (pointVectorX * segmentVectorX + pointVectorY * segmentVectorY) / segmentLengthSquared))
    let projectionX = a.x + t * segmentVectorX
    let projectionY = a.y + t * segmentVectorY
    let deltaX = pp.x - projectionX
    let deltaY = pp.y - projectionY
    let distanceMeters = sqrt(deltaX * deltaX + deltaY * deltaY)

    if distanceMeters > thresholdMeters { return nil }

    // --- Map t back to geographic coordinates (same rule as linearInterpolate). ---
    let latitude = from.latitude + t * (to.latitude - from.latitude)
    let longitude = fromLng + t * crossMeridianDiff

    let alt: Double
    switch (from.altitude, to.altitude) {
    case let (fromAlt?, toAlt?):
        alt = fromAlt + t * (toAlt - fromAlt)
    case let (fromAlt?, nil):
        alt = fromAlt
    case let (nil, toAlt?):
        alt = toAlt
    default:
        alt = 0.0
    }

    return (
        GeoPoint(latitude: latitude, longitude: normalizeLng(longitude), altitude: alt),
        distanceMeters
    )
}

private func deg2rad(_ degrees: Double) -> Double { degrees * .pi / 180.0 }

private func normalizeLng(_ lng: Double) -> Double {
    (((lng + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)) - 180.0
}
