import CoreGraphics

/// マーカーのタップ判定（スクリーン空間）。
///
/// android-sdk の `StrategyMarkerController.find()` /
/// `com.mapconductor.arcgis.marker.ArcGISMarkerController.find()` が共通で行っている
/// 「アイコンの矩形 + `Settings.Default.tapTolerance`」判定を、iOS 側でも 1 箇所に集約したもの。
///
/// 半径固定の円で判定すると、大きいアイコンは端をタップしても反応せず、小さいアイコンは
/// 離れた場所でも反応してしまう。アイコンの実寸とアンカーを使うことで、見た目どおりの
/// 当たり判定になる。
public enum MarkerHitTest {
    /// タップ点がマーカーアイコンの矩形（＋許容量）に入っているか。
    ///
    /// - Parameters:
    ///   - touchScreen: タップ位置（ビューのポイント座標）。
    ///   - markerScreen: マーカーのアンカー点を投影したビュー座標。
    ///   - state: 判定対象のマーカー。
    ///   - defaultIcon: `state` がアイコンを持たないときに使う既定アイコン。
    ///
    /// アンカーは「アイコン内のどこがマーカー位置に一致するか」を 0..1 で表す。例えば
    /// ピン形状の既定アンカー `(0.5, 1.0)` なら、矩形はアンカー点から上方向へ広がる。
    ///
    /// iOS の投影はポイント単位で返るため、Android のような画面密度倍は掛けない。
    public static func hitsIcon(
        touchScreen: CGPoint,
        markerScreen: CGPoint,
        state: MarkerState,
        defaultIcon: any MarkerIconProtocol = DefaultMarkerIcon()
    ) -> Bool {
        let icon = state.icon ?? defaultIcon
        let iconWidth = icon.iconSize * icon.scale
        let iconHeight = icon.iconSize * icon.scale
        let anchorX = icon.anchor.x
        let anchorY = icon.anchor.y
        let tolerance = Settings.Default.tapTolerance
        let dx = touchScreen.x - markerScreen.x
        let dy = touchScreen.y - markerScreen.y
        let left = -anchorX * iconWidth - tolerance
        let right = (1 - anchorX) * iconWidth + tolerance
        let top = -anchorY * iconHeight - tolerance
        let bottom = (1 - anchorY) * iconHeight + tolerance
        return dx >= left && dx <= right && dy >= top && dy <= bottom
    }
}
