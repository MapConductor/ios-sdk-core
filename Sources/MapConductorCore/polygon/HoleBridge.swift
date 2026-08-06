import Foundation

/// 外周リング + 複数の穴リングを、穴をブリッジで繋いだ「単一リング」に変換する
/// （mapbox/earcut の eliminateHoles 相当。android-sdk-core `HoleBridge.kt` の移植）。
///
/// 穴（inner ring）をネイティブにサポートしない描画系（TomTom の通常 Polygon など）で、
/// 穴付きポリゴンを 1 枚の通常ポリゴンとして塗るために使う。各穴は外周（および既にブリッジ
/// 済みのリング）へ「ゼロ幅の橋」で接続され、全体で 1 つの弱単純ポリゴンになる。塗りは
/// 正しく穴が抜けるが、橋の部分は細い切れ込みとして残るため、輪郭線は別途 stroke-only の
/// ポリゴンで描くこと。
///
/// 入力の巻き方向は問わない（内部で外周 CCW / 穴 CW に正規化する）。x=経度, y=緯度で扱う。
///
/// - Parameter separation: 橋の「行き」と「帰り」のエッジを横方向にずらす度数。0 だと橋は
///   幅ゼロ（座標が完全に一致する往復エッジ）になり、Android の TomTom はそのまま塗れるが、
///   iOS の TomTom (Orbis) や HERE のテッセレータは自己接触リングとして塗りを崩す／穴を
///   無視する。正の値を渡すと厳密に単純なリングになり、塗り規則によっては穴が抜ける
///   （すき間は画面上では不可視）。
///
///   ただし TomTom (Orbis iOS) はこれでも塗れない。2026-08-06 に iPad 実機で
///   separation = 1e-6 / 1e-4 の両方を検証したが、いずれも塗りが楔状に崩れ穴も抜けなかった
///   （`HolePolygonUITests.testTomTomHoleDrift`）。TomTom iOS は `PolygonHoleSplit` の
///   分割方式（`partitionPolygonByHoles`）を使うこと。
public func bridgeHolesIntoSingleRing(
    outer: [GeoPointProtocol],
    holes: [[GeoPointProtocol]],
    separation: Double = 0.0
) -> [GeoPointProtocol] {
    if holes.isEmpty { return outer }

    let arena = BridgeArena(separation: separation)
    // ノードは strong な循環リンクを持つため、arena が最後に必ずリンクを切って解放する。
    defer { arena.breakCycles() }

    guard let outerNode = arena.buildRing(dropClosing(outer), wantClockwise: false) else { return outer }

    var queue: [BridgeNode] = []
    for hole in holes {
        guard let list = arena.buildRing(dropClosing(hole), wantClockwise: true) else { continue }
        queue.append(leftmost(list))
    }
    // 穴を左端 x の昇順で処理する（earcut と同じ）。
    queue.sort { lhs, rhs in
        lhs.x != rhs.x ? lhs.x < rhs.x : lhs.y < rhs.y
    }

    for holeLeftmost in queue {
        if let bridge = findHoleBridge(hole: holeLeftmost, outerNode: outerNode) {
            arena.splitPolygon(bridge, holeLeftmost)
        }
    }

    var result: [GeoPointProtocol] = []
    result.reserveCapacity(outer.count + holes.reduce(0) { $0 + $1.count } * 2)
    var p = outerNode
    repeat {
        result.append(p.source)
        p = p.next
    } while p !== outerNode
    return result
}

