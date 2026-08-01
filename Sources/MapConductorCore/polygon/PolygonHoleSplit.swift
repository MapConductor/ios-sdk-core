import Foundation

/// 外周リング + 穴リング群を、穴のない「単純なリング」の集合へ分割する（分割方式）。
///
/// 各穴について、穴の最上端頂点と最下端頂点から水平方向（東または西）へレイを飛ばし、
/// 外周（または分割済みピース境界）との最初の交点へ 2 本の「橋」を張る。2 本の橋で
/// 環状領域が 2 つの単純ポリゴンに分かれるため、keyhole（幅ゼロの切れ込み）や自己接触が
/// 一切生じない。TomTom (Orbis iOS) のように keyhole リングを塗れないレンダラ向け。
///
/// - 橋の方向は交点までの経度差が小さい側を選ぶ（経度 180° 超のエッジはレンダラが
///   対蹠線越えとして描くため、世界マスク級の外周でも橋が短辺側に張られる）。
/// - 橋レイが他の穴を横切る場合は反対方向を試し、それも不可なら当該穴のみ
///   `bridgeHolesIntoSingleRingWrapAware`（keyhole）にフォールバックする。
/// - 入力リングの巻き方向は問わない。出力リングはすべて CCW・開リング。
public func splitPolygonWithHolesIntoSimpleRings(
    outer: [GeoPointProtocol],
    holes: [[GeoPointProtocol]]
) -> [[GeoPointProtocol]] {
    let outerOpen = dropClosingPoint(outer)
    guard outerOpen.count >= 3 else { return [] }
    var pieces: [[GeoPointProtocol]] = [ensureCounterClockwise(outerOpen)]
    let cleanHoles = holes.map { dropClosingPoint($0) }.filter { $0.count >= 3 }
    guard !cleanHoles.isEmpty else { return pieces }

    for (holeIndex, hole) in cleanHoles.enumerated() {
        guard let probe = hole.first,
              let pieceIndex = pieces.firstIndex(where: { evenOddContains($0, lat: probe.latitude, lng: probe.longitude) })
        else { continue }

        let otherHoles = cleanHoles.enumerated().filter { $0.offset != holeIndex }.map { $0.element }
        if let (a, b) = splitPiece(pieces[pieceIndex], hole: hole, otherHoles: otherHoles) {
            pieces.remove(at: pieceIndex)
            pieces.append(ensureCounterClockwise(a))
            pieces.append(ensureCounterClockwise(b))
        } else {
            // フォールバック: この穴だけ keyhole ブリッジ（微小開き）で抜く。
            let bridged = bridgeHolesIntoSingleRingWrapAware(
                outer: pieces[pieceIndex],
                holes: [hole],
                separation: 1e-6
            )
            pieces[pieceIndex] = ensureCounterClockwise(bridged)
        }
    }
    return pieces
}

// MARK: - Partition (piece ≤ 1 hole)

