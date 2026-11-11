import Foundation

/// マーカー帯の中での重なり順。全プロバイダで同じ規則にそろえる。
///
/// 1. `zIndex ?? 0` が大きいほど手前。
/// 2. 同じなら南（緯度が小さい）ほど手前。重なったピンの先が隠れない、地図として自然な並び。
/// 3. 緯度も同じなら西（経度が小さい）ほど手前。
///
/// 足した順・送り直した順には左右されない。帯をまたいでは効かない（帯の並びは
/// ``OverlayStacking`` が決める）。
///
/// SDK ごとに受け取れる数の形が違うので、2 つの形で返す。
///
/// - ``key(zIndex:position:)``: 小さな `Double`。整数部が zIndex、小数部 [0, 0.5) が
///   南・西の順位。浮動小数で並べる SDK（MapLibre 系の `symbol-sort-key`、MapKit の
///   `zPriority` など）向け。Float に落とす SDK では zIndex の絶対値が大きいほど
///   同順位の分解能が落ちる（zIndex が 0 付近なら緯度 1e-5 度程度まで区別できる）。
/// - ``integerKey(zIndex:position:tieSteps:)``: 整数しか受けない SDK
///   （Google の `GMSMarker.zIndex` など）向け。`zIndex × tieSteps + 順位`。
///
/// android-sdk-core / js-sdk-core にも同じ規則で置く。
@_spi(MapConductorDriver)
public enum MarkerDrawOrder {
    /// ``integerKey(zIndex:position:tieSteps:)`` と ``key(zIndex:position:)`` が受け付ける
    /// zIndex の絶対値の上限。超える値は丸める（``OverlayStacking/zIndexSpan`` と同じ）。
    public static let zIndexSpan = OverlayStacking.zIndexSpan

    /// 同順位の並び [0, 1)。南ほど、同じ緯度なら西ほど大きい。
    static func tieRank(_ position: GeoPointProtocol) -> Double {
        let latitude = min(max(position.latitude, -90.0), 90.0)
        let longitude = GeoPoint.from(position: position).wrap().longitude
        // 南ほど大きい [0, 1]。
        let south = (90.0 - latitude) / 180.0
        // 西ほど大きい [0, 1]。緯度の差より必ず小さくなるよう、ごく小さく混ぜる。
        let west = (180.0 - longitude) / 360.0
        let rank = (south * (1.0 - 1e-9) + west * 1e-9)
        return min(max(rank, 0.0), 1.0 - 1e-12)
    }

    static func clampedZIndex(_ zIndex: Int?) -> Int {
        min(max(zIndex ?? 0, -zIndexSpan), zIndexSpan)
    }

    /// 大きいほど手前。整数部が zIndex、小数部 [0, 0.5) が同順位の並び。
    public static func key(zIndex: Int?, position: GeoPointProtocol) -> Double {
        Double(clampedZIndex(zIndex)) + 0.499 * tieRank(position)
    }

    /// 大きいほど手前。`clamp(zIndex) × tieSteps + floor(順位 × tieSteps)`。
    ///
    /// `tieSteps` は同じ zIndex の中を何段に分けるか。値の幅は
    /// ±(``zIndexSpan`` + 1) × `tieSteps` に収まる。
    public static func integerKey(zIndex: Int?, position: GeoPointProtocol, tieSteps: Int) -> Int {
        let steps = max(tieSteps, 1)
        let rank = min(Int(tieRank(position) * Double(steps)), steps - 1)
        return clampedZIndex(zIndex) * steps + rank
    }
}
