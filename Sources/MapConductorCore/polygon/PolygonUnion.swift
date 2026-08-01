import Foundation

public extension PolygonState {
    /// Returns a copy of this polygon where all overlapping holes have been merged
    /// into their union. Non-overlapping holes are re-emitted with clockwise winding.
    ///
    /// Note: the raster tile renderer already handles overlapping holes visually via
    /// CGContext `.clear` blend mode, so this utility is for pre-processing consumers
    /// who need geometrically-correct polygon data.
    func unionHoles() -> PolygonState {
        guard let merged = unionHoleRings(holes) else { return self }
        return copy(holes: merged)
    }
}

// MARK: - Implementation

/// Unions overlapping hole rings in a planar lon/lat coordinate space, with no
/// external geometry library.
///
/// Mirrors react-sdk `PolygonUnion.ts` and android-sdk `PolygonHoleUnion.kt` so all
/// platforms agree. Instead of a Boolean-op sweep line, this builds the planar
/// arrangement of all hole edges (splitting them at every intersection), keeps only
/// the sub-edges that lie on the outer boundary of the union — those with the union
/// interior on exactly one side, decided by point-in-polygon coverage — and chains
/// them back into rings.
///
/// Notes:
/// - Planar geometry (not geodesic). For very large polygons or near the poles,
///   results may differ from spherical expectations.
/// - Returns nil when the input is degenerate or the union fails; callers keep the
///   original rings unchanged in that case.
func unionHoleRings(_ holes: [[GeoPointProtocol]]) -> [[GeoPointProtocol]]? {
    guard holes.count > 1 else { return nil }

    // Work relative to an origin so coordinates stay feature-scale, which keeps
    // cross-product precision high far from lon/lat 0 (e.g. Tokyo).
    guard let origin = firstFinite(holes) else { return nil }

    let rings = holes.compactMap { toRing($0, origin: origin) }
    guard rings.count > 1 else { return nil }

    let merged = unionRings(rings)
    guard !merged.isEmpty else { return nil }

    return merged.map { ring -> [GeoPointProtocol] in
        let geo: [GeoPointProtocol] = ring.map { p in
            GeoPoint(latitude: p.y + origin.y, longitude: p.x + origin.x)
        }
        // Normalize hole winding to clockwise (renderers expect holes to wind
        // opposite the shell). unionRings emits counter-clockwise rings.
        return signedArea(ring) > 0 ? geo.reversed() : geo
    }
}

private struct Vec {
    var x: Double
    var y: Double
}

private struct Edge {
    var a: Vec
    var b: Vec
}

/// Snapped coordinates on an integer grid; ring chaining needs exact endpoint matches.
private struct VecKey: Hashable {
    var ix: Int64
    var iy: Int64
}

private struct DirectedEdgeKey: Hashable {
    var a: VecKey
    var b: VecKey
}

// Snap grid (degrees): shared endpoints must match exactly for chaining. ~0.1mm.
private let gridQ = 1e-9
// Tolerance for parallel/collinear/on-segment tests in feature-scale coords.
private let unionEps = 1e-12

private func unionRings(_ rings: [[Vec]]) -> [[Vec]] {
    // Directed edges of every ring (closed).
    var edges: [Edge] = []
    for ring in rings {
        for i in ring.indices {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            if !samePoint(a, b) { edges.append(Edge(a: a, b: b)) }
        }
    }

    let subEdges = splitEdges(edges)
    let boundary = classifyBoundary(subEdges, rings: rings)
    return traceRings(boundary)
}

/// Split every edge at all points where another edge crosses or touches it.
private func splitEdges(_ edges: [Edge]) -> [Edge] {
    var result: [Edge] = []
    for i in edges.indices {
        let seg = edges[i]
        let dir = sub(seg.b, seg.a)
        let lenSq = dot(dir, dir)
        if lenSq < unionEps { continue }

        // Collect cut points as parameters t in [0, 1] along the segment.
        var params: [VecKey: Double] = [:]
        func add(_ p: Vec) {
            let t = clamp01(dot(sub(p, seg.a), dir) / lenSq)
            params[keyOf(snap(add2(seg.a, scale(dir, t))))] = t
        }
        add(seg.a)
        add(seg.b)
        for j in edges.indices where i != j {
            for p in intersectionPoints(seg, edges[j]) { add(p) }
        }

        let points = params.values.sorted().map { t in
            snap(add2(seg.a, scale(dir, t)))
        }
        for k in 0..<(max(points.count, 1) - 1) {
            if !samePoint(points[k], points[k + 1]) {
                result.append(Edge(a: points[k], b: points[k + 1]))
            }
        }
    }
    return result
}