/// 外周＋複数穴を「各ピースが穴を最大 1 個だけ含む」ように分割する。
///
/// TomTom の `PolygonOverlay` のように同心（入れ子チェイン）の穴しか表現できない描画系向け。
/// 穴同士を緯度（不可なら経度）の分離線で分け、外周をその線で切って再帰的に分割する。
/// どの軸でも分離できない（バウンディングが絡み合う）場合は、その穴群をまとめて 1 ピースで返す
/// （呼び出し側はチェイン表現などで近似する）。出力ピースの外周は CCW・開リング。
public func partitionPolygonByHoles(
    outer: [GeoPointProtocol],
    holes: [[GeoPointProtocol]]
) -> [(outer: [GeoPointProtocol], holes: [[GeoPointProtocol]])] {
    let outerOpen = ensureCounterClockwise(dropClosingPoint(outer))
    let cleanHoles = holes.map { dropClosingPoint($0) }.filter { $0.count >= 3 }
    guard outerOpen.count >= 3 else { return [] }
    if cleanHoles.count <= 1 {
        return [(outerOpen, cleanHoles)]
    }

    // 緯度の分離線で分割
    if let cut = separatingLatitude(cleanHoles, ring: outerOpen) {
        let (north, south) = splitSimplePolygonByLatitude(outerOpen, latitude: cut)
        let pieces = north + south
        if pieces.count >= 2 {
            var result: [(outer: [GeoPointProtocol], holes: [[GeoPointProtocol]])] = []
            for piece in pieces {
                let contained = cleanHoles.filter { hole in
                    guard let probe = hole.first else { return false }
                    return evenOddContains(piece, lat: probe.latitude, lng: probe.longitude)
                }
                result.append(contentsOf: partitionPolygonByHoles(outer: piece, holes: contained))
            }
            return result
        }
    }

    // 経度の分離線で分割（転置して緯度分割を再利用）
    if let cut = separatingLatitude(
        cleanHoles.map { $0.map(transposePoint) },
        ring: outerOpen.map(transposePoint)
    ) {
        let (east, west) = splitSimplePolygonByLatitude(
            ensureCounterClockwise(outerOpen.map(transposePoint)),
            latitude: cut
        )
        let pieces = (east + west).map { ensureCounterClockwise($0.map(transposePoint)) }
        if pieces.count >= 2 {
            var result: [(outer: [GeoPointProtocol], holes: [[GeoPointProtocol]])] = []
            for piece in pieces {
                let contained = cleanHoles.filter { hole in
                    guard let probe = hole.first else { return false }
                    return evenOddContains(piece, lat: probe.latitude, lng: probe.longitude)
                }
                result.append(contentsOf: partitionPolygonByHoles(outer: piece, holes: contained))
            }
            return result
        }
    }

    // 分離不能: 1 ピースにまとめて返す
    return [(outerOpen, cleanHoles)]
}

private func transposePoint(_ point: GeoPointProtocol) -> GeoPointProtocol {
    GeoPoint(latitude: point.longitude, longitude: point.latitude, altitude: point.altitude ?? 0.0)
}

/// 穴群を 2 グループに分ける緯度（どの穴の緯度範囲にも重ならず、リングの頂点とも一致しない値）。
private func separatingLatitude(_ holes: [[GeoPointProtocol]], ring: [GeoPointProtocol]) -> Double? {
    let ranges = holes.map { hole -> (minLat: Double, maxLat: Double) in
        let lats = hole.map { $0.latitude }
        return (lats.min() ?? 0, lats.max() ?? 0)
    }.sorted { $0.minLat < $1.minLat }

    var coveredMax = ranges[0].maxLat
    for index in 1..<ranges.count {
        let next = ranges[index]
        if next.minLat > coveredMax {
            var cut = (coveredMax + next.minLat) / 2
            var attempts = 0
            while ring.contains(where: { abs($0.latitude - cut) < 1e-12 }), attempts < 8 {
                cut += (next.minLat - coveredMax) * 1e-3
                attempts += 1
            }
            return cut
        }
        coveredMax = max(coveredMax, next.maxLat)
    }
    return nil
}