/// 経度ラップを考慮したブリッジ。
///
/// 標準の（earcut 同様の）ブリッジは穴の左端から「西向き」に外周を探すため、世界マスク級の
/// 外周では橋のエッジが経度 180° 超を跨ぐことがある。ネイティブ地図レンダラ（TomTom Orbis /
/// HERE など）は 180° 超のエッジを「短い方」（対蹠線越え）として描くため、リングが自己交差
/// して塗りが壊れる。西向きの結果に 180° 超のエッジが含まれる場合は、経度を鏡像反転して
/// 東向きに橋を張り直し、経度ステップが小さく収まる方を返す。
public func bridgeHolesIntoSingleRingWrapAware(
    outer: [GeoPointProtocol],
    holes: [[GeoPointProtocol]],
    separation: Double = 0.0
) -> [GeoPointProtocol] {
    let west = bridgeHolesIntoSingleRing(outer: outer, holes: holes, separation: separation)
    let westMax = maxAbsLngStep(west)
    if westMax <= 180.0 { return west }

    let east = bridgeHolesIntoSingleRing(
        outer: outer.map(mirrorLng),
        holes: holes.map { $0.map(mirrorLng) },
        separation: separation
    ).map(mirrorLng)
    return maxAbsLngStep(east) < westMax ? east : west
}

private func mirrorLng(_ point: GeoPointProtocol) -> GeoPointProtocol {
    GeoPoint(latitude: point.latitude, longitude: -point.longitude, altitude: point.altitude ?? 0.0)
}

private func maxAbsLngStep(_ ring: [GeoPointProtocol]) -> Double {
    guard ring.count >= 2 else { return 0 }
    var maxStep = 0.0
    for i in ring.indices {
        let a = ring[i]
        let b = ring[(i + 1) % ring.count]
        maxStep = max(maxStep, abs(b.longitude - a.longitude))
    }
    return maxStep
}

// MARK: - Implementation

private final class BridgeNode {
    let x: Double
    let y: Double
    let source: GeoPointProtocol

    // 循環連結リスト。arena.breakCycles() が最後にリンクを切って解放する。
    var prev: BridgeNode!
    var next: BridgeNode!

    init(x: Double, y: Double, source: GeoPointProtocol) {
        self.x = x
        self.y = y
        self.source = source
    }
}

/// 生成した全ノードを保持し、終了時に循環参照を確実に切るアリーナ。
private final class BridgeArena {
    private var nodes: [BridgeNode] = []
    private let separation: Double

    init(separation: Double = 0.0) {
        self.separation = separation
    }

    func makeNode(x: Double, y: Double, source: GeoPointProtocol) -> BridgeNode {
        let node = BridgeNode(x: x, y: y, source: source)
        node.prev = node
        node.next = node
        nodes.append(node)
        return node
    }

    /// points から循環連結リストを構築し、head ノードを返す。wantClockwise に合わせて巻き方向を正規化。
    func buildRing(_ points: [GeoPointProtocol], wantClockwise: Bool) -> BridgeNode? {
        if points.count < 3 { return nil }
        var sum = 0.0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.longitude * b.latitude - b.longitude * a.latitude
        }
        let isCcw = sum > 0.0
        // wantClockwise==true なら CW に、false なら CCW にしたい。現状と一致しなければ反転。
        let ordered = (isCcw == wantClockwise) ? Array(points.reversed()) : points

        var last: BridgeNode?
        for pt in ordered {
            let node = makeNode(x: pt.longitude, y: pt.latitude, source: pt)
            if let prev = last {
                node.prev = prev
                node.next = prev.next
                prev.next.prev = node
                prev.next = node
            }
            last = node
        }
        return last?.next
    }

    /// a と b を橋で接続し、リングを繋ぎ替える（earcut の splitPolygon）。
    /// separation > 0 のときは複製ノード（帰りエッジ側）を橋方向の法線に沿って
    /// 微小オフセットし、往復エッジの座標一致（自己接触）を避ける。
    func splitPolygon(_ a: BridgeNode, _ b: BridgeNode) {
        var a2x = a.x
        var a2y = a.y
        var b2x = b.x
        var b2y = b.y
        if separation > 0 {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 0 {
                let nx = -dy / len * separation
                let ny = dx / len * separation
                a2x += nx
                a2y += ny
                b2x += nx
                b2y += ny
            }
        }
        let a2 = makeNode(
            x: a2x,
            y: a2y,
            source: separation > 0 ? GeoPoint(latitude: a2y, longitude: a2x) : a.source
        )
        let b2 = makeNode(
            x: b2x,
            y: b2y,
            source: separation > 0 ? GeoPoint(latitude: b2y, longitude: b2x) : b.source
        )
        let an: BridgeNode = a.next
        let bp: BridgeNode = b.prev

        a.next = b
        b.prev = a
        a2.next = an
        an.prev = a2
        b2.next = a2
        a2.prev = b2
        bp.next = b2
        b2.prev = bp
    }

    func breakCycles() {
        for node in nodes {
            node.prev = nil
            node.next = nil
        }
        nodes.removeAll()
    }
}

