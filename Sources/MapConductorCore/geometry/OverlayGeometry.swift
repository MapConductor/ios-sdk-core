import Foundation

// ポリライン／ポリゴン描画用の共通ジオメトリパイプライン（unwrap 版）。
//
// Mapbox GL / MapLibre GL（MapTiler 含む）は GeoJSON の経度が [-180, 180] を超えていても
// そのまま描画できる。経度を連続化（unwrap）した単一ジオメトリを渡せば、±180 跨ぎでも
// 分割不要で継ぎ目が出ず、外周が分割されることによる「穴を含められない」制約も無くなる。
// 経度 ±180 に制約のある SDK は従来どおり normalize + `splitByMeridian`／
// `splitRingByMeridian` を使うこと。android-sdk の geometry パッケージと同一仕様。

/// ポリゴンの外周リングと穴リング。リングは閉じていない
/// （末尾に先頭点を追加する処理は各ドライバーの座標変換後に行う）。
public struct PolygonRings {
    public let outerRings: [[GeoPointProtocol]]
    public let holeRings: [[GeoPointProtocol]]

    public init(outerRings: [[GeoPointProtocol]], holeRings: [[GeoPointProtocol]]) {
        self.outerRings = outerRings
        self.holeRings = holeRings
    }
}

/// geodesic に応じた補間で点列を密度化し、緯度経度を正規化して返す。
public func densifyAndNormalize(
    _ points: [GeoPointProtocol],
    geodesic: Bool,
    maxSegmentLength: Double = 10_000.0
) -> [GeoPointProtocol] {
    let interpolated = geodesic
        ? WGS84Geodesic.createInterpolatePoints(points, maxSegmentLength: maxSegmentLength)
        : Planar.createInterpolatePoints(points)
    return interpolated.map { $0.normalize() }
}

// ─── 分割版パイプライン（経度 ±180 に制約のある SDK 向け） ─────────────────────
//
// 経度 ±180 を超える座標を受け付けない SDK（ネイティブオーバーレイ系）は、密度化・正規化後に
// 子午線で分割した複数リングとして描画する。GL 系は代わりに `buildUnwrappedPolylinePath`／
// `buildUnwrappedPolygonRings`（unwrap 版）を使うこと。android-sdk と同一仕様。

/// ポリライン用パイプライン（分割版）。密度化・正規化後に子午線で分割したセグメント列を返す。
/// 頂点 2 未満の入力、および分割で 2 点未満になったセグメントは除く（空配列になり得る）。
public func buildPolylineSegments(
    _ points: [GeoPointProtocol],
    geodesic: Bool
) -> [[GeoPointProtocol]] {
    guard points.count >= 2 else { return [] }
    return splitByMeridian(densifyAndNormalize(points, geodesic: geodesic), geodesic: geodesic)
        .filter { $0.count >= 2 }
}

/// ポリゴン用パイプライン（分割版）。外周を密度化→分割し、穴も同じ方式で密度化する。
///
/// 外周が子午線で複数リングに分割された場合、穴を分割後の各ピースへ再割当てできないため
/// 穴を含めない（従来から全 GeoJSON 系ドライバー共通の仕様）。頂点 3 未満の外周入力は
/// 空の結果を返し、3 点未満に縮退したリングは除外する。
public func buildPolygonRings(
    points: [GeoPointProtocol],
    holes: [[GeoPointProtocol]],
    geodesic: Bool
) -> PolygonRings {
    guard points.count >= 3 else { return PolygonRings(outerRings: [], holeRings: []) }
    let outerRings = splitRingByMeridian(
        densifyAndNormalize(points, geodesic: geodesic),
        geodesic: geodesic
    ).filter { $0.count >= 3 }
    let includeHoles = !holes.isEmpty && outerRings.count == 1
    let holeRings = includeHoles
        ? holes
            .filter { $0.count >= 3 }
            .map { densifyAndNormalize($0, geodesic: geodesic) }
            .filter { $0.count >= 3 }
        : []
    return PolygonRings(outerRings: outerRings, holeRings: holeRings)
}

/// 密度化済みの点列の経度を、直前の点からの最短差分を積み上げる形で連続化する。
/// 先頭点は `anchorLng`（省略時は正規化した自身の経度）から ±180 以内に配置する。
private func unwrapContinuous(
    _ points: [GeoPointProtocol],
    anchorLng: Double? = nil
) -> [GeoPointProtocol] {
    guard let first = points.first else { return points }
    var result: [GeoPointProtocol] = []
    result.reserveCapacity(points.count)
    var prevLng: Double
    if let anchorLng {
        prevLng = anchorLng + normalizeLngDegrees(first.longitude - anchorLng)
    } else {
        prevLng = normalizeLngDegrees(first.longitude)
    }
    result.append(GeoPoint(latitude: first.latitude, longitude: prevLng))
    for i in 1 ..< points.count {
        let p = points[i]
        prevLng += normalizeLngDegrees(p.longitude - points[i - 1].longitude)
        result.append(GeoPoint(latitude: p.latitude, longitude: prevLng))
    }
    return result
}

/// ポリライン用パイプライン（unwrap 版）。密度化後に経度を連続化した単一パスを返す。
/// 頂点 2 未満の入力は空配列を返す。
public func buildUnwrappedPolylinePath(
    _ points: [GeoPointProtocol],
    geodesic: Bool,
    maxSegmentLength: Double = 10_000.0
) -> [GeoPointProtocol] {
    guard points.count >= 2 else { return [] }
    return unwrapContinuous(
        densifyAndNormalize(points, geodesic: geodesic, maxSegmentLength: maxSegmentLength)
    )
}

/// ポリゴン用パイプライン（unwrap 版）。外周・穴とも密度化し、外周の先頭経度を基準に
/// 同一の連続座標系へ unwrap する（±180 跨ぎでも常に外周 1 リング + 全穴を返せる）。
/// 頂点 3 未満の外周入力は空の結果を返し、3 点未満に縮退した穴は除外する。
public func buildUnwrappedPolygonRings(
    points: [GeoPointProtocol],
    holes: [[GeoPointProtocol]],
    geodesic: Bool,
    maxSegmentLength: Double = 10_000.0
) -> PolygonRings {
    guard points.count >= 3 else { return PolygonRings(outerRings: [], holeRings: []) }
    let outer = unwrapContinuous(
        densifyAndNormalize(points, geodesic: geodesic, maxSegmentLength: maxSegmentLength)
    )
    let anchor = outer[0].longitude
    let holeRings = holes
        .filter { $0.count >= 3 }
        .map { hole in
            unwrapContinuous(
                densifyAndNormalize(hole, geodesic: geodesic, maxSegmentLength: maxSegmentLength),
                anchorLng: anchor
            )
        }
        .filter { $0.count >= 3 }
    return PolygonRings(outerRings: [outer], holeRings: holeRings)
}
