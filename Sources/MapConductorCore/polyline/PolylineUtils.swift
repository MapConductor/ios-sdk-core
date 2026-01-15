import Foundation

private enum PolylineEarth {
    // Used for Web Mercator meters-per-pixel computations.
    static let radiusMeters: Double = 6_378_137.0
    static let circumferenceMeters: Double = 2.0 * Double.pi * radiusMeters
}

public func calculateMetersPerPixel(
    latitude: Double,
    zoom: Double,
    // Match Android/Web Mercator convention where zoom is defined against a 256px tile.
    tileSize: Double = 256.0
) -> Double {
    let metersPerPixelAtEquator = PolylineEarth.circumferenceMeters / tileSize
    let metersPerPixelAtZoom = metersPerPixelAtEquator / pow(2.0, zoom)
    let latitudeAdjustment = cos(deg2rad(abs(latitude)))
    return metersPerPixelAtZoom * latitudeAdjustment
}

public func createInterpolatePoints(
    _ points: [GeoPointProtocol],
    maxSegmentLength: Double = 10_000.0
) -> [GeoPointProtocol] {
    guard points.count >= 2 else { return points }
    var results: [GeoPointProtocol] = [points[0]]

    for index in 1..<points.count {
        let from = points[index - 1]
        let to = points[index]
        let inv = vincentyInverseMeters(
            lat1: from.latitude,
            lon1: from.longitude,
            lat2: to.latitude,
            lon2: to.longitude
        )
        let distance = inv?.distanceMeters ?? haversineDistanceMeters(from: from, to: to)
        let segments = max(1, Int(distance / maxSegmentLength))
        let step = 1.0 / Double(segments)

        var fraction = step
        while fraction < 1.0 {
            if let inv {
                if let dst = vincentyDirect(
                    lat1: from.latitude,
                    lon1: from.longitude,
                    alpha1Rad: inv.initialBearingRad,
                    distanceMeters: distance * fraction
                ) {
                    let altitude = interpolateAltitude(from: from, to: to, fraction: fraction)
                    results.append(GeoPoint(latitude: dst.lat2, longitude: dst.lon2, altitude: altitude))
                } else {
                    results.append(geodesicInterpolate(from: from, to: to, fraction: fraction))
                }
            } else {
                let spherical = sphericalGeodesicInterpolate(from: from, to: to, fraction: fraction)
                let altitude = interpolateAltitude(from: from, to: to, fraction: fraction)
                results.append(GeoPoint(latitude: spherical.latitude, longitude: spherical.longitude, altitude: altitude))
            }
            fraction += step
        }
        results.append(to)
    }
    return results
}

public func createLinearInterpolatePoints(
    _ points: [GeoPointProtocol],
    fractionStep: Double = 0.01
) -> [GeoPointProtocol] {
    guard points.count >= 2 else { return points }
    var results: [GeoPointProtocol] = [points[0]]

    for index in 1..<points.count {
        let from = points[index - 1]
        let to = points[index]
        var fraction = fractionStep
        while fraction <= 1.0 {
            results.append(linearInterpolate(from: from, to: to, fraction: fraction))
            fraction += fractionStep
        }
        results.append(to)
    }
    return results
}

public func splitByMeridian(
    _ points: [GeoPointProtocol],
    geodesic: Bool
) -> [[GeoPointProtocol]] {
    guard !points.isEmpty else { return [] }
    var results: [[GeoPointProtocol]] = []
    var fragment: [GeoPointProtocol] = []

    for point in points {
        if fragment.isEmpty {
            fragment.append(point)
            continue
        }

        let previousPoint = fragment.last!
        let prevLng = previousPoint.longitude
        let currLng = point.longitude
        let lngDiff = currLng - prevLng
        let crossesMeridian = abs(lngDiff) > 180.0

        if !crossesMeridian {
            fragment.append(point)
            continue
        }

        let meridianPoint = interpolateAtMeridian(from: previousPoint, to: point, geodesic: geodesic)
        fragment.append(meridianPoint)
        results.append(fragment)
        fragment = []

        let opposite = createOppositeMeridianPoint(meridianPoint)
        fragment.append(opposite)
        fragment.append(point)
    }

    if !fragment.isEmpty {
        results.append(fragment)
    }

    return results
}

