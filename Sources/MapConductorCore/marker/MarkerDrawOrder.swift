import Foundation

/// マーカー帯の中での重なり順。全プロバイダで同じ規則にそろえる。
///
/// 1. `zIndex ?? 0` が大きいほど手前。
/// 2. 同じなら、地図を回したあとの**画面で下にあるほど**手前（Google Maps JS の既定と同じ。
///    北が上なら南ほど手前）。
/// 3. 画面で同じ高さなら左ほど手前（北が上なら西）。Google はここを足した順で決めるが、
///    足した順・送り直した順に左右させないため、ここだけは合わせない。
///
/// 2 と 3 は地図の向き（``Frame``）で変わるので、向きが変わったら描画担当が付け直す
/// （``MarkerDrawOrderFrameReceiver``）。タイルに焼き込むマーカーはタイルが北が上で
/// 描かれるため、常に ``Frame/northUp`` で並べる。帯をまたいでは効かない（帯の並びは
/// ``OverlayStacking`` が決める）。
///
/// SDK ごとに受け取れる数の形が違うので、2 つの形で返す。
///
/// - ``key(zIndex:position:frame:)``: 小さな `Double`。整数部が zIndex、小数部 [0, 0.5) が
///   画面上の順位。浮動小数で並べる SDK（MapLibre 系の `symbol-sort-key`、MapKit の
///   `zPriority` など）向け。Float に落とす SDK では zIndex の絶対値が大きいほど
///   同順位の分解能が落ちる（zIndex が 0 付近なら数十 m 程度まで区別できる）。
/// - ``integerKey(zIndex:position:tieSteps:frame:)``: 整数しか受けない SDK
///   （Google の `GMSMarker.zIndex` など）向け。`zIndex × tieSteps + 順位`。
///
/// android-sdk-core / js-sdk-core にも同じ式・同じ名前（`headingDegrees`）で置く。
@_spi(MapConductorDriver)
public enum MarkerDrawOrder {
    /// ``integerKey(zIndex:position:tieSteps:frame:)`` と ``key(zIndex:position:frame:)`` が受け付ける
    /// zIndex の絶対値の上限。超える値は丸める（``OverlayStacking/zIndexSpan`` と同じ）。
    public static let zIndexSpan = OverlayStacking.zIndexSpan

    /// 並べるときの地図の向き。
    public struct Frame: Equatable, Sendable {
        /// カメラの向き（heading。度、画面の上が指す方位を北から時計回り）。
        ///
        /// ``MapCameraPositionProtocol/bearing``（地図の回転角）とは符号が逆。
        /// ``init(camera:)`` は ``CameraBearing/toNativeHeading(_:)`` で変換する。
        public let headingDegrees: Double
        /// 経度の折り返しの基準（ふつうは画面中心の経度）。±180° 離れたマーカー同士の
        /// 左右がここで決まる。
        public let originLongitude: Double

        public init(headingDegrees: Double = 0, originLongitude: Double = 0) {
            self.headingDegrees = headingDegrees.isFinite ? headingDegrees : 0
            self.originLongitude = originLongitude.isFinite ? originLongitude : 0
        }

        public init(camera: MapCameraPositionProtocol) {
            self.init(
                headingDegrees: CameraBearing.toNativeHeading(camera.bearing),
                originLongitude: camera.position.longitude
            )
        }

        /// 北が上。タイルに焼き込むマーカーと、向きを知らない描画担当が使う。
        public static let northUp = Frame()

        /// 付け直す価値があるほど向きが変わったか。`threshold` 度未満の回転は無視する
        /// （回転のたびに全マーカーを付け直さないため）。基準経度だけの変化は無視する:
        /// 効くのは 180° 離れたマーカー同士だけで、パンのたびに付け直す価値はない。
        public func needsReorder(from previous: Frame?, threshold: Double = 0.5) -> Bool {
            guard let previous else { return headingDegrees != 0 }
            var delta = (headingDegrees - previous.headingDegrees).truncatingRemainder(dividingBy: 360)
            if delta < -180 { delta += 360 }
            if delta >= 180 { delta -= 360 }
            return abs(delta) >= threshold
        }
    }

