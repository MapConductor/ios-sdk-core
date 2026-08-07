import Foundation

/// リング操作の小道具（重複除去、頂点探索、交差判定、内外判定）。
///
/// すべて副作用のない計算。分割の各段から共通で呼ばれる。

// MARK: - Helpers

func dropClosingPoint(_ points: [GeoPointProtocol]) -> [GeoPointProtocol] {
    if points.count >= 2,
       let first = points.first, let last = points.last,
       first.latitude == last.latitude,
       first.longitude == last.longitude {
        return Array(points.dropLast())
    }
    return points
}

/// 最上端（isTop）または最下端の頂点。緯度が同じ場合は経度が大きい（東の）方。
func extremeVertexIndex(_ ring: [GeoPointProtocol], isTop: Bool) -> Int? {
    guard !ring.isEmpty else { return nil }
    var best = 0
    for index in ring.indices {
        let candidate = ring[index]
        let current = ring[best]
        let better: Bool
        if candidate.latitude == current.latitude {
            better = candidate.longitude > current.longitude
        } else {
            better = isTop
                ? candidate.latitude > current.latitude
                : candidate.latitude < current.latitude
        }
        if better { best = index }
    }
    return best
}

/// リングのエッジと水平線 y=lat の交点のうち、x > fromLng で最小の x（最初の東向き交点）。
func firstEastCrossing(
    _ ring: [GeoPointProtocol],
    fromLat lat: Double,
    fromLng: Double
) -> (edgeIndex: Int, x: Double, t: Double)? {
    var best: (edgeIndex: Int, x: Double, t: Double)?
    for index in ring.indices {
        let a = ring[index]
        let b = ring[(index + 1) % ring.count]
        guard (a.latitude > lat) != (b.latitude > lat) else { continue }
        let t = (lat - a.latitude) / (b.latitude - a.latitude)
        let x = a.longitude + t * (b.longitude - a.longitude)
        guard x > fromLng else { continue }
        if best == nil || x < best!.x {
            best = (index, x, t)
        }
    }
    return best
}

/// リングのエッジが水平セグメント（y=lat, x∈(x0,x1)）と交差するか。
func horizontalSegmentIntersectsRing(
    _ ring: [GeoPointProtocol],
    lat: Double,
    x0: Double,
    x1: Double,
    skipVertex: GeoPointProtocol? = nil
) -> Bool {
    let lo = min(x0, x1)
    let hi = max(x0, x1)
    for index in ring.indices {
        let a = ring[index]
        let b = ring[(index + 1) % ring.count]
        guard (a.latitude > lat) != (b.latitude > lat) else { continue }
        let t = (lat - a.latitude) / (b.latitude - a.latitude)
        let x = a.longitude + t * (b.longitude - a.longitude)
        if let skip = skipVertex, abs(x - skip.longitude) < 1e-12 { continue }
        if x > lo, x < hi { return true }
    }
    return false
}

/// hole の from→to を配列順方向（インデックス増加、循環）で辿ったチェイン（両端含む）。
func holeChain(_ hole: [GeoPointProtocol], from: Int, to: Int) -> [GeoPointProtocol] {
    var chain: [GeoPointProtocol] = []
    var index = from
    while true {
        chain.append(hole[index])
        if index == to { break }
        index = (index + 1) % hole.count
    }
    return chain
}

func meanLng(_ chain: [GeoPointProtocol]) -> Double {
    guard chain.count > 2 else {
        let lngs = chain.map { $0.longitude }
        return lngs.isEmpty ? -Double.infinity : lngs.reduce(0, +) / Double(lngs.count)
    }
    let interior = chain.dropFirst().dropLast()
    return interior.map { $0.longitude }.reduce(0, +) / Double(interior.count)
}

/// ring の from→to を配列順方向（循環）で辿った列（両端含む）。
func walkForward(_ ring: [GeoPointProtocol], from: Int, to: Int) -> [GeoPointProtocol] {
    var result: [GeoPointProtocol] = []
    var index = from
    while true {
        result.append(ring[index])
        if index == to { break }
        index = (index + 1) % ring.count
    }
    return result
}

/// 連続する同一座標（長さゼロのエッジ）を除去する（先頭・末尾の一致も除く）。
func dedupeConsecutive(_ ring: [GeoPointProtocol]) -> [GeoPointProtocol] {
    guard !ring.isEmpty else { return ring }
    var result: [GeoPointProtocol] = []
    for point in ring {
        if let last = result.last,
           last.latitude == point.latitude, last.longitude == point.longitude {
            continue
        }
        result.append(point)
    }
    while result.count >= 2,
          let first = result.first, let last = result.last,
          first.latitude == last.latitude, first.longitude == last.longitude {
        result.removeLast()
    }
    return result
}

/// 偶奇規則の内外判定。
func evenOddContains(_ ring: [GeoPointProtocol], lat: Double, lng: Double) -> Bool {
    var inside = false
    var j = ring.count - 1
    for i in ring.indices {
        let a = ring[i]
        let b = ring[j]
        if (a.latitude > lat) != (b.latitude > lat) {
            let x = a.longitude + ((lat - a.latitude) / (b.latitude - a.latitude)) * (b.longitude - a.longitude)
            if lng < x { inside.toggle() }
        }
        j = i
    }
    return inside
}