func pointOnGeodesicSegmentOrNull(
    from: GeoPointProtocol,
    to: GeoPointProtocol,
    position: GeoPointProtocol,
    thresholdMeters: Double
) -> (GeoPointProtocol, Double)? {
    guard let line = vincentyInverseMeters(
        lat1: from.latitude,
        lon1: from.longitude,
        lat2: to.latitude,
        lon2: to.longitude
    ) else {
        // Fallback to spherical distance/interpolation if Vincenty fails to converge.
        let totalDistance = haversineDistanceMeters(from: from, to: to)
        if totalDistance == 0.0 {
            let distFrom = haversineDistanceMeters(from: from, to: position)
            if distFrom <= thresholdMeters {
                return (GeoPoint.from(position: from), distFrom)
            }
            return nil
        }

        var left = 0.0
        var right = 1.0
        let epsilon = 1e-6

        while right - left > epsilon {
            let m1 = left + (right - left) / 3.0
            let m2 = right - (right - left) / 3.0

            let point1 = sphericalGeodesicInterpolate(from: from, to: to, fraction: m1)
            let dist1 = haversineDistanceMeters(from: point1, to: position)

            let point2 = sphericalGeodesicInterpolate(from: from, to: to, fraction: m2)
            let dist2 = haversineDistanceMeters(from: point2, to: position)

            if dist1 > dist2 {
                left = m1
            } else {
                right = m2
            }
        }

        let bestFraction = (left + right) / 2.0
        if bestFraction <= 0.0 || bestFraction >= 1.0 {
            let distFrom = haversineDistanceMeters(from: from, to: position)
            let distTo = haversineDistanceMeters(from: to, to: position)
            let minDistance = min(distFrom, distTo)
            if minDistance > thresholdMeters { return nil }

            let chosen = distFrom <= distTo ? from : to
            return (GeoPoint.from(position: chosen), minDistance)
        }

        let closestPoint = sphericalGeodesicInterpolate(from: from, to: to, fraction: bestFraction)
        let minDistance = haversineDistanceMeters(from: closestPoint, to: position)
        if minDistance > thresholdMeters { return nil }

        let altitude = interpolateAltitude(from: from, to: to, fraction: bestFraction)
        return (GeoPoint(latitude: closestPoint.latitude, longitude: closestPoint.longitude, altitude: altitude), minDistance)
    }

    let totalDistance = line.distanceMeters
    if totalDistance == 0.0 {
        let distFrom = wgs84DistanceMeters(from: from, to: position)
        if distFrom <= thresholdMeters {
            return (GeoPoint.from(position: from), distFrom)
        }
        return nil
    }

    var left = 0.0
    var right = 1.0
    let epsilon = 1e-6

    while right - left > epsilon {
        let m1 = left + (right - left) / 3.0
        let m2 = right - (right - left) / 3.0

        let point1: GeoPointProtocol
        if let dst = vincentyDirect(
            lat1: from.latitude,
            lon1: from.longitude,
            alpha1Rad: line.initialBearingRad,
            distanceMeters: totalDistance * m1
        ) {
            point1 = GeoPoint(latitude: dst.lat2, longitude: dst.lon2)
        } else {
            point1 = geodesicInterpolate(from: from, to: to, fraction: m1)
        }
        let dist1 = wgs84DistanceMeters(from: point1, to: position)

        let point2: GeoPointProtocol
        if let dst = vincentyDirect(
            lat1: from.latitude,
            lon1: from.longitude,
            alpha1Rad: line.initialBearingRad,
            distanceMeters: totalDistance * m2
        ) {
            point2 = GeoPoint(latitude: dst.lat2, longitude: dst.lon2)
        } else {
            point2 = geodesicInterpolate(from: from, to: to, fraction: m2)
        }
        let dist2 = wgs84DistanceMeters(from: point2, to: position)

        if dist1 > dist2 {
            left = m1
        } else {
            right = m2
        }
    }

    let bestFraction = (left + right) / 2.0

    if bestFraction <= 0.0 || bestFraction >= 1.0 {
        let distFrom = wgs84DistanceMeters(from: from, to: position)
        let distTo = wgs84DistanceMeters(from: to, to: position)
        let minDistance = min(distFrom, distTo)
        if minDistance > thresholdMeters { return nil }

        let chosen = distFrom <= distTo ? from : to
        return (GeoPoint.from(position: chosen), minDistance)
    }

    let closestPoint: GeoPointProtocol
    if let dst = vincentyDirect(
        lat1: from.latitude,
        lon1: from.longitude,
        alpha1Rad: line.initialBearingRad,
        distanceMeters: totalDistance * bestFraction
    ) {
        closestPoint = GeoPoint(latitude: dst.lat2, longitude: dst.lon2)
    } else {
        closestPoint = geodesicInterpolate(from: from, to: to, fraction: bestFraction)
    }
    let minDistance = wgs84DistanceMeters(from: closestPoint, to: position)
    if minDistance > thresholdMeters { return nil }

    let altitude = interpolateAltitude(from: from, to: to, fraction: bestFraction)
    return (GeoPoint(latitude: closestPoint.latitude, longitude: closestPoint.longitude, altitude: altitude), minDistance)
}