/// Keep the sub-edges on the union boundary, oriented so the union interior is on
/// their left (yielding counter-clockwise rings), de-duplicated.
private func classifyBoundary(_ subEdges: [Edge], rings: [[Vec]]) -> [Edge] {
    var out: [Edge] = []
    var seen = Set<DirectedEdgeKey>()
    for seg in subEdges {
        let dir = sub(seg.b, seg.a)
        let len = (dir.x * dir.x + dir.y * dir.y).squareRoot()
        if len < unionEps { continue }

        let mid = add2(seg.a, scale(dir, 0.5))
        // Unit left normal. Sample coverage just off each side of the mid-point;
        // after splitting, no other edge crosses this sub-edge's interior, so a
        // small offset stays within the two cells this edge separates.
        let nx = -dir.y / len
        let ny = dir.x / len
        let off = min(len * 0.25, 1e-5)
        let leftInside = coverage(Vec(x: mid.x + nx * off, y: mid.y + ny * off), rings) > 0
        let rightInside = coverage(Vec(x: mid.x - nx * off, y: mid.y - ny * off), rings) > 0
        if leftInside == rightInside { continue } // interior on both/neither side

        // Orient so the interior is on the left.
        let a = leftInside ? seg.a : seg.b
        let b = leftInside ? seg.b : seg.a
        let key = DirectedEdgeKey(a: keyOf(a), b: keyOf(b))
        if !seen.insert(key).inserted { continue }
        out.append(Edge(a: a, b: b))
    }
    return out
}

/// Chain directed boundary edges into closed rings.
private func traceRings(_ edges: [Edge]) -> [[Vec]] {
    var byStart: [VecKey: [Int]] = [:]
    for (index, edge) in edges.enumerated() {
        byStart[keyOf(edge.a), default: []].append(index)
    }

    var used = [Bool](repeating: false, count: edges.count)
    var rings: [[Vec]] = []

    for i in edges.indices {
        if used[i] { continue }
        var ring: [Vec] = []
        var current = i
        while current != -1 && !used[current] && ring.count <= edges.count {
            used[current] = true
            ring.append(edges[current].a)
            current = nextEdge(edges, byStart: byStart, used: used, edge: edges[current])
        }
        if ring.count >= 3 { rings.append(ring) }
    }
    return rings
}

/// The next unused edge continuing from `edge.b`. At a shared vertex (more than
/// one continuation), pick the sharpest clockwise turn from the reverse of the
/// incoming direction — the standard "next edge around the vertex" that keeps the
/// interior on the left and never crosses another boundary curve.
private func nextEdge(
    _ edges: [Edge],
    byStart: [VecKey: [Int]],
    used: [Bool],
    edge: Edge
) -> Int {
    let candidates = (byStart[keyOf(edge.b)] ?? []).filter { !used[$0] }
    if candidates.isEmpty { return -1 }
    if candidates.count == 1 { return candidates[0] }

    let back = atan2(edge.a.y - edge.b.y, edge.a.x - edge.b.x)
    var best = -1
    var bestAngle = Double.infinity
    for index in candidates {
        let out = edges[index]
        var angle = back - atan2(out.b.y - out.a.y, out.b.x - out.a.x)
        angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if angle < 0 { angle += 2 * .pi }
        if angle < 1e-9 { angle += 2 * .pi } // deprioritize a U-turn back the way we came
        if angle < bestAngle {
            bestAngle = angle
            best = index
        }
    }
    return best
}

