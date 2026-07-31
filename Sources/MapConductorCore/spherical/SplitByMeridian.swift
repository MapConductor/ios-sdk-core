import Foundation

/// Splits a list of points by the 180°/-180° meridian line, inserting
/// interpolated points at the meridian crossings so there are no gaps.
///
/// - Parameters:
///   - points: Points to split.
///   - geodesic: If true, uses geodesic (great-circle) interpolation; otherwise
///     linear interpolation.
/// - Returns: Groups of points, each a continuous segment without meridian crossings.
public func splitByMeridian(
    _ points: [GeoPointProtocol],
    geodesic: Bool
) -> [[GeoPointProtocol]] {
    guard !points.isEmpty else { return [] }

    var results: [[GeoPointProtocol]] = []
    var fragment: [GeoPointProtocol] = []

    for currentPoint in points {
        if fragment.isEmpty {
            fragment.append(currentPoint)
            continue
        }

        let previousPoint = fragment[fragment.count - 1]
        let prevLng = previousPoint.longitude
        let currLng = currentPoint.longitude

        // Detect a 180° meridian crossing only (0° crossings are excluded).
        let lngDiff = currLng - prevLng
        let crossesMeridian = abs(lngDiff) > 180.0

        if !crossesMeridian {
            fragment.append(currentPoint)
        } else {
            // Add an interpolated point at the meridian, close the fragment, and
            // start a new one from the opposite meridian.
            let meridianPoint = interpolateAtMeridian(from: previousPoint, to: currentPoint, geodesic: geodesic)
            fragment.append(meridianPoint)

            results.append(fragment)
            fragment = []

            let oppositeMeridianPoint = createOppositeMeridianPoint(meridianPoint)
            fragment.append(oppositeMeridianPoint)
            fragment.append(currentPoint)
        }
    }

    if !fragment.isEmpty {
        results.append(fragment)
    }

    return results
}

/// Interpolates a point at the 180°/-180° meridian line between two points.
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