func isPointOnLinearLine(
    from: GeoPointProtocol,
    to: GeoPointProtocol,
    position: GeoPointProtocol,
    thresholdMeters: Double
) -> (GeoPointProtocol, Double)? {
    let fromLng = from.longitude
    let directDiff = to.longitude - fromLng
    let crossMeridianDiff: Double
    if directDiff > 180.0 {
        crossMeridianDiff = directDiff - 360.0
    } else if directDiff < -180.0 {
        crossMeridianDiff = directDiff + 360.0
    } else {
        crossMeridianDiff = directDiff
    }

    func unwrapLngRelative(baseLng: Double, targetLng: Double) -> Double {
        var diff = targetLng - baseLng
        while diff > 180.0 { diff -= 360.0 }
        while diff < -180.0 { diff += 360.0 }
        return baseLng + diff
    }

    let toLngUnwrapped = fromLng + crossMeridianDiff
    let posLngUnwrapped = unwrapLngRelative(baseLng: fromLng, targetLng: position.longitude)

    let lat0Rad = deg2rad((from.latitude + to.latitude) / 2.0)
    let metersPerDegLat = 111_132.954
    let metersPerDegLng = metersPerDegLat * cos(lat0Rad)

    func toMetersPoint(lat: Double, lng: Double) -> (Double, Double) {
        (lng * metersPerDegLng, lat * metersPerDegLat)
    }

    let a = toMetersPoint(lat: from.latitude, lng: fromLng)
    let b = toMetersPoint(lat: to.latitude, lng: toLngUnwrapped)
    let pp = toMetersPoint(lat: position.latitude, lng: posLngUnwrapped)

    let segmentVectorX = b.0 - a.0
    let segmentVectorY = b.1 - a.1
    let pointVectorX = pp.0 - a.0
    let pointVectorY = pp.1 - a.1
    let segmentLengthSquared = segmentVectorX * segmentVectorX + segmentVectorY * segmentVectorY

    if segmentLengthSquared == 0.0 {
        let deltaX = pp.0 - a.0
        let deltaY = pp.1 - a.1
        let d = sqrt(deltaX * deltaX + deltaY * deltaY)
        if d > thresholdMeters { return nil }
        let altitude = from.altitude ?? to.altitude ?? 0.0
        return (
            GeoPoint(latitude: from.latitude, longitude: normalizeLng(fromLng), altitude: altitude),
            d
        )
    }

    let t = max(0.0, min(1.0, (pointVectorX * segmentVectorX + pointVectorY * segmentVectorY) / segmentLengthSquared))
    let projectionX = a.0 + t * segmentVectorX
    let projectionY = a.1 + t * segmentVectorY
    let deltaX = pp.0 - projectionX
    let deltaY = pp.1 - projectionY
    let distanceMeters = sqrt(deltaX * deltaX + deltaY * deltaY)

    if distanceMeters > thresholdMeters { return nil }

    let latitude = from.latitude + t * (to.latitude - from.latitude)
    let longitude = fromLng + t * crossMeridianDiff
    let altitude = interpolateAltitude(from: from, to: to, fraction: t)

    return (
        GeoPoint(latitude: latitude, longitude: normalizeLng(longitude), altitude: altitude),
        distanceMeters
    )
}