/// 単純ポリゴン（開リング）を緯度線で北側・南側のピース群に分割する。
/// 頂点が線上に一致しない前提（呼び出し側で線をずらす）。出力ピースは CCW・開リング。
func splitSimplePolygonByLatitude(
    _ ring: [GeoPointProtocol],
    latitude c: Double
) -> (north: [[GeoPointProtocol]], south: [[GeoPointProtocol]]) {
    let ccw = ensureCounterClockwise(dropClosingPoint(ring))
    guard ccw.count >= 3 else { return ([], []) }

    let lats = ccw.map { $0.latitude }
    if lats.allSatisfy({ $0 > c }) { return ([ccw], []) }
    if lats.allSatisfy({ $0 < c }) { return ([], [ccw]) }

    // 交点を挿入した頂点列（crossing フラグ付き）
    struct SplitVertex {
        let point: GeoPointProtocol
        let isCrossing: Bool
    }
    var vertices: [SplitVertex] = []
    for index in ccw.indices {
        let a = ccw[index]
        let b = ccw[(index + 1) % ccw.count]
        vertices.append(SplitVertex(point: a, isCrossing: false))
        if (a.latitude > c) != (b.latitude > c) {
            let t = (c - a.latitude) / (b.latitude - a.latitude)
            let lng = a.longitude + t * (b.longitude - a.longitude)
            vertices.append(SplitVertex(point: GeoPoint(latitude: c, longitude: lng), isCrossing: true))
        }
    }

    // 切断線上の「内部区間」ペア: 交点を経度順に並べ、(0,1), (2,3), … が内部。
    let crossingLngs = vertices.filter { $0.isCrossing }.map { $0.point.longitude }.sorted()
    var intervalPartner: [Double: Double] = [:]
    var pairIndex = 0
    while pairIndex + 1 < crossingLngs.count {
        intervalPartner[crossingLngs[pairIndex]] = crossingLngs[pairIndex + 1]
        intervalPartner[crossingLngs[pairIndex + 1]] = crossingLngs[pairIndex]
        pairIndex += 2
    }

    // 片側のチェイン（crossing → … → crossing）を抽出し、内部区間と交互にたどって閉リング化
    func extractPieces(keepNorth: Bool) -> [[GeoPointProtocol]] {
        let n = vertices.count
        guard let firstCrossing = vertices.firstIndex(where: { $0.isCrossing }) else { return [] }

        struct Chain {
            let startLng: Double
            let endLng: Double
            let points: [GeoPointProtocol]
        }
        var chains: [Chain] = []
        var index = firstCrossing
        var guardCount = 0
        repeat {
            let start = vertices[index]
            var chainPoints: [GeoPointProtocol] = [start.point]
            var side = 0.0
            var cursor = (index + 1) % n
            while !vertices[cursor].isCrossing {
                chainPoints.append(vertices[cursor].point)
                side = vertices[cursor].point.latitude - c
                cursor = (cursor + 1) % n
            }
            chainPoints.append(vertices[cursor].point)
            let keep = keepNorth ? side > 0 : side < 0
            if keep, chainPoints.count >= 2 {
                chains.append(
                    Chain(
                        startLng: start.point.longitude,
                        endLng: vertices[cursor].point.longitude,
                        points: chainPoints
                    )
                )
            }
            index = cursor
            guardCount += 1
        } while index != firstCrossing && guardCount <= n

        guard !chains.isEmpty else { return [] }

        var chainByStartLng: [Double: Int] = [:]
        for (chainIndex, chain) in chains.enumerated() {
            chainByStartLng[chain.startLng] = chainIndex
        }

        var used = [Bool](repeating: false, count: chains.count)
        var pieces: [[GeoPointProtocol]] = []
        for startIndex in chains.indices where !used[startIndex] {
            var piece: [GeoPointProtocol] = []
            var currentIndex = startIndex
            var steps = 0
            while !used[currentIndex] && steps <= chains.count {
                used[currentIndex] = true
                steps += 1
                let chain = chains[currentIndex]
                piece.append(contentsOf: chain.points)
                guard let partnerLng = intervalPartner[chain.endLng],
                      let nextIndex = chainByStartLng[partnerLng] else { break }
                currentIndex = nextIndex
            }
            let cleaned = dedupeConsecutive(piece)
            if cleaned.count >= 3 {
                pieces.append(ensureCounterClockwise(cleaned))
            }
        }
        return pieces
    }

    return (extractPieces(keepNorth: true), extractPieces(keepNorth: false))
}

// MARK: - Piece splitting