    /// 同順位の並び [0, 1)。回したあとの画面で下ほど、同じ高さなら左ほど大きい。
    static func tieRank(_ position: GeoPointProtocol, frame: Frame) -> Double {
        // Web メルカトルの世界座標 [0, 1]。y は北が 0、南が 1。
        let latitude = min(max(position.latitude, -85.05112878), 85.05112878)
        let sinLat = sin(latitude * .pi / 180)
        let wy = 0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)
        let wx = (position.longitude + 180) / 360
        // 基準経度からの差を [-0.5, 0.5) に折り返す。
        var dx = (wx - (frame.originLongitude + 180) / 360).truncatingRemainder(dividingBy: 1)
        if dx < -0.5 { dx += 1 }
        if dx >= 0.5 { dx -= 1 }
        let dy = wy - 0.5
        let theta = frame.headingDegrees * .pi / 180
        // 画面の下向き・右向き。|dx|,|dy| <= 0.5 なので絶対値は 1/√2 以下。
        let down = -dx * sin(theta) + dy * cos(theta)
        let right = dx * cos(theta) + dy * sin(theta)
        let down01 = 0.5 + down / 2.0.squareRoot()
        let left01 = 0.5 - right / 2.0.squareRoot()
        // 左右は上下の差より必ず小さくなるよう、ごく小さく混ぜる。
        let rank = down01 * (1.0 - 1e-9) + left01 * 1e-9
        return min(max(rank, 0.0), 1.0 - 1e-12)
    }

    static func clampedZIndex(_ zIndex: Int?) -> Int {
        min(max(zIndex ?? 0, -zIndexSpan), zIndexSpan)
    }

    /// 大きいほど手前。整数部が zIndex、小数部 [0, 0.5) が同順位の並び。
    public static func key(zIndex: Int?, position: GeoPointProtocol, frame: Frame = .northUp) -> Double {
        Double(clampedZIndex(zIndex)) + 0.45 * tieRank(position, frame: frame)
    }

    /// 大きいほど手前。`clamp(zIndex) × tieSteps + floor(順位 × tieSteps)`。
    ///
    /// `tieSteps` は同じ zIndex の中を何段に分けるか。値の幅は
    /// ±(``zIndexSpan`` + 1) × `tieSteps` に収まる。
    public static func integerKey(
        zIndex: Int?,
        position: GeoPointProtocol,
        tieSteps: Int,
        frame: Frame = .northUp
    ) -> Int {
        let steps = max(tieSteps, 1)
        let rank = min(Int(tieRank(position, frame: frame) * Double(steps)), steps - 1)
        return clampedZIndex(zIndex) * steps + rank
    }
}

/// 地図の向きが変わったときに、マーカーの重なり順を付け直す描画担当。
///
/// ``AbstractMarkerController`` / ``StrategyMarkerController`` がカメラの変化を見て、
/// ``MarkerDrawOrder/Frame/needsReorder(from:threshold:)`` が真のときだけ呼ぶ。
/// 描画担当は `frame` を覚えて以後の onAdd / onChange でも使い、`entities` のうち
/// 地図に載っているものの順位を付け直す。採用しない描画担当（向きで並びが変わらない、
/// または並びを指定できない SDK）には何も届かない。
///
/// ``MarkerOverlayRendererProtocol`` の要件にしないのは、公開プロトコルを外で実装している
/// 描画担当を壊さないため。
@_spi(MapConductorDriver)
@MainActor
public protocol MarkerDrawOrderFrameReceiver: AnyObject {
    associatedtype ActualMarker
    func onDrawOrderFrameChanged(_ frame: MarkerDrawOrder.Frame, entities: [MarkerEntity<ActualMarker>]) async
}

@MainActor
func dispatchDrawOrderFrame<ActualMarker>(
    to renderer: Any,
    frame: MarkerDrawOrder.Frame,
    entities: () -> [MarkerEntity<ActualMarker>]
) async {
    guard let receiver = renderer as? any MarkerDrawOrderFrameReceiver else { return }
    await send(receiver, frame: frame, entities: entities())
}

@MainActor
private func send<Receiver: MarkerDrawOrderFrameReceiver, ActualMarker>(
    _ receiver: Receiver,
    frame: MarkerDrawOrder.Frame,
    entities: [MarkerEntity<ActualMarker>]
) async {
    guard let typed = entities as? [MarkerEntity<Receiver.ActualMarker>] else { return }
    await receiver.onDrawOrderFrameChanged(frame, entities: typed)
}
