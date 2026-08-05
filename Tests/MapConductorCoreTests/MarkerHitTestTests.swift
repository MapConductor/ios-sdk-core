import CoreGraphics
import XCTest
@testable import MapConductorCore

/// ``MarkerHitTest`` の判定境界。
///
/// android-sdk の `StrategyMarkerController.find()` /
/// `com.mapconductor.arcgis.marker.ArcGISMarkerController.find()` と同じ
/// 「アイコン矩形 + tapTolerance」判定になっていることを押さえる。
/// 半径固定の判定に戻ってしまうと、大きいアイコンは端が反応せず小さいアイコンは
/// 離れていても反応する、という以前の挙動に戻るため、その差が出る点を明示的に見る。
final class MarkerHitTestTests: XCTestCase {
    private let tolerance = Settings.Default.tapTolerance

    /// 既定アンカー `(0.5, 1.0)`（下端中央）のアイコンを持つマーカー。
    private func marker(iconSize: CGFloat, scale: CGFloat = 1.0) -> MarkerState {
        MarkerState(
            position: GeoPoint(latitude: 0, longitude: 0),
            icon: DefaultMarkerIcon(scale: scale, iconSize: iconSize)
        )
    }

    private func hits(_ dx: CGFloat, _ dy: CGFloat, state: MarkerState) -> Bool {
        MarkerHitTest.hitsIcon(
            touchScreen: CGPoint(x: 100 + dx, y: 100 + dy),
            markerScreen: CGPoint(x: 100, y: 100),
            state: state
        )
    }

    func testAnchorPointHits() {
        XCTAssertTrue(hits(0, 0, state: marker(iconSize: 48)))
    }

    func testIconExtendsUpwardFromBottomAnchor() {
        let state = marker(iconSize: 48)
        // アンカーは下端なので、矩形はアンカーから上へ 48pt（+ 許容量）伸びる。
        XCTAssertTrue(hits(0, -48, state: state), "アイコン上端は当たること")
        XCTAssertTrue(hits(0, -48 - tolerance + 0.5, state: state), "上端 + 許容量の内側は当たること")
        XCTAssertFalse(hits(0, -48 - tolerance - 0.5, state: state), "上端 + 許容量の外側は外れること")
    }

    func testBelowAnchorOnlyToleranceApplies() {
        let state = marker(iconSize: 48)
        // アンカーより下にアイコンは無いので、許容量の分しか当たらない。
        XCTAssertTrue(hits(0, tolerance - 0.5, state: state))
        XCTAssertFalse(hits(0, tolerance + 0.5, state: state))
    }

    func testHorizontalBoundsUseHalfIconWidth() {
        let state = marker(iconSize: 48)
        let limit = 24 + tolerance // 半幅 + 許容量
        XCTAssertTrue(hits(limit - 0.5, 0, state: state))
        XCTAssertFalse(hits(limit + 0.5, 0, state: state))
        XCTAssertTrue(hits(-(limit - 0.5), 0, state: state))
    }

    /// 半径固定の判定との差。大きいアイコンは、固定半径より外側でも当たる。
    func testLargeIconHitsBeyondFixedRadius() {
        let state = marker(iconSize: 120)
        XCTAssertTrue(hits(0, -100, state: state), "大きいアイコンの上部は当たること")
        XCTAssertTrue(hits(55, 0, state: state), "大きいアイコンの左右端も当たること")
    }

    /// 逆に、小さいアイコンはアイコンから離れた場所では当たらない。
    func testSmallIconDoesNotHitFarAway() {
        let state = marker(iconSize: 16)
        XCTAssertFalse(hits(0, -40, state: state))
        XCTAssertFalse(hits(30, 0, state: state))
    }

    /// `scale` はアイコン寸法に掛かる。
    func testScaleEnlargesHitArea() {
        let state = marker(iconSize: 48, scale: 2.0)
        XCTAssertTrue(hits(0, -96, state: state))
        XCTAssertFalse(hits(0, -96 - tolerance - 0.5, state: state))
    }

    /// アイコン未設定なら ``DefaultMarkerIcon`` の寸法で判定する。
    func testNilIconUsesDefaultIconMetrics() {
        let state = MarkerState(position: GeoPoint(latitude: 0, longitude: 0))
        let icon = DefaultMarkerIcon()
        let height = icon.iconSize * icon.scale
        XCTAssertTrue(hits(0, -height, state: state))
        XCTAssertFalse(hits(0, -height - tolerance - 0.5, state: state))
    }
}
