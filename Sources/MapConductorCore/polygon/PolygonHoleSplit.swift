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