/// piece（CCW・開リング）を hole で 2 つの単純リングへ分割する。
/// まず東向きの橋を試し、不可なら経度を鏡像反転して再試行（=西向き）。
private func splitPiece(
    _ piece: [GeoPointProtocol],
    hole: [GeoPointProtocol],
    otherHoles: [[GeoPointProtocol]]
) -> ([GeoPointProtocol], [GeoPointProtocol])? {
    let east = splitPieceEast(piece, hole: hole, otherHoles: otherHoles)
    let westMirrored = splitPieceEast(
        piece.reversed().map(mirrorLngPoint),
        hole: hole.reversed().map(mirrorLngPoint),
        otherHoles: otherHoles.map { $0.map(mirrorLngPoint) }
    )
    let west = westMirrored.map { result in
        (
            result.rings.0.reversed().map(mirrorLngPoint),
            result.rings.1.reversed().map(mirrorLngPoint)
        )
    }

    switch (east, west) {
    case (nil, nil):
        return nil
    case (let e?, nil):
        return e.rings
    case (nil, let w?):
        return (w.0, w.1)
    case (let e?, let w?):
        // どちらも可能なら橋の合計長（経度差）が短い方（描画エッジのラップ耐性が高い方）。
        return e.bridgeSpan <= mirroredBridgeSpan(westMirrored) ? e.rings : (w.0, w.1)
    }
}

private func mirroredBridgeSpan(
    _ result: (rings: ([GeoPointProtocol], [GeoPointProtocol]), bridgeSpan: Double)?
) -> Double {
    result?.bridgeSpan ?? .infinity
}

private func mirrorLngPoint(_ point: GeoPointProtocol) -> GeoPointProtocol {
    GeoPoint(latitude: point.latitude, longitude: -point.longitude, altitude: point.altitude ?? 0.0)
}

/// 東向き（+x 方向）の橋 2 本で piece を分割する。piece は CCW・開リングであること。
private func splitPieceEast(
    _ piece: [GeoPointProtocol],
    hole: [GeoPointProtocol],
    otherHoles: [[GeoPointProtocol]]
) -> (rings: ([GeoPointProtocol], [GeoPointProtocol]), bridgeSpan: Double)? {
    let ccwPiece = ensureCounterClockwise(piece)
    guard hole.count >= 3 else { return nil }

    // 最上端・最下端の頂点（同緯度なら東寄りを選ぶ: レイが自分自身の水平エッジを掠らないように）。
    guard let v1Index = extremeVertexIndex(hole, isTop: true),
          let v2Index = extremeVertexIndex(hole, isTop: false),
          v1Index != v2Index else { return nil }
    let v1 = hole[v1Index]
    let v2 = hole[v2Index]

    guard let c1 = firstEastCrossing(ccwPiece, fromLat: v1.latitude, fromLng: v1.longitude),
          let c2 = firstEastCrossing(ccwPiece, fromLat: v2.latitude, fromLng: v2.longitude) else {
        return nil
    }

    // 橋が他の穴を横切るなら不可。
    for other in otherHoles {
        if horizontalSegmentIntersectsRing(other, lat: v1.latitude, x0: v1.longitude, x1: c1.x)
            || horizontalSegmentIntersectsRing(other, lat: v2.latitude, x0: v2.longitude, x1: c2.x) {
            return nil
        }
    }
    // 橋が自分の穴の他エッジを横切るケース（凹んだ穴）も不可。
    if horizontalSegmentIntersectsRing(hole, lat: v1.latitude, x0: v1.longitude, x1: c1.x, skipVertex: v1)
        || horizontalSegmentIntersectsRing(hole, lat: v2.latitude, x0: v2.longitude, x1: c2.x, skipVertex: v2) {
        return nil
    }

    let p1 = GeoPoint(latitude: v1.latitude, longitude: c1.x)
    let p2 = GeoPoint(latitude: v2.latitude, longitude: c2.x)

    // 交点を piece のエッジへ挿入（同一エッジに複数挿入される場合はエッジ始点からの距離順）。
    var augmented: [GeoPointProtocol] = []
    var p1Position = -1
    var p2Position = -1
    for (index, point) in ccwPiece.enumerated() {
        augmented.append(point)
        var inserts: [(t: Double, point: GeoPoint, isP1: Bool)] = []
        if c1.edgeIndex == index { inserts.append((c1.t, p1, true)) }
        if c2.edgeIndex == index { inserts.append((c2.t, p2, false)) }
        inserts.sort { $0.t < $1.t }
        for insert in inserts {
            augmented.append(insert.point)
            if insert.isP1 {
                p1Position = augmented.count - 1
            } else {
                p2Position = augmented.count - 1
            }
        }
    }
    guard p1Position >= 0, p2Position >= 0 else { return nil }

    // 穴の頂点列を v1→v2（配列順方向）と v2→v1（配列順方向）の 2 チェインに分ける。
    let chainF = holeChain(hole, from: v1Index, to: v2Index) // v1 → v2
    let chainG = holeChain(hole, from: v2Index, to: v1Index) // v2 → v1
    // 「東側チェイン」（v1→v2 向き）: 内部頂点の平均経度が大きい方。
    let eastChainV1toV2: [GeoPointProtocol]
    let westChainV2toV1: [GeoPointProtocol]
    if meanLng(chainF) >= meanLng(Array(chainG.reversed())) {
        eastChainV1toV2 = chainF
        westChainV2toV1 = chainG
    } else {
        eastChainV1toV2 = Array(chainG.reversed())
        westChainV2toV1 = Array(chainF.reversed())
    }

    // ring A: p2 →(piece 順方向)→ p1 → v1 →(穴 東側)→ v2 → (p2 へ閉じる)
    var ringA = walkForward(augmented, from: p2Position, to: p1Position)
    ringA.append(contentsOf: eastChainV1toV2)
    ringA = dedupeConsecutive(ringA)
    // ring B: p1 →(piece 順方向)→ p2 → v2 →(穴 西側)→ v1 → (p1 へ閉じる)
    var ringB = walkForward(augmented, from: p1Position, to: p2Position)
    ringB.append(contentsOf: westChainV2toV1)
    ringB = dedupeConsecutive(ringB)

    guard ringA.count >= 3, ringB.count >= 3 else { return nil }
    let span = abs(c1.x - v1.longitude) + abs(c2.x - v2.longitude)
    return ((ringA, ringB), span)
}

