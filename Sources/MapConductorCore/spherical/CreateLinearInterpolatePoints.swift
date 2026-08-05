import Foundation

/// 非測地線（直線補間）の点列を密度化する。
///
/// 分割数はセグメント長に応じて決める（`createInterpolatePoints` と同じ方式）。固定分割だと
/// 短いセグメントが多い多頂点ポリゴンで点数が頂点数×分割数に膨れ上がり、WebView ブリッジや
/// ネイティブジオメトリ構築が極端に遅くなるため、`maxSegmentLength` を超えるセグメントのみ
/// 分割する。android-sdk / react-sdk と同一仕様。
func densifyAlongStraightLine(
    _ points: [GeoPointProtocol],
    maxSegmentLength: Double = 10_000.0
) -> [GeoPointProtocol] {
    guard points.count >= 2 else { return points }

    var results: [GeoPointProtocol] = [points[0]]

    for index in 1 ..< points.count {
        let from = points[index - 1]
        let to = points[index]
        let distance = WGS84Geodesic.computeDistanceBetween(from: from, to: to)
        let numSegments = max(Int(distance / maxSegmentLength), 1)
        let step = 1.0 / Double(numSegments)
        var fraction = step
        while fraction < 1.0 {
            results.append(Planar.interpolate(from: from, to: to, fraction: fraction))
            fraction += step
        }
        results.append(to)
    }

    return results
}
