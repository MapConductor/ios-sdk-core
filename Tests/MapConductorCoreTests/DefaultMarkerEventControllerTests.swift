import CoreGraphics
import XCTest
@testable import MapConductorCore

/// ``DefaultMarkerEventController`` の状態遷移。
///
/// 移行前は ios-for-maplibre / ios-for-maptiler が同じ 84 行を持っていて、
/// **どちらもテストが無かった**。地図 SDK に触れない形へ引き上げたので、
/// ここで実機を使わずに契約を固定できる。
///
/// 特に **「掴む前の isScrollEnabled へ戻す」** を落とすと、アプリが
/// `uiSettings.scrollGesture = false` にしていた地図がドラッグ後に動くようになる。
/// 実機の目視では気づきにくい（ドラッグ後にわざわざパンを試さないと出ない）。
@MainActor
final class DefaultMarkerEventControllerTests: XCTestCase {
    private final class FakeSurface: MarkerDragSurface {
        var isScrollEnabled = true
        /// 画面座標 (x, y) を (lat, lng) = (y, x) にそのまま写す。検証を読みやすくするため。
        func geoPoint(atScreenPoint point: CGPoint) -> GeoPoint? {
            GeoPoint(latitude: Double(point.y), longitude: Double(point.x), altitude: 0)
        }
    }

    private final class FakeHost: MarkerEventHostProtocol {
        var markerIdAtPoint: String?
        var states: [String: MarkerState] = [:]
        var tiledTapResult = false

        var log: [String] = []
        var bubbleUpdates: [String] = []

        func markerId(atScreenPoint _: CGPoint) -> String? { markerIdAtPoint }
        func markerState(for id: String) -> MarkerState? { states[id] }
        func handleTiledMarkerTap(atScreenPoint _: CGPoint) -> Bool {
            log.append("tiled")
            return tiledTapResult
        }

        func dispatchClick(state: MarkerState) { log.append("click:\(state.id)") }
        func dispatchDragStart(state: MarkerState) { log.append("dragStart:\(state.id)") }
        func dispatchDrag(state: MarkerState) { log.append("drag:\(state.id)") }
        func dispatchDragEnd(state: MarkerState) { log.append("dragEnd:\(state.id)") }
        func onUpdateInfoBubble(_ markerId: String) { bubbleUpdates.append(markerId) }
    }

    private func makeMarker(id: String, clickable: Bool = true, draggable: Bool = false) -> MarkerState {
        MarkerState(
            position: GeoPoint(latitude: 0, longitude: 0, altitude: 0),
            id: id,
            clickable: clickable,
            draggable: draggable
        )
    }

    private func fixture() -> (FakeSurface, FakeHost, DefaultMarkerEventController) {
        let surface = FakeSurface()
        let host = FakeHost()
        return (surface, host, DefaultMarkerEventController(surface: surface, host: host))
    }

    // MARK: - タップ

    func testTapDispatchesClickForNativeMarker() {
        let (_, host, controller) = fixture()
        host.markerIdAtPoint = "m1"
        host.states["m1"] = makeMarker(id: "m1")

        XCTAssertTrue(controller.handleTap(at: CGPoint(x: 10, y: 20)))
        XCTAssertEqual(host.log, ["click:m1"])
    }

    /// `clickable = false` のマーカーはタイル方式の経路へ落とす。
    /// 握り潰さない（＝地図クリックまで届きうる）のが 3 プラットフォーム共通の契約。
    func testTapFallsThroughWhenNotClickable() {
        let (_, host, controller) = fixture()
        host.markerIdAtPoint = "m1"
        host.states["m1"] = makeMarker(id: "m1", clickable: false)

        XCTAssertFalse(controller.handleTap(at: .zero))
        XCTAssertEqual(host.log, ["tiled"], "clickable=false でクリックを配送してはいけない")
    }

    func testTapFallsBackToTiledMarkers() {
        let (_, host, controller) = fixture()
        host.markerIdAtPoint = nil
        host.tiledTapResult = true

        XCTAssertTrue(controller.handleTap(at: .zero))
        XCTAssertEqual(host.log, ["tiled"])
    }

    // MARK: - ドラッグ

    func testDragLifecycleMovesMarkerAndUpdatesBubble() {
        let (surface, host, controller) = fixture()
        let marker = makeMarker(id: "m1", draggable: true)
        host.markerIdAtPoint = "m1"
        host.states["m1"] = marker

        XCTAssertTrue(controller.handleLongPress(state: .began, at: CGPoint(x: 1, y: 2)))
        XCTAssertFalse(surface.isScrollEnabled, "掴んでいる間はパンを止める")

        XCTAssertTrue(controller.handleLongPress(state: .changed, at: CGPoint(x: 30, y: 40)))
        XCTAssertEqual(marker.position.latitude, 40)
        XCTAssertEqual(marker.position.longitude, 30)

        XCTAssertTrue(controller.handleLongPress(state: .ended, at: CGPoint(x: 30, y: 40)))
        XCTAssertEqual(host.log, ["dragStart:m1", "drag:m1", "dragEnd:m1"])
        XCTAssertEqual(host.bubbleUpdates, ["m1", "m1", "m1"], "吹き出しはマーカーに追従する")
    }

