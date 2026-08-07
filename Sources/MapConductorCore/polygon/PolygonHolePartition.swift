import Foundation

/// 穴を 1 つずつに分けるための前処理。
///
/// 穴が複数ある外周をいきなり分割しようとすると、橋どうしが交差して破綻する。
/// まず緯度線で切って「1 ピースにつき穴は高々 1 つ」の形へ落とし、そのうえで
/// ``splitPiece`` に渡す。緯度線の選び方（穴と穴の隙間）が [separatingLatitude]。
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

func transposePoint(_ point: GeoPointProtocol) -> GeoPointProtocol {
    GeoPoint(latitude: point.longitude, longitude: point.latitude, altitude: point.altitude ?? 0.0)
}

/// 穴群を 2 グループに分ける緯度（どの穴の緯度範囲にも重ならず、リングの頂点とも一致しない値）。
func separatingLatitude(_ holes: [[GeoPointProtocol]], ring: [GeoPointProtocol]) -> Double? {
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
