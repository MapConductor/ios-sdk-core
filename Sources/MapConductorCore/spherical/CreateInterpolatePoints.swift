import Foundation

/// Densifies a path by inserting geodesic (WGS84 great-circle) points so that no
/// segment exceeds `maxSegmentLength` meters.
public func createInterpolatePoints(
    _ points: [GeoPointProtocol],
    maxSegmentLength: Double = 10_000.0
) -> [GeoPointProtocol] {
    guard points.count >= 2 else { return points }

    var results: [GeoPointProtocol] = [points[0]]

    for index in 1..<points.count {
        let from = points[index - 1]
        let to = points[index]
        let distance = GeographicLibCalculator.computeDistanceBetween(from: from, to: to)

        let numSegments = max(1, Int(distance / maxSegmentLength))
        let step = 1.0 / Double(numSegments)

        var fraction = step
        while fraction < 1.0 {
            results.append(GeographicLibCalculator.interpolate(from: from, to: to, fraction: fraction))
            fraction += step
        }
        results.append(to)
    }

    return results
}