    /// 離した点で位置を確定させる。react-sdk の `finishDrag` と同じ。
    func testDragEndCommitsReleasePosition() {
        let (_, host, controller) = fixture()
        let marker = makeMarker(id: "m1", draggable: true)
        host.markerIdAtPoint = "m1"
        host.states["m1"] = marker

        XCTAssertTrue(controller.handleLongPress(state: .began, at: CGPoint(x: 1, y: 2)))
        XCTAssertTrue(controller.handleLongPress(state: .changed, at: CGPoint(x: 10, y: 10)))
        XCTAssertTrue(controller.handleLongPress(state: .ended, at: CGPoint(x: 55, y: 66)))

        XCTAssertEqual(marker.position.latitude, 66)
        XCTAssertEqual(marker.position.longitude, 55)
    }

    func testDraggableFalseIsNotGrabbed() {
        let (surface, host, controller) = fixture()
        host.markerIdAtPoint = "m1"
        host.states["m1"] = makeMarker(id: "m1", draggable: false)

        XCTAssertFalse(controller.handleLongPress(state: .began, at: .zero))
        XCTAssertTrue(surface.isScrollEnabled, "掴めなかったならパンは止めない")
        XCTAssertEqual(host.log, [])
    }

    /// **回帰の本命。** ドラッグ後に `true` を代入してしまうと、
    /// パンを切ってある地図が動くようになる。掴む前の値へ戻すこと。
    func testScrollRestoresToPreDragValue() {
        for before in [true, false] {
            let (surface, host, controller) = fixture()
            surface.isScrollEnabled = before
            host.markerIdAtPoint = "m1"
            host.states["m1"] = makeMarker(id: "m1", draggable: true)

            XCTAssertTrue(controller.handleLongPress(state: .began, at: .zero))
            XCTAssertFalse(surface.isScrollEnabled)
            XCTAssertTrue(controller.handleLongPress(state: .ended, at: .zero))

            XCTAssertEqual(surface.isScrollEnabled, before, "掴む前が \(before) なら \(before) へ戻す")
        }
    }

    func testCancelReleasesGrabAndRestoresScroll() {
        let (surface, host, controller) = fixture()
        surface.isScrollEnabled = false
        host.markerIdAtPoint = "m1"
        host.states["m1"] = makeMarker(id: "m1", draggable: true)

        XCTAssertTrue(controller.handleLongPress(state: .began, at: .zero))
        XCTAssertTrue(controller.handleLongPress(state: .cancelled, at: .zero))
        XCTAssertFalse(surface.isScrollEnabled)

        // 掴みが解けているので、次の .changed は何も配送しない。
        XCTAssertFalse(controller.handleLongPress(state: .changed, at: CGPoint(x: 5, y: 5)))
        XCTAssertEqual(host.log, ["dragStart:m1"])
    }

    /// 掴んでいないところで長押ししただけならジェスチャを消費しない。
    /// ここで true を返すと、地図の長押しが二度と効かなくなる。
    func testUngrabbedGestureIsNotConsumed() {
        let (_, _, controller) = fixture()
        XCTAssertFalse(controller.handleLongPress(state: .changed, at: .zero))
        XCTAssertFalse(controller.handleLongPress(state: .cancelled, at: .zero))
        XCTAssertFalse(controller.handleLongPress(state: .other, at: .zero))
    }

    /// **回帰の本命その2。** `surface` は呼び出し側が `super.init` の引数として作る
    /// 薄いアダプタで、他に持ち主がいない。コアが weak で持つと生成直後に解放され、
    /// **ドラッグだけが黙って死ぬ**（タップは surface を使わないので気づけない）。
    ///
    /// 実際に一度この形で壊し、実機の A/B 比較で拾った。ここで固定する。
    func testSurfaceIsRetainedWhenCallerKeepsNoReference() {
        let host = FakeHost()
        host.markerIdAtPoint = "m1"
        host.states["m1"] = makeMarker(id: "m1", draggable: true)
        // FakeSurface をローカルにも保持しない。プロバイダの書き方をそのまま再現する。
        let controller = DefaultMarkerEventController(surface: FakeSurface(), host: host)

        XCTAssertTrue(
            controller.handleLongPress(state: .began, at: .zero),
            "surface を weak で持つとここが false になる"
        )
        XCTAssertEqual(host.log, ["dragStart:m1"])
    }

    func testUnbindRestoresScrollWhileGrabbed() {
        let (surface, host, controller) = fixture()
        host.markerIdAtPoint = "m1"
        host.states["m1"] = makeMarker(id: "m1", draggable: true)

        XCTAssertTrue(controller.handleLongPress(state: .began, at: .zero))
        controller.unbind()
        XCTAssertTrue(surface.isScrollEnabled, "掴んだまま地図が消えてもパンは戻す")
    }
}
