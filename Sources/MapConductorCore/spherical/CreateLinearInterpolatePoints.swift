import Foundation

/// Densifies a path by inserting linearly interpolated (rhumb-like) points at a
/// fixed fraction step between each pair of vertices.
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
            results.append(Spherical.linearInterpolate(from: from, to: to, fraction: fraction))
            fraction += fractionStep
        }
        results.append(to)
    }

    return results
}