private func interpolateAtMeridian(
    from: GeoPointProtocol,
    to: GeoPointProtocol,
    geodesic: Bool
) -> GeoPoint {
    if geodesic {
        return interpolateAtMeridianGeodesic(from: from, to: to)
    }
    return interpolateAtMeridianLinear(from: from, to: to)
}

private func interpolateAtMeridianLinear(
    from: GeoPointProtocol,
    to: GeoPointProtocol
) -> GeoPoint {
    let fromLng = from.longitude
    let toLng = to.longitude
    let targetMeridian = fromLng >= 0 ? 180.0 : -180.0
    let totalLngDiff = toLng - fromLng
    let meridianDiff = targetMeridian - fromLng
    let fraction = meridianDiff / totalLngDiff

    let latitude = from.latitude + fraction * (to.latitude - from.latitude)
    let altitude = interpolateAltitude(from: from, to: to, fraction: fraction)

    return GeoPoint(latitude: latitude, longitude: targetMeridian, altitude: altitude)
}

private func interpolateAtMeridianGeodesic(
    from: GeoPointProtocol,
    to: GeoPointProtocol
) -> GeoPoint {
    let fromLng = from.longitude
    let targetMeridian = fromLng >= 0 ? 180.0 : -180.0
    let targetUnwrapped = unwrapLngRelative(baseLng: fromLng, targetLng: targetMeridian)

    var low = 0.0
    var high = 1.0
    for _ in 0..<60 {
        let mid = (low + high) / 2.0
        let point = geodesicInterpolate(from: from, to: to, fraction: mid)
        let midLng = unwrapLngRelative(baseLng: fromLng, targetLng: point.longitude)

        if midLng < targetUnwrapped {
            low = mid
        } else {
            high = mid
        }
    }

    let finalFraction = (low + high) / 2.0
    let crossingPoint = geodesicInterpolate(from: from, to: to, fraction: finalFraction)

    return GeoPoint(latitude: crossingPoint.latitude, longitude: targetMeridian, altitude: crossingPoint.altitude ?? 0.0)
}

private func createOppositeMeridianPoint(_ point: GeoPointProtocol) -> GeoPoint {
    let oppositeLongitude = point.longitude >= 0 ? -180.0 : 180.0
    return GeoPoint(latitude: point.latitude, longitude: oppositeLongitude, altitude: point.altitude ?? 0.0)
}

private func geodesicInterpolate(
    from: GeoPointProtocol,
    to: GeoPointProtocol,
    fraction: Double
) -> GeoPoint {
    let f = max(0.0, min(1.0, fraction))
    let altitude = interpolateAltitude(from: from, to: to, fraction: f)

    // Prefer WGS84 ellipsoid geodesic; fall back to spherical interpolation if Vincenty fails to converge.
    if let point = wgs84Interpolate(from: from, to: to, fraction: f) {
        return GeoPoint(latitude: point.latitude, longitude: point.longitude, altitude: altitude)
    }
    let spherical = sphericalGeodesicInterpolate(from: from, to: to, fraction: f)
    return GeoPoint(latitude: spherical.latitude, longitude: spherical.longitude, altitude: altitude)
}

private func linearInterpolate(
    from: GeoPointProtocol,
    to: GeoPointProtocol,
    fraction: Double
) -> GeoPoint {
    let f = max(0.0, min(1.0, fraction))
    let latitude = from.latitude + (to.latitude - from.latitude) * f
    let fromLng = from.longitude
    let directDiff = to.longitude - fromLng
    let crossMeridianDiff: Double
    if directDiff > 180.0 {
        crossMeridianDiff = directDiff - 360.0
    } else if directDiff < -180.0 {
        crossMeridianDiff = directDiff + 360.0
    } else {
        crossMeridianDiff = directDiff
    }
    let longitude = normalizeLng(fromLng + crossMeridianDiff * f)
    let altitude = interpolateAltitude(from: from, to: to, fraction: f)
    return GeoPoint(latitude: latitude, longitude: longitude, altitude: altitude)
}