// MARK: - Helpers

private func dropClosingPoint(_ points: [GeoPointProtocol]) -> [GeoPointProtocol] {
    if points.count >= 2,
       let first = points.first, let last = points.last,
       first.latitude == last.latitude,
       first.longitude == last.longitude {
        return Array(points.dropLast())
    }
    return points
}

/// 最上端（isTop）または最下端の頂点。緯度が同じ場合は経度が大きい（東の）方。
private func extremeVertexIndex(_ ring: [GeoPointProtocol], isTop: Bool) -> Int? {
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
private func firstEastCrossing(
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
private func horizontalSegmentIntersectsRing(
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
private func holeChain(_ hole: [GeoPointProtocol], from: Int, to: Int) -> [GeoPointProtocol] {
    var chain: [GeoPointProtocol] = []
    var index = from
    while true {
        chain.append(hole[index])
        if index == to { break }
        index = (index + 1) % hole.count
    }
    return chain
}

private func meanLng(_ chain: [GeoPointProtocol]) -> Double {
    guard chain.count > 2 else {
        let lngs = chain.map { $0.longitude }
        return lngs.isEmpty ? -Double.infinity : lngs.reduce(0, +) / Double(lngs.count)
    }
    let interior = chain.dropFirst().dropLast()
    return interior.map { $0.longitude }.reduce(0, +) / Double(interior.count)
}

/// ring の from→to を配列順方向（循環）で辿った列（両端含む）。
private func walkForward(_ ring: [GeoPointProtocol], from: Int, to: Int) -> [GeoPointProtocol] {
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
private func dedupeConsecutive(_ ring: [GeoPointProtocol]) -> [GeoPointProtocol] {
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
private func evenOddContains(_ ring: [GeoPointProtocol], lat: Double, lng: Double) -> Bool {
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