private func dropClosing(_ points: [GeoPointProtocol]) -> [GeoPointProtocol] {
    if points.count >= 2,
       let first = points.first, let last = points.last,
       first.latitude == last.latitude,
       first.longitude == last.longitude {
        return Array(points.dropLast())
    }
    return points
}

private func leftmost(_ start: BridgeNode) -> BridgeNode {
    var p = start
    var minNode = start
    repeat {
        if p.x < minNode.x || (p.x == minNode.x && p.y < minNode.y) { minNode = p }
        p = p.next
    } while p !== start
    return minNode
}

/// 穴の左端ノードから見て、外周リング上に接続可能な（可視な）橋の相手ノードを探す。
private func findHoleBridge(hole: BridgeNode, outerNode: BridgeNode) -> BridgeNode? {
    var p = outerNode
    let hx = hole.x
    let hy = hole.y
    var qx = -Double.infinity
    var m: BridgeNode?

    // 穴左端から左向きに水平レイを飛ばし、交差する外周エッジのうち最も近い（x が最大の）ものを選ぶ。
    repeat {
        if hy <= p.y && hy >= p.next.y && p.next.y != p.y {
            let x = p.x + (hy - p.y) * (p.next.x - p.x) / (p.next.y - p.y)
            if x <= hx && x > qx {
                qx = x
                if x == hx {
                    return p.x < p.next.x ? p : p.next
                }
                m = p.x < p.next.x ? p : p.next
            }
        }
        p = p.next
    } while p !== outerNode

    guard let bridge = m else { return nil }

    // 橋候補 bridge と穴・レイ交点で作る三角形の内側に頂点があれば、より角度の小さい頂点へ橋を張り替える
    // （凹んだ外周や近接する穴での自己交差を避ける）。
    let stop = bridge
    var best = bridge
    let mx = bridge.x
    let my = bridge.y
    var tanMin = Double.infinity
    p = bridge
    repeat {
        let inTri: Bool
        if hy < my {
            inTri = pointInTriangle(hx, hy, mx, my, qx, hy, p.x, p.y)
        } else {
            inTri = pointInTriangle(qx, hy, mx, my, hx, hy, p.x, p.y)
        }
        if hx >= p.x && p.x >= mx && hx != p.x && inTri {
            let tan = abs(hy - p.y) / (hx - p.x)
            if locallyInside(p, hole) && (tan < tanMin || (tan == tanMin && p.x > best.x)) {
                best = p
                tanMin = tan
            }
        }
        p = p.next
    } while p !== stop

    return best
}

private func area(_ p: BridgeNode, _ q: BridgeNode, _ r: BridgeNode) -> Double {
    (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
}

private func locallyInside(_ a: BridgeNode, _ b: BridgeNode) -> Bool {
    if area(a.prev, a, a.next) < 0 {
        return area(a, b, a.next) >= 0 && area(a, a.prev, b) >= 0
    } else {
        return area(a, b, a.prev) < 0 || area(a, a.next, b) < 0
    }
}

private func pointInTriangle(
    _ ax: Double, _ ay: Double,
    _ bx: Double, _ by: Double,
    _ cx: Double, _ cy: Double,
    _ px: Double, _ py: Double
) -> Bool {
    (cx - px) * (ay - py) - (ax - px) * (cy - py) >= 0 &&
        (ax - px) * (by - py) - (bx - px) * (ay - py) >= 0 &&
        (bx - px) * (cy - py) - (cx - px) * (by - py) >= 0
}