private func interpolateAltitude(from: GeoPointProtocol, to: GeoPointProtocol, fraction: Double) -> Double {
    let f = max(0.0, min(1.0, fraction))
    switch (from.altitude, to.altitude) {
    case let (fromAlt?, toAlt?):
        return fromAlt + (toAlt - fromAlt) * f
    case let (fromAlt?, nil):
        return fromAlt
    case let (nil, toAlt?):
        return toAlt
    default:
        return 0.0
    }
}

private func wgs84DistanceMeters(from: GeoPointProtocol, to: GeoPointProtocol) -> Double {
    if let meters = vincentyInverseMeters(
        lat1: from.latitude,
        lon1: from.longitude,
        lat2: to.latitude,
        lon2: to.longitude
    )?.distanceMeters {
        return meters
    }
    // Fallback to spherical distance (Web Mercator radius) if Vincenty fails to converge.
    return haversineDistanceMeters(from: from, to: to)
}

private func wgs84Interpolate(from: GeoPointProtocol, to: GeoPointProtocol, fraction: Double) -> GeoPointProtocol? {
    let f = max(0.0, min(1.0, fraction))
    guard let inv = vincentyInverseMeters(
        lat1: from.latitude,
        lon1: from.longitude,
        lat2: to.latitude,
        lon2: to.longitude
    ) else {
        return nil
    }
    let s = inv.distanceMeters * f
    guard let dst = vincentyDirect(
        lat1: from.latitude,
        lon1: from.longitude,
        alpha1Rad: inv.initialBearingRad,
        distanceMeters: s
    ) else {
        return nil
    }
    return GeoPoint(latitude: dst.lat2, longitude: dst.lon2, altitude: 0.0)
}

private func haversineDistanceMeters(from: GeoPointProtocol, to: GeoPointProtocol) -> Double {
    let lat1 = deg2rad(from.latitude)
    let lon1 = deg2rad(from.longitude)
    let lat2 = deg2rad(to.latitude)
    let lon2 = deg2rad(to.longitude)

    let dLat = lat2 - lat1
    let dLon = lon2 - lon1

    let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return PolylineEarth.radiusMeters * c
}

private func sphericalGeodesicInterpolate(from: GeoPointProtocol, to: GeoPointProtocol, fraction: Double) -> GeoPoint {
    let f = max(0.0, min(1.0, fraction))
    let lat1 = deg2rad(from.latitude)
    let lon1 = deg2rad(from.longitude)
    let lat2 = deg2rad(to.latitude)
    let lon2 = deg2rad(to.longitude)

    let v1 = (
        x: cos(lat1) * cos(lon1),
        y: cos(lat1) * sin(lon1),
        z: sin(lat1)
    )
    let v2 = (
        x: cos(lat2) * cos(lon2),
        y: cos(lat2) * sin(lon2),
        z: sin(lat2)
    )

    var dot = v1.x * v2.x + v1.y * v2.y + v1.z * v2.z
    dot = min(1.0, max(-1.0, dot))
    let omega = acos(dot)
    if abs(omega) < 1e-12 {
        return GeoPoint.from(position: from)
    }

    let sinOmega = sin(omega)
    let t1 = sin((1.0 - f) * omega) / sinOmega
    let t2 = sin(f * omega) / sinOmega

    let x = t1 * v1.x + t2 * v2.x
    let y = t1 * v1.y + t2 * v2.y
    let z = t1 * v1.z + t2 * v2.z

    let lat = atan2(z, sqrt(x * x + y * y))
    let lon = atan2(y, x)

    return GeoPoint(latitude: rad2deg(lat), longitude: rad2deg(lon), altitude: 0.0)
}

// MARK: - Vincenty (WGS84 Ellipsoid)

private enum WGS84 {
    static let a: Double = 6_378_137.0
    static let f: Double = 1.0 / 298.257_223_563
    static let b: Double = a * (1.0 - f)
}

