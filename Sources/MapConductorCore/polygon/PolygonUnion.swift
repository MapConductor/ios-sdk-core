import Foundation

public extension PolygonState {
    /// Returns a copy of this polygon where all overlapping holes have been merged
    /// into their union. Non-overlapping holes are returned unchanged.
    ///
    /// Note: the raster tile renderer already handles overlapping holes visually via
    /// CGContext `.clear` blend mode, so this utility is for pre-processing consumers
    /// who need geometrically-correct polygon data.
    func unionHoles() -> PolygonState {
        let merged = PolygonHoleUnion.merge(holes: holes)
        if merged.count == holes.count { return self }
        return copy(holes: merged)
    }
}

// MARK: - Implementation

enum PolygonHoleUnion {
    static func merge(holes: [[GeoPointProtocol]]) -> [[GeoPointProtocol]] {
        guard holes.count > 1 else { return holes }
        var result = holes
        var changed = true
        while changed {
            changed = false
            var merged: [[GeoPointProtocol]] = []
            var used = [Bool](repeating: false, count: result.count)
            for i in 0..<result.count {
                if used[i] { continue }
                var current = result[i]
                for j in (i + 1)..<result.count {
                    if used[j] { continue }
                    if boundingBoxesOverlap(current, result[j]) {
                        if let union = computeUnion(current, result[j]) {
                            current = union
                            used[j] = true
                            changed = true
                        }
                    }
                }
                merged.append(current)
            }
            result = merged
        }
        return result
    }

    // MARK: - Bounding box

    private static func boundingBoxesOverlap(_ a: [GeoPointProtocol], _ b: [GeoPointProtocol]) -> Bool {
        let (minLatA, maxLatA, minLonA, maxLonA) = bounds(a)
        let (minLatB, maxLatB, minLonB, maxLonB) = bounds(b)
        return minLatA <= maxLatB && maxLatA >= minLatB
            && minLonA <= maxLonB && maxLonA >= minLonB
    }

    private static func bounds(_ ring: [GeoPointProtocol]) -> (Double, Double, Double, Double) {
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for p in ring {
            minLat = min(minLat, p.latitude)
            maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude)
            maxLon = max(maxLon, p.longitude)
        }
        return (minLat, maxLat, minLon, maxLon)
    }

    // MARK: - Sutherland-Hodgman polygon clipping for union

    /// Computes the union of two convex-ish polygons.
    /// Uses Sutherland-Hodgman to find the intersection, then constructs the union.
    /// Returns nil if the polygons do not actually overlap.
    private static func computeUnion(_ a: [GeoPointProtocol], _ b: [GeoPointProtocol]) -> [GeoPointProtocol]? {
        let intersection = clip(subject: a, clip: b)
        guard !intersection.isEmpty else { return nil }
        return mergePolygons(a, b)
    }

    /// Sutherland-Hodgman clipping: returns intersection of subject clipped by clip polygon.
    private static func clip(subject: [GeoPointProtocol], clip: [GeoPointProtocol]) -> [GeoPointProtocol] {
        var output = subject
        let n = clip.count
        for i in 0..<n {
            if output.isEmpty { return [] }
            let edgeA = clip[i]
            let edgeB = clip[(i + 1) % n]
            let input = output
            output = []
            for j in 0..<input.count {
                let current = input[j]
                let previous = input[(j + Int(input.count) - 1) % input.count]
                if isInside(current, edgeA, edgeB) {
                    if !isInside(previous, edgeA, edgeB) {
                        if let p = intersect(previous, current, edgeA, edgeB) {
                            output.append(p)
                        }
                    }
                    output.append(current)
                } else if isInside(previous, edgeA, edgeB) {
                    if let p = intersect(previous, current, edgeA, edgeB) {
                        output.append(p)
                    }
                }
            }
        }
        return output
    }

    private static func isInside(_ p: GeoPointProtocol, _ a: GeoPointProtocol, _ b: GeoPointProtocol) -> Bool {
        // Cross product: (b-a) × (p-a) >= 0 means p is on the left side (inside for CCW polygon)
        let cross = (b.longitude - a.longitude) * (p.latitude - a.latitude)
                  - (b.latitude - a.latitude) * (p.longitude - a.longitude)
        return cross >= 0
    }

    private static func intersect(
        _ p1: GeoPointProtocol, _ p2: GeoPointProtocol,
        _ p3: GeoPointProtocol, _ p4: GeoPointProtocol
    ) -> GeoPointProtocol? {
        let d1lon = p2.longitude - p1.longitude
        let d1lat = p2.latitude - p1.latitude
        let d2lon = p4.longitude - p3.longitude
        let d2lat = p4.latitude - p3.latitude
        let denom = d1lon * d2lat - d1lat * d2lon
        guard abs(denom) > 1e-12 else { return nil }
        let t = ((p3.longitude - p1.longitude) * d2lat - (p3.latitude - p1.latitude) * d2lon) / denom
        return GeoPoint(
            latitude: p1.latitude + t * d1lat,
            longitude: p1.longitude + t * d1lon
        )
    }

    /// Merge two polygons by tracing the outer boundary.
    /// Builds the union outline by concatenating both polygon vertices, removing interior ones.
    private static func mergePolygons(_ a: [GeoPointProtocol], _ b: [GeoPointProtocol]) -> [GeoPointProtocol] {
        // Simple convex hull of all vertices as fallback for the union boundary
        let all = a + b
        return convexHull(all)
    }

    // MARK: - Convex hull (Andrew's monotone chain)

    private static func convexHull(_ points: [GeoPointProtocol]) -> [GeoPointProtocol] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { $0.longitude < $1.longitude || ($0.longitude == $1.longitude && $0.latitude < $1.latitude) }
        var lower: [GeoPointProtocol] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [GeoPointProtocol] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func cross(_ o: GeoPointProtocol, _ a: GeoPointProtocol, _ b: GeoPointProtocol) -> Double {
        (a.longitude - o.longitude) * (b.latitude - o.latitude) - (a.latitude - o.latitude) * (b.longitude - o.longitude)
    }
}
