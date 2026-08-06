import XCTest

@testable import MapConductorCore

/// `MarkerState.copy()` はすべてのプロパティを引き継ぐ。
///
/// animation は以前 `animation: nil` がハードコードされており、
/// `marker.copy(position:)` で跳ねているマーカーが止まっていた。コピーであることは
/// 「アニメーションをやめる」意味を持たないので引き継ぐ。
/// android-sdk / react-sdk と同じ意味論であることをここで固定する。
final class MarkerStateCopyTests: XCTestCase {

    private func makeState(animation: MarkerAnimation? = nil) -> MarkerState {
        MarkerState(
            position: GeoPoint(latitude: 35.0, longitude: 139.0),
            id: "m1",
            animation: animation
        )
    }

    func testCopyCarriesAnimationOver() {
        let original = makeState(animation: .Bounce)
        let copied = original.copy(position: GeoPoint(latitude: 36.0, longitude: 140.0))

        XCTAssertEqual(copied.getAnimation(), .Bounce)
    }

    /// 二重オプショナルの使い分け: `.some(x)` で差し替え、`.some(nil)` で明示的に消す。
    func testCopyCanOverrideAnimation() {
        let original = makeState(animation: .Bounce)

        XCTAssertEqual(original.copy(animation: .Drop).getAnimation(), .Drop)
        XCTAssertNil(original.copy(animation: .some(nil)).getAnimation())
    }

    /// animate() で後から付けた場合も引き継ぐ（コンストラクタ引数だけを見ない）。
    func testCopyKeepsAnimationSetAfterConstruction() {
        let original = makeState()
        original.animate(.Drop)

        XCTAssertEqual(original.copy().getAnimation(), .Drop)
    }

    func testCopyKeepsOtherProperties() {
        let original = MarkerState(
            position: GeoPoint(latitude: 35.0, longitude: 139.0),
            id: "m1",
            animation: .Bounce,
            clickable: false,
            draggable: true,
            zIndex: 7
        )
        let copied = original.copy()

        XCTAssertEqual(copied.id, "m1")
        XCTAssertEqual(copied.zIndex, 7)
        XCTAssertFalse(copied.clickable)
        XCTAssertTrue(copied.draggable)
        XCTAssertEqual(copied.getAnimation(), .Bounce)
    }
}