private struct VincentyInverseResult {
    let distanceMeters: Double
    let initialBearingRad: Double
    let finalBearingRad: Double
}

private func normalizeRadians(_ x: Double) -> Double {
    var v = x
    while v > Double.pi { v -= 2.0 * Double.pi }
    while v < -Double.pi { v += 2.0 * Double.pi }
    return v
}

// Vincenty inverse formula.
// Returns nil if it fails to converge (near-antipodal cases can fail).
private func vincentyInverseMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> VincentyInverseResult? {
    if lat1 == lat2, lon1 == lon2 {
        return VincentyInverseResult(distanceMeters: 0.0, initialBearingRad: 0.0, finalBearingRad: 0.0)
    }

    let a = WGS84.a
    let b = WGS84.b
    let f = WGS84.f

    let phi1 = deg2rad(lat1)
    let phi2 = deg2rad(lat2)
    let l1 = deg2rad(lon1)
    let l2 = deg2rad(lon2)

    let u1 = atan((1.0 - f) * tan(phi1))
    let u2 = atan((1.0 - f) * tan(phi2))

    let sinU1 = sin(u1)
    let cosU1 = cos(u1)
    let sinU2 = sin(u2)
    let cosU2 = cos(u2)

    var lambda = normalizeRadians(l2 - l1)
    var prevLambda = 0.0

    var sinSigma = 0.0
    var cosSigma = 0.0
    var sigma = 0.0
    var sinAlpha = 0.0
    var cos2Alpha = 0.0
    var cos2SigmaM = 0.0

    for _ in 0..<200 {
        let sinLambda = sin(lambda)
        let cosLambda = cos(lambda)

        let x = cosU2 * sinLambda
        let y = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
        sinSigma = sqrt(x * x + y * y)
        if sinSigma == 0.0 {
            return VincentyInverseResult(distanceMeters: 0.0, initialBearingRad: 0.0, finalBearingRad: 0.0)
        }
        cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
        sigma = atan2(sinSigma, cosSigma)

        sinAlpha = (cosU1 * cosU2 * sinLambda) / sinSigma
        cos2Alpha = 1.0 - sinAlpha * sinAlpha

        if cos2Alpha != 0.0 {
            cos2SigmaM = cosSigma - (2.0 * sinU1 * sinU2) / cos2Alpha
        } else {
            cos2SigmaM = 0.0
        }

        let c = (f / 16.0) * cos2Alpha * (4.0 + f * (4.0 - 3.0 * cos2Alpha))

        prevLambda = lambda
        lambda =
            normalizeRadians(
                (l2 - l1) + (1.0 - c) * f * sinAlpha * (
                    sigma +
                        c * sinSigma * (
                            cos2SigmaM + c * cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM)
                        )
                )
            )

        if abs(lambda - prevLambda) < 1e-12 {
            break
        }
    }

    if abs(lambda - prevLambda) >= 1e-10 {
        return nil
    }

    let uSq = cos2Alpha * (a * a - b * b) / (b * b)
    let aCoeff = 1.0 + (uSq / 16384.0) * (4096.0 + uSq * (-768.0 + uSq * (320.0 - 175.0 * uSq)))
    let bCoeff = (uSq / 1024.0) * (256.0 + uSq * (-128.0 + uSq * (74.0 - 47.0 * uSq)))
    let deltaSigma =
        bCoeff * sinSigma * (
            cos2SigmaM + (bCoeff / 4.0) * (
                cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM) -
                    (bCoeff / 6.0) * cos2SigmaM * (-3.0 + 4.0 * sinSigma * sinSigma) * (-3.0 + 4.0 * cos2SigmaM * cos2SigmaM)
            )
        )

    let s = b * aCoeff * (sigma - deltaSigma)

    let alpha1 = atan2(cosU2 * sin(lambda), cosU1 * sinU2 - sinU1 * cosU2 * cos(lambda))
    let alpha2 = atan2(cosU1 * sin(lambda), -sinU1 * cosU2 + cosU1 * sinU2 * cos(lambda))

    return VincentyInverseResult(distanceMeters: s, initialBearingRad: normalizeRadians(alpha1), finalBearingRad: normalizeRadians(alpha2))
}

