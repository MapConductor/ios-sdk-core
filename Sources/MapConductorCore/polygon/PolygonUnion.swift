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

    // MARK: - Polygon union

    /// Computes the union of two simple polygons by retaining the portions of each
    /// boundary that are not inside the other polygon, then joining those portions.
    /// Returns nil if the polygons do not overlap.
    private static func computeUnion(_ a: [GeoPointProtocol], _ b: [GeoPointProtocol]) -> [GeoPointProtocol]? {
        let lhs = ensureCounterClockwise(openRing(a))
        let rhs = ensureCounterClockwise(openRing(b))
        guard lhs.count >= 3, rhs.count >= 3 else { return nil }

        let intersections = edgeIntersections(lhs, rhs)
        let lhsIsContained = lhs.allSatisfy { pointLocation($0, in: rhs) != .outside }
        let rhsIsContained = rhs.allSatisfy { pointLocation($0, in: lhs) != .outside }

        if intersections.isEmpty {
            if lhsIsContained { return rhs }
            if rhsIsContained { return lhs }
            return nil
        }

        var segments = boundarySegments(of: lhs, outside: rhs, intersections: intersections, ringIndex: 0)
        segments += boundarySegments(of: rhs, outside: lhs, intersections: intersections, ringIndex: 1)
        segments = removeDuplicateSegments(segments)

        guard let boundary = joinBoundarySegments(segments), boundary.count >= 3 else {
            return nil
        }
        return boundary
    }

    private static let epsilon = 1e-10

    private struct EdgeIntersection {
        let lhsEdge: Int
        let rhsEdge: Int
        let lhsFraction: Double
        let rhsFraction: Double
    }

    private struct BoundarySegment {
        let start: GeoPointProtocol
        let end: GeoPointProtocol
    }

    private enum PointLocation: Equatable {
        case outside
        case inside
        case boundary
    }

    private static func openRing(_ ring: [GeoPointProtocol]) -> [GeoPointProtocol] {
        guard let first = ring.first, let last = ring.last,
              samePoint(first, last) else { return ring }
        return Array(ring.dropLast())
    }

    private static func edgeIntersections(
        _ lhs: [GeoPointProtocol],
        _ rhs: [GeoPointProtocol]
    ) -> [EdgeIntersection] {
        var result: [EdgeIntersection] = []
        for lhsIndex in lhs.indices {
            let lhsStart = lhs[lhsIndex]
            let lhsEnd = lhs[(lhsIndex + 1) % lhs.count]
            for rhsIndex in rhs.indices {
                let rhsStart = rhs[rhsIndex]
                let rhsEnd = rhs[(rhsIndex + 1) % rhs.count]
                guard let fractions = segmentIntersectionFractions(
                    lhsStart, lhsEnd, rhsStart, rhsEnd
                ) else { continue }
                result.append(EdgeIntersection(
                    lhsEdge: lhsIndex,
                    rhsEdge: rhsIndex,
                    lhsFraction: fractions.0,
                    rhsFraction: fractions.1
                ))
            }
        }
        return result
    }

    private static func segmentIntersectionFractions(
        _ a: GeoPointProtocol,
        _ b: GeoPointProtocol,
        _ c: GeoPointProtocol,
        _ d: GeoPointProtocol
    ) -> (Double, Double)? {
        let abLongitude = b.longitude - a.longitude
        let abLatitude = b.latitude - a.latitude
        let cdLongitude = d.longitude - c.longitude
        let cdLatitude = d.latitude - c.latitude
        let denominator = abLongitude * cdLatitude - abLatitude * cdLongitude
        guard abs(denominator) > epsilon else { return nil }

        let acLongitude = c.longitude - a.longitude
        let acLatitude = c.latitude - a.latitude
        let lhsFraction = (acLongitude * cdLatitude - acLatitude * cdLongitude) / denominator
        let rhsFraction = (acLongitude * abLatitude - acLatitude * abLongitude) / denominator
        guard lhsFraction >= -epsilon, lhsFraction <= 1.0 + epsilon,
              rhsFraction >= -epsilon, rhsFraction <= 1.0 + epsilon else { return nil }
        return (clampUnit(lhsFraction), clampUnit(rhsFraction))
    }

    private static func boundarySegments(
        of ring: [GeoPointProtocol],
        outside other: [GeoPointProtocol],
        intersections: [EdgeIntersection],
        ringIndex: Int
    ) -> [BoundarySegment] {
        var result: [BoundarySegment] = []
        for edgeIndex in ring.indices {
            let start = ring[edgeIndex]
            let end = ring[(edgeIndex + 1) % ring.count]
            let edgeFractions = intersections.compactMap { intersection -> Double? in
                if ringIndex == 0, intersection.lhsEdge == edgeIndex {
                    return intersection.lhsFraction
                }
                if ringIndex == 1, intersection.rhsEdge == edgeIndex {
                    return intersection.rhsFraction
                }
                return nil
            }
            let fractions = uniqueSorted([0.0, 1.0] + edgeFractions)
            for index in 0..<(fractions.count - 1) {
                let fromFraction = fractions[index]
                let toFraction = fractions[index + 1]
                guard toFraction - fromFraction > epsilon else { continue }
                let midpoint = interpolate(start, end, fraction: (fromFraction + toFraction) / 2.0)
                guard pointLocation(midpoint, in: other) != .inside else { continue }
                result.append(BoundarySegment(
                    start: interpolate(start, end, fraction: fromFraction),
                    end: interpolate(start, end, fraction: toFraction)
                ))
            }
        }
        return result
    }

    private static func pointLocation(
        _ point: GeoPointProtocol,
        in ring: [GeoPointProtocol]
    ) -> PointLocation {
        var isInside = false
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            if pointIsOnSegment(point, a, b) { return .boundary }

            let crossesLatitude = (a.latitude > point.latitude) != (b.latitude > point.latitude)
            if crossesLatitude {
                let longitudeAtLatitude = a.longitude
                    + (point.latitude - a.latitude) * (b.longitude - a.longitude)
                    / (b.latitude - a.latitude)
                if longitudeAtLatitude > point.longitude { isInside.toggle() }
            }
        }
        return isInside ? .inside : .outside
    }

    private static func pointIsOnSegment(
        _ point: GeoPointProtocol,
        _ start: GeoPointProtocol,
        _ end: GeoPointProtocol
    ) -> Bool {
        let area = (end.longitude - start.longitude) * (point.latitude - start.latitude)
            - (end.latitude - start.latitude) * (point.longitude - start.longitude)
        guard abs(area) <= epsilon else { return false }
        return point.longitude >= min(start.longitude, end.longitude) - epsilon
            && point.longitude <= max(start.longitude, end.longitude) + epsilon
            && point.latitude >= min(start.latitude, end.latitude) - epsilon
            && point.latitude <= max(start.latitude, end.latitude) + epsilon
    }

    private static func removeDuplicateSegments(_ segments: [BoundarySegment]) -> [BoundarySegment] {
        var result: [BoundarySegment] = []
        for segment in segments {
            if result.contains(where: { samePoint($0.start, segment.start) && samePoint($0.end, segment.end) }) {
                continue
            }
            if let reversedIndex = result.firstIndex(where: {
                samePoint($0.start, segment.end) && samePoint($0.end, segment.start)
            }) {
                result.remove(at: reversedIndex)
                continue
            }
            result.append(segment)
        }
        return result
    }

    private static func joinBoundarySegments(_ segments: [BoundarySegment]) -> [GeoPointProtocol]? {
        guard let first = segments.first else { return nil }
        var unused = Array(segments.dropFirst())
        var boundary: [GeoPointProtocol] = [first.start]
        var current = first.end

        while !samePoint(current, boundary[0]) {
            boundary.append(current)
            guard let nextIndex = unused.firstIndex(where: { samePoint($0.start, current) }) else {
                return nil
            }
            current = unused.remove(at: nextIndex).end
            guard boundary.count <= segments.count else { return nil }
        }
        return boundary
    }

    private static func interpolate(
        _ start: GeoPointProtocol,
        _ end: GeoPointProtocol,
        fraction: Double
    ) -> GeoPointProtocol {
        return GeoPoint(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    private static func uniqueSorted(_ values: [Double]) -> [Double] {
        values.sorted().reduce(into: []) { result, value in
            if let last = result.last, abs(last - value) <= epsilon { return }
            result.append(value)
        }
    }

    private static func clampUnit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private static func samePoint(_ lhs: GeoPointProtocol, _ rhs: GeoPointProtocol) -> Bool {
        abs(lhs.latitude - rhs.latitude) <= epsilon
            && abs(lhs.longitude - rhs.longitude) <= epsilon
    }
}
