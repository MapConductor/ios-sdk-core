import Foundation

/// 穴が 1 つのピースを、橋 2 本で 2 つの単純リングへ割る部分。
///
/// まず東向きの橋を試し、駄目なら経度を鏡像反転して西向きで再試行する。
/// 反転して同じ関数を通すことで、東西で別実装を持たずに済む。
// MARK: - Piece splitting

/// piece（CCW・開リング）を hole で 2 つの単純リングへ分割する。
/// まず東向きの橋を試し、不可なら経度を鏡像反転して再試行（=西向き）。
func splitPiece(
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

func mirroredBridgeSpan(
    _ result: (rings: ([GeoPointProtocol], [GeoPointProtocol]), bridgeSpan: Double)?
) -> Double {
    result?.bridgeSpan ?? .infinity
}

func mirrorLngPoint(_ point: GeoPointProtocol) -> GeoPointProtocol {
    GeoPoint(latitude: point.latitude, longitude: -point.longitude, altitude: point.altitude ?? 0.0)
}

/// 東向き（+x 方向）の橋 2 本で piece を分割する。piece は CCW・開リングであること。
func splitPieceEast(
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
