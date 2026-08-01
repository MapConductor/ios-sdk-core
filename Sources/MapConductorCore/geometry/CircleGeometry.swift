import Foundation

/// 円リング近似の既定分割数。
public let defaultCircleSegments = 128

/// 経度を [-180, 180] へ正規化する（geometry モジュール共有ヘルパー）。
func normalizeLngDegrees(_ lng: Double) -> Double {
    (((lng + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0)
        .truncatingRemainder(dividingBy: 360.0)) - 180.0
}

/// 円を頂点列（開いたリング）へ変換する共通ジオメトリ。各ドライバーはこの結果を
/// 自 SDK の型へ変換して描画するだけにする（円の形状定義を全プロバイダで統一する）。
///
/// - geodesic=true : 球面上で中心から等距離のリング（`Spherical.computeOffset`）。
/// - geodesic=false: 中心緯度の局所平面（正距円筒）近似での等距離リング。
///   小さな半径・低〜中緯度では geodesic とほぼ一致する。
///
/// 経度は中心経度まわりに連続化（unwrap）して返す。±180 を跨ぐ円でも経度が飛ばないため、
/// 範囲外経度を扱える GL 系 SDK（Mapbox/MapLibre 等）はこのまま 1 枚のポリゴンとして
/// 描画できる（子午線の継ぎ目が出ない）。経度 ±180 に制約のある SDK は、各点を
/// normalize してから `splitRingByMeridian` で分割すること。
///
/// リングは閉じていない（必要なら `closeRing` を使う）。半径 0 以下・分割数 3 未満は
/// 空配列を返す。android-sdk / react-sdk の `circleToRing` と同一仕様。
public func circleToRing(
    center: GeoPointProtocol,
    radiusMeters: Double,
    geodesic: Bool,
    segments: Int = defaultCircleSegments
) -> [GeoPointProtocol] {
    guard radiusMeters > 0.0, segments >= 3 else { return [] }
    if geodesic {
        return (0 ..< segments).map { i -> GeoPointProtocol in
            let p = Spherical.computeOffset(
                origin: center,
                distance: radiusMeters,
                heading: 360.0 * Double(i) / Double(segments)
            )
            return GeoPoint(
                latitude: p.latitude,
                // 中心経度まわりに連続化する。
                longitude: center.longitude + normalizeLngDegrees(p.longitude - center.longitude)
            )
        }
    }
    let metersPerDegree = Earth.circumferenceMeters / 360.0
    // 極付近で経度補正が発散しないよう下限を設ける。
    let latCorrection = max(cos(center.latitude * .pi / 180.0), 1e-6)
    return (0 ..< segments).map { i -> GeoPointProtocol in
        let angle = 2.0 * .pi * Double(i) / Double(segments)
        let deltaLat = radiusMeters / metersPerDegree * cos(angle)
        let deltaLng = radiusMeters / (metersPerDegree * latCorrection) * sin(angle)
        return GeoPoint(
            latitude: min(max(center.latitude + deltaLat, -90.0), 90.0),
            longitude: center.longitude + deltaLng
        )
    }
}

/// リングが閉じていなければ先頭点を末尾へ追加して閉じる。
public func closeRing(_ ring: [GeoPointProtocol]) -> [GeoPointProtocol] {
    guard let first = ring.first, let last = ring.last else { return ring }
    if first.latitude == last.latitude, first.longitude == last.longitude {
        return ring
    }
    return ring + [first]
}