/// Points where segment `other` meets segment `seg` (crossings, T-junctions,
/// collinear overlap ends).
private func intersectionPoints(_ seg: Edge, _ other: Edge) -> [Vec] {
    let r = sub(seg.b, seg.a)
    let s = sub(other.b, other.a)
    let qp = sub(other.a, seg.a)
    let rxs = cross(r, s)
    let qpxr = cross(qp, r)

    if abs(rxs) < unionEps && abs(qpxr) < unionEps {
        // Collinear: report the overlap endpoints that fall on `seg`.
        let rr = dot(r, r)
        if rr < unionEps { return [] }
        var t0 = dot(sub(other.a, seg.a), r) / rr
        var t1 = dot(sub(other.b, seg.a), r) / rr
        if t0 > t1 { swap(&t0, &t1) }
        let lo = max(0, t0)
        let hi = min(1, t1)
        if lo > hi + unionEps { return [] }
        var points = [add2(seg.a, scale(r, lo))]
        if hi > lo + unionEps { points.append(add2(seg.a, scale(r, hi))) }
        return points
    }
    if abs(rxs) < unionEps { return [] } // parallel, disjoint

    let t = cross(qp, s) / rxs
    let u = cross(qp, r) / rxs
    if t < -unionEps || t > 1 + unionEps || u < -unionEps || u > 1 + unionEps { return [] }
    return [add2(seg.a, scale(r, clamp01(t)))]
}

/// How many rings' interiors contain the point.
private func coverage(_ point: Vec, _ rings: [[Vec]]) -> Int {
    rings.reduce(0) { count, ring in
        pointInRing(point, ring) ? count + 1 : count
    }
}

/// Even-odd ray-casting point-in-polygon (winding-independent).
private func pointInRing(_ point: Vec, _ ring: [Vec]) -> Bool {
    var inside = false
    var j = ring.count - 1
    for i in ring.indices {
        let a = ring[i]
        let b = ring[j]
        if (a.y > point.y) != (b.y > point.y) {
            let x = a.x + ((point.y - a.y) / (b.y - a.y)) * (b.x - a.x)
            if point.x < x { inside.toggle() }
        }
        j = i
    }
    return inside
}

// MARK: - Ring / vector helpers

private func firstFinite(_ holes: [[GeoPointProtocol]]) -> Vec? {
    for hole in holes {
        for p in hole where p.latitude.isFinite && p.longitude.isFinite {
            return Vec(x: p.longitude, y: p.latitude)
        }
    }
    return nil
}

/// Open, de-duplicated, origin-relative ring, or nil when degenerate.
private func toRing(_ hole: [GeoPointProtocol], origin: Vec) -> [Vec]? {
    var points: [Vec] = []
    for p in hole where p.latitude.isFinite && p.longitude.isFinite {
        let point = snap(Vec(x: p.longitude - origin.x, y: p.latitude - origin.y))
        if points.isEmpty || !samePoint(points[points.count - 1], point) {
            points.append(point)
        }
    }
    while points.count >= 2, samePoint(points[0], points[points.count - 1]) {
        points.removeLast()
    }
    return points.count >= 3 ? points : nil
}

private func signedArea(_ ring: [Vec]) -> Double {
    var area = 0.0
    for i in ring.indices {
        let a = ring[i]
        let b = ring[(i + 1) % ring.count]
        area += a.x * b.y - b.x * a.y
    }
    return area / 2
}

private func sub(_ a: Vec, _ b: Vec) -> Vec { Vec(x: a.x - b.x, y: a.y - b.y) }

private func add2(_ a: Vec, _ b: Vec) -> Vec { Vec(x: a.x + b.x, y: a.y + b.y) }

private func scale(_ a: Vec, _ k: Double) -> Vec { Vec(x: a.x * k, y: a.y * k) }

private func dot(_ a: Vec, _ b: Vec) -> Double { a.x * b.x + a.y * b.y }

private func cross(_ a: Vec, _ b: Vec) -> Double { a.x * b.y - a.y * b.x }

private func clamp01(_ t: Double) -> Double { t < 0 ? 0 : (t > 1 ? 1 : t) }

private func snap(_ p: Vec) -> Vec {
    Vec(x: (p.x / gridQ).rounded() * gridQ, y: (p.y / gridQ).rounded() * gridQ)
}

private func keyOf(_ p: Vec) -> VecKey {
    VecKey(ix: Int64((p.x / gridQ).rounded()), iy: Int64((p.y / gridQ).rounded()))
}

private func samePoint(_ a: Vec, _ b: Vec) -> Bool { keyOf(a) == keyOf(b) }
