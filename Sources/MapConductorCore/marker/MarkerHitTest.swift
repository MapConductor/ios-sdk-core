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
        let extent = extentRatio(of: icon)
        let iconWidth = icon.iconSize * icon.scale * extent.width
        let iconHeight = icon.iconSize * icon.scale * extent.height
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

    /// アイコンの矩形がピン本体（iconSize × scale の正方形）の何倍か。`anchor` はこの矩形に対する割合。
    /// 既定アイコンはラベルの分だけビットマップが広いことがあるので実寸から求め、それ以外は正方形とする。
    /// android-sdk の `MarkerIconExtent`、react-sdk の `markerIconExtentPx` に対応する。
    static func extentRatio(of icon: any MarkerIconProtocol) -> CGSize {
        guard icon is ColorDefaultIcon || icon is ImageDefaultIcon else { return CGSize(width: 1, height: 1) }
        let base = icon.iconSize * icon.scale
        guard base > 0 else { return CGSize(width: 1, height: 1) }
        let size = icon.toBitmapIcon().size
        return CGSize(width: size.width / base, height: size.height / base)
    }

    /// アンカー点を投影した画面座標と、そのアイコンの矩形（pt）。`pickIndex` の入力。
    @_spi(MapConductorDriver)
    public struct ScreenRect {
        public let anchorScreen: CGPoint
        public let width: CGFloat
        public let height: CGFloat
        public let anchor: CGPoint

        public init(anchorScreen: CGPoint, width: CGFloat, height: CGFloat, anchor: CGPoint) {
            self.anchorScreen = anchorScreen
            self.width = width
            self.height = height
            self.anchor = anchor
        }

        func contains(dx: CGFloat, dy: CGFloat, tolerance: CGFloat) -> Bool {
            let left = -anchor.x * width - tolerance
            let right = (1 - anchor.x) * width + tolerance
            let top = -anchor.y * height - tolerance
            let bottom = (1 - anchor.y) * height + tolerance
            return dx >= left && dx <= right && dy >= top && dy <= bottom
        }
    }

    /// タップ点に当たるマーカーを選ぶ規則（android-sdk の `MarkerHitTest.pickIndex`、
    /// react-sdk の `pickMarkerIndex` と同じ）。
    ///
    /// 1. アイコン（ラベル込み）の矩形そのものにタップ点が入っているものがあれば、その中で
    ///    画面上いちばん下にアンカーがあるもの（手前に描かれるもの）を選ぶ。近くに別のマーカーの
    ///    先端があっても、指の下に描かれているマーカーが勝つ。
    /// 2. どの矩形にも入っていなければ、矩形 + `tolerance` に入るもののうち、アンカーが
    ///    タップ点にいちばん近いものを選ぶ。
    @_spi(MapConductorDriver)
    public static func pickIndex(
        touch: CGPoint,
        rects: [ScreenRect],
        tolerance: CGFloat = Settings.Default.tapTolerance
    ) -> Int? {
        var exact: Int?
        var exactY = -CGFloat.greatestFiniteMagnitude
        var near: Int?
        var nearDistance = CGFloat.greatestFiniteMagnitude
        for (index, rect) in rects.enumerated() {
            let dx = touch.x - rect.anchorScreen.x
            let dy = touch.y - rect.anchorScreen.y
            if rect.contains(dx: dx, dy: dy, tolerance: 0) {
                if rect.anchorScreen.y > exactY {
                    exact = index
                    exactY = rect.anchorScreen.y
                }
            } else if exact == nil, rect.contains(dx: dx, dy: dy, tolerance: tolerance) {
                let distance = hypot(dx, dy)
                if distance < nearDistance {
                    near = index
                    nearDistance = distance
                }
            }
        }
        return exact ?? near
    }

    /// 既定の大きさ（iconSize × scale × ラベルの広がり）で `ScreenRect` を作る。
    @_spi(MapConductorDriver)
    public static func screenRect(
        anchorScreen: CGPoint,
        state: MarkerState,
        defaultIcon: any MarkerIconProtocol = DefaultMarkerIcon()
    ) -> ScreenRect {
        let icon = state.icon ?? defaultIcon
        let extent = extentRatio(of: icon)
        let base = icon.iconSize * icon.scale
        return ScreenRect(
            anchorScreen: anchorScreen,
            width: base * extent.width,
            height: base * extent.height,
            anchor: icon.anchor
        )
    }

    /// `candidates` の中からタップ点に当たるマーカーを `pickIndex` の規則で選ぶ。
    @_spi(MapConductorDriver)
    public static func pick<T>(
        touchScreen: CGPoint,
        candidates: [T],
        state: (T) -> MarkerState,
        project: (GeoPointProtocol) -> CGPoint?,
        defaultIcon: any MarkerIconProtocol = DefaultMarkerIcon()
    ) -> T? {
        var projected: [T] = []
        var rects: [ScreenRect] = []
        projected.reserveCapacity(candidates.count)
        rects.reserveCapacity(candidates.count)
        for candidate in candidates {
            let markerState = state(candidate)
            guard let anchorScreen = project(markerState.position) else { continue }
            projected.append(candidate)
            rects.append(screenRect(anchorScreen: anchorScreen, state: markerState, defaultIcon: defaultIcon))
        }
        return pickIndex(touch: touchScreen, rects: rects).map { projected[$0] }
    }

    /// 候補を集める範囲。タップ点から画面上 `searchRadius` 以内に先端があるマーカーを含む。
    ///
    /// ラベルを横に置くとアイコンはピンより大きく広がるので、最寄りの 1 つだけでは足りない。
    /// pt → 度の換算は、タップ点の近くを投影して局所的に求める（回転していても各軸の長さは保たれる）。
    @_spi(MapConductorDriver)
    public static func searchBounds(
        position: GeoPointProtocol,
        touchScreen: CGPoint,
        project: (GeoPointProtocol) -> CGPoint?,
        searchRadius: CGFloat = searchRadius
    ) -> GeoRectBounds? {
        let epsilon = 1e-4
        guard let north = project(GeoPoint(latitude: position.latitude + epsilon, longitude: position.longitude)),
              let east = project(GeoPoint(latitude: position.latitude, longitude: position.longitude + epsilon))
        else { return nil }
        let ptPerDegLat = Double(hypot(north.x - touchScreen.x, north.y - touchScreen.y)) / epsilon
        let ptPerDegLon = Double(hypot(east.x - touchScreen.x, east.y - touchScreen.y)) / epsilon
        guard ptPerDegLat > 0, ptPerDegLon > 0 else { return nil }
        let halfLat = Double(searchRadius) / ptPerDegLat
        let halfLon = Double(searchRadius) / ptPerDegLon
        return GeoRectBounds(
            southWest: GeoPoint(latitude: max(position.latitude - halfLat, -90), longitude: position.longitude - halfLon),
            northEast: GeoPoint(latitude: min(position.latitude + halfLat, 90), longitude: position.longitude + halfLon)
        )
    }

    /// 候補を探す半径（pt）。ラベルの長さの上限の目安で、これより遠くまで伸びたラベルの端は拾えない。
    @_spi(MapConductorDriver)
    public static let searchRadius: CGFloat = 256
}
