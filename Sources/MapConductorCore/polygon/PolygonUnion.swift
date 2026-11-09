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
        return copy(holes: merged.map { $0.map { $0 as GeoPointProtocol } })
    }

    /// ``unionHoles()`` を MainActor の外で回すバックグラウンド版。
    ///
    /// android-sdk の `ArcGISPolygonOverlayRenderer` / `HerePolygonOverlayRenderer` が
    /// `withContext(Dispatchers.Default) { state.unionHoles() }` としているのと同じ位置づけ。
    /// 平面アレンジメントは辺数に対して O(n²) なので、穴の多いポリゴンをドラッグ中に
    /// 再構築するとメインスレッドを塞ぐ。
    ///
    /// 存在型（`GeoPointProtocol`）は Sendable でないため、detached task へは値型の
    /// ``GeoPoint`` に落としたスナップショットだけを渡す。
    func unionHolesInBackground() async -> PolygonState {
        guard holes.count > 1 else { return self }
        let snapshot = holes.map { ring in
            ring.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude ?? 0.0) }
        }
        let merged = await Task.detached(priority: .userInitiated) {
            unionHoleRings(snapshot.map { $0.map { $0 as GeoPointProtocol } })
        }.value
        guard let merged else { return self }
        return copy(holes: merged.map { $0.map { $0 as GeoPointProtocol } })
    }

    /// In-place variant: mutates `holes` to the merged result and returns self.
    ///
    /// android-sdk の `PolygonState.unionHolesInPlace()`（`PolygonUnion.kt`）の移植。
    /// 呼び出し側は android-sdk と同じくコンポーネント層（``Polygon``）。
    ///
    /// android-sdk は `LaunchedEffect(state)` により 1 state インスタンスにつき 1 回しか
    /// 走らないので、こちらも ``PolygonState/holesUnionApplied`` で同じ回数に揃える。
    /// つまり後から `holes` が差し替わっても（頂点ドラッグなど）ここは再実行されない。
    /// そのため各プロバイダのレンダラも、ジオメトリを組み立てる時点で ``unionHoles()``
    /// （または ``unionHolesInBackground()``）を通す — android-sdk の各
    /// `PolygonOverlayRenderer.resolveHoles()` と同じ構成。
    @discardableResult
    func unionHolesInPlace() -> PolygonState {
        if holesUnionApplied { return self }
        // android-sdk と同じく穴が 1 つ以下ならそのまま。ユニオン失敗時も元の穴を保持する。
        guard holes.count > 1, let merged = unionHoleRings(holes) else {
            holesUnionApplied = true
            return self
        }
        holes = merged.map { $0.map { $0 as GeoPointProtocol } }
        holesUnionApplied = true
        return self
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
func unionHoleRings(_ holes: [[GeoPointProtocol]]) -> [[GeoPoint]]? {
    guard holes.count > 1 else { return nil }

    // Work relative to an origin so coordinates stay feature-scale, which keeps
    // cross-product precision high far from lon/lat 0 (e.g. Tokyo).
    guard let origin = firstFinite(holes) else { return nil }

    let rings = holes.compactMap { toRing($0, origin: origin) }
    guard rings.count > 1 else { return nil }
    // Holes that neither cross, touch nor contain one another are already their
    // own union. Checking that is linear; the union is quadratic in the hole
    // edges, which a street-network parcel with 80 holes and 8,000 hole
    // vertices turns into seconds. js-sdk-core and android-sdk take the same
    // shortcut. The rings come back as the union would return them: clockwise.
    let merged = holesAreDisjoint(rings) ? rings : unionRings(rings)
    guard !merged.isEmpty else { return nil }

    return merged.map { ring -> [GeoPoint] in
        let geo: [GeoPoint] = ring.map { p in
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
// A sub-edge this close to a mid-point passes through it (degrees, far below gridQ).
private let unionOnEdge = 1e-12

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

// Reach of intersectionPoints beyond a segment's box (degrees). Its collinear
// test accepts an edge up to unionEps / |seg| off the line, and a segment
// shorter than sqrt(unionEps) = 1e-6 is skipped there, so that is at most 2e-6.
private let meetPad = 4e-6

// Farthest a side sample is taken from a sub-edge's mid-point, doubled (degrees).
private let clearanceCap = 2e-5

/// Edges filed in a uniform grid over their bounding boxes, so a search asks
/// only the edges near a box instead of all of them. A box covering every cell
/// an edge's box touches finds every edge that box can meet.
private struct EdgeGrid {
    private let side: Int
    private let minX: Double
    private let minY: Double
    private let cellW: Double
    private let cellH: Double
    private var cells: [Int: [Int]] = [:]
    private var seen: [Int]
    private var stamp = 0

    init(_ edges: [Edge], pad: Double) {
        var x0 = Double.infinity, y0 = Double.infinity
        var x1 = -Double.infinity, y1 = -Double.infinity
        for e in edges {
            x0 = min(x0, e.a.x, e.b.x); x1 = max(x1, e.a.x, e.b.x)
            y0 = min(y0, e.a.y, e.b.y); y1 = max(y1, e.a.y, e.b.y)
        }
        side = max(1, min(1024, Int(Double(edges.count).squareRoot().rounded(.up))))
        minX = x0
        minY = y0
        let w = (x1 - x0) / Double(side), h = (y1 - y0) / Double(side)
        cellW = w > 0 ? w : 1
        cellH = h > 0 ? h : 1
        seen = [Int](repeating: 0, count: edges.count)
        for (i, e) in edges.enumerated() {
            let (cx0, cy0, cx1, cy1) = cellRange(
                min(e.a.x, e.b.x) - pad, min(e.a.y, e.b.y) - pad,
                max(e.a.x, e.b.x) + pad, max(e.a.y, e.b.y) + pad
            )
            for cx in cx0...cx1 {
                for cy in cy0...cy1 { cells[cx * side + cy, default: []].append(i) }
            }
        }
    }

    /// Indices of the edges filed in a cell the box touches, each once, in no order.
    mutating func near(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double, into out: inout [Int]) {
        out.removeAll(keepingCapacity: true)
        stamp += 1
        let (cx0, cy0, cx1, cy1) = cellRange(minX, minY, maxX, maxY)
        for cx in cx0...cx1 {
            for cy in cy0...cy1 {
                guard let bucket = cells[cx * side + cy] else { continue }
                for i in bucket where seen[i] != stamp {
                    seen[i] = stamp
                    out.append(i)
                }
            }
        }
    }

    private func cellRange(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> (Int, Int, Int, Int) {
        (cell(minX, self.minX, cellW), cell(minY, self.minY, cellH),
         cell(maxX, self.minX, cellW), cell(maxY, self.minY, cellH))
    }

    private func cell(_ v: Double, _ min: Double, _ size: Double) -> Int {
        let c = ((v - min) / size).rounded(.down)
        return c < 0 ? 0 : (c > Double(side - 1) ? side - 1 : Int(c))
    }
}

/// Split every edge at all points where another edge crosses or touches it.
private func splitEdges(_ edges: [Edge]) -> [Edge] {
    var result: [Edge] = []
    // Only an edge whose box comes within meetPad of this one's can meet it.
    var grid = EdgeGrid(edges, pad: meetPad)
    var near: [Int] = []
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
        grid.near(
            min(seg.a.x, seg.b.x) - meetPad, min(seg.a.y, seg.b.y) - meetPad,
            max(seg.a.x, seg.b.x) + meetPad, max(seg.a.y, seg.b.y) + meetPad,
            into: &near
        )
        for j in near where i != j {
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
    var grid = EdgeGrid(subEdges, pad: 0)
    var near: [Int] = []
    let ringsBounds = rings.map(ringBounds)
    for seg in subEdges {
        let dir = sub(seg.b, seg.a)
        let len = (dir.x * dir.x + dir.y * dir.y).squareRoot()
        if len < unionEps { continue }

        let mid = add2(seg.a, scale(dir, 0.5))
        // Unit left normal. Sample coverage just off each side of the mid-point;
        // after splitting, no other edge crosses this sub-edge's interior, so an
        // offset shorter than the distance to the nearest other edge stays within
        // the two cells this edge separates. A fixed offset does not: where
        // another hole runs closer than it (two holes 1e-5 degree apart), the
        // sample lands inside that hole, the edge looks interior on both sides
        // and is dropped, and the traced ring cuts across a hole.
        let nx = -dir.y / len
        let ny = dir.x / len
        let off = min(len * 0.25, 0.5 * clearance(mid, cap: clearanceCap, subEdges, grid: &grid, near: &near))
        let leftInside = coverage(Vec(x: mid.x + nx * off, y: mid.y + ny * off), rings, ringsBounds) > 0
        let rightInside = coverage(Vec(x: mid.x - nx * off, y: mid.y - ny * off), rings, ringsBounds) > 0
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

/// Distance from `point` (the mid-point of a sub-edge) to the nearest sub-edge
/// that does not pass through it, or `cap` when none is closer. The sub-edge
/// itself and its duplicates from other rings pass through it and are skipped.
/// Only the sub-edges filed near the box `cap` around the point are asked; any
/// closer than `cap` is among them.
private func clearance(
    _ point: Vec,
    cap: Double,
    _ subEdges: [Edge],
    grid: inout EdgeGrid,
    near: inout [Int]
) -> Double {
    var best = cap
    grid.near(point.x - cap, point.y - cap, point.x + cap, point.y + cap, into: &near)
    for index in near {
        let e = subEdges[index]
        if min(e.a.x, e.b.x) > point.x + best || max(e.a.x, e.b.x) < point.x - best
            || min(e.a.y, e.b.y) > point.y + best || max(e.a.y, e.b.y) < point.y - best {
            continue
        }
        let d = distanceToSegment(point, e)
        if d > unionOnEdge && d < best { best = d }
    }
    return best
}

private func distanceToSegment(_ p: Vec, _ e: Edge) -> Double {
    let d = sub(e.b, e.a)
    let lenSq = dot(d, d)
    let t = lenSq > 0 ? clamp01(dot(sub(p, e.a), d) / lenSq) : 0
    let q = add2(e.a, scale(d, t))
    return ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot()
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

/// True when no two rings cross, touch or nest. The edges go into the same
/// EdgeGrid the union uses, and each edge is tested only against the edges filed
/// near its box, so the cost grows with the edge count rather than its square.
private func holesAreDisjoint(_ rings: [[Vec]]) -> Bool {
    let bounds = rings.map(ringBounds)
    // A ring inside another: one of its vertices is inside it.
    for i in rings.indices {
        let p = rings[i][0]
        for j in rings.indices where i != j {
            let b = bounds[j]
            if p.x >= b.minX && p.x <= b.maxX && p.y >= b.minY && p.y <= b.maxY && pointInRing(p, rings[j]) {
                return false
            }
        }
    }

    var edges: [Edge] = []
    var ringOf: [Int] = []
    for (r, ring) in rings.enumerated() {
        for i in ring.indices {
            edges.append(Edge(a: ring[i], b: ring[(i + 1) % ring.count]))
            ringOf.append(r)
        }
    }
    // Only an edge whose box comes within meetPad of this one's can meet it.
    var grid = EdgeGrid(edges, pad: meetPad)
    var near: [Int] = []
    for i in edges.indices {
        let seg = edges[i]
        grid.near(
            min(seg.a.x, seg.b.x) - meetPad, min(seg.a.y, seg.b.y) - meetPad,
            max(seg.a.x, seg.b.x) + meetPad, max(seg.a.y, seg.b.y) + meetPad,
            into: &near
        )
        for j in near where j > i && ringOf[j] != ringOf[i] {
            if !intersectionPoints(seg, edges[j]).isEmpty { return false }
        }
    }
    return true
}

/// How many rings' interiors contain the point. A ring whose latitudes do not
/// straddle the point's has no edge pointInRing would count, so it is skipped.
private func coverage(_ point: Vec, _ rings: [[Vec]], _ bounds: [Bounds]) -> Int {
    var count = 0
    for i in rings.indices {
        let b = bounds[i]
        if point.y < b.minY || point.y >= b.maxY { continue }
        if pointInRing(point, rings[i]) { count += 1 }
    }
    return count
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

private struct Bounds {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
}

private func ringBounds(_ ring: [Vec]) -> Bounds {
    var b = Bounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
    for p in ring {
        if p.x < b.minX { b.minX = p.x }
        if p.x > b.maxX { b.maxX = p.x }
        if p.y < b.minY { b.minY = p.y }
        if p.y > b.maxY { b.maxY = p.y }
    }
    return b
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