private struct VincentyDirectResult {
    let lat2: Double
    let lon2: Double
    let alpha2Rad: Double
}

// Vincenty direct formula.
private func vincentyDirect(lat1: Double, lon1: Double, alpha1Rad: Double, distanceMeters: Double) -> VincentyDirectResult? {
    let a = WGS84.a
    let b = WGS84.b
    let f = WGS84.f

    let phi1 = deg2rad(lat1)
    let l1 = deg2rad(lon1)

    let sinAlpha1 = sin(alpha1Rad)
    let cosAlpha1 = cos(alpha1Rad)

    let u1 = atan((1.0 - f) * tan(phi1))
    let sinU1 = sin(u1)
    let cosU1 = cos(u1)

    let sigma1 = atan2(tan(u1), cosAlpha1)
    let sinAlpha = cosU1 * sinAlpha1
    let cos2Alpha = 1.0 - sinAlpha * sinAlpha

    let uSq = cos2Alpha * (a * a - b * b) / (b * b)
    let aCoeff = 1.0 + (uSq / 16384.0) * (4096.0 + uSq * (-768.0 + uSq * (320.0 - 175.0 * uSq)))
    let bCoeff = (uSq / 1024.0) * (256.0 + uSq * (-128.0 + uSq * (74.0 - 47.0 * uSq)))

    var sigma = distanceMeters / (b * aCoeff)
    var prevSigma = 0.0
    var cos2SigmaM = 0.0
    var sinSigma = 0.0
    var cosSigma = 0.0

    for _ in 0..<200 {
        cos2SigmaM = cos(2.0 * sigma1 + sigma)
        sinSigma = sin(sigma)
        cosSigma = cos(sigma)
        let deltaSigma =
            bCoeff * sinSigma * (
                cos2SigmaM + (bCoeff / 4.0) * (
                    cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM) -
                        (bCoeff / 6.0) * cos2SigmaM * (-3.0 + 4.0 * sinSigma * sinSigma) * (-3.0 + 4.0 * cos2SigmaM * cos2SigmaM)
                )
            )
        prevSigma = sigma
        sigma = distanceMeters / (b * aCoeff) + deltaSigma
        if abs(sigma - prevSigma) < 1e-12 {
            break
        }
    }

    if abs(sigma - prevSigma) >= 1e-10 {
        return nil
    }

    let tmp = sinU1 * sinSigma - cosU1 * cosSigma * cosAlpha1
    let phi2 = atan2(
        sinU1 * cosSigma + cosU1 * sinSigma * cosAlpha1,
        (1.0 - f) * sqrt(sinAlpha * sinAlpha + tmp * tmp)
    )

    let lambda = atan2(
        sinSigma * sinAlpha1,
        cosU1 * cosSigma - sinU1 * sinSigma * cosAlpha1
    )

    let c = (f / 16.0) * cos2Alpha * (4.0 + f * (4.0 - 3.0 * cos2Alpha))
    let l =
        lambda - (1.0 - c) * f * sinAlpha * (
            sigma + c * sinSigma * (
                cos2SigmaM + c * cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM)
            )
        )

    let l2 = normalizeRadians(l1 + l)

    let alpha2 = atan2(
        sinAlpha,
        -tmp
    )

    return VincentyDirectResult(
        lat2: rad2deg(phi2),
        lon2: rad2deg(l2),
        alpha2Rad: normalizeRadians(alpha2)
    )
}

private func normalizeLng(_ lng: Double) -> Double {
    (((lng + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)) - 180.0
}

private func unwrapLngRelative(baseLng: Double, targetLng: Double) -> Double {
    var diff = targetLng - baseLng
    while diff > 180.0 { diff -= 360.0 }
    while diff < -180.0 { diff += 360.0 }
    return baseLng + diff
}

private func deg2rad(_ deg: Double) -> Double {
    deg * Double.pi / 180.0
}

private func rad2deg(_ rad: Double) -> Double {
    rad * 180.0 / Double.pi
}
