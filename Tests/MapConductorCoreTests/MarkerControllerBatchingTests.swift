import UIKit
import XCTest

@testable import MapConductorCore

/// `AbstractMarkerController.add(data:)` のバッチ分割が android-sdk と一致することを確認する。
///
/// android-sdk（`AbstractMarkerController.kt`）は `added` / `updated` を
/// `MARKER_RENDER_BATCH_SIZE = 500` 件ずつに `chunked` してレンダラを呼び、
/// 各バッチの後に `yield()` する。以前の iOS 実装は全件を 1 回の `onAdd` に渡しており、
/// 数万件のマーカー投入中にメインアクタが解放されなかった。
@MainActor
final class MarkerControllerBatchingTests: XCTestCase {
    // MARK: - Test doubles

    /// 受け取ったバッチのサイズだけを記録するレンダラ。
    final class RecordingRenderer: MarkerOverlayRendererProtocol {
        typealias ActualMarker = FakeMarker

        var animateStartListener: OnMarkerEventHandler?
        var animateEndListener: OnMarkerEventHandler?

        private(set) var addBatchSizes: [Int] = []
        private(set) var changeBatchSizes: [Int] = []
        private(set) var removeBatchSizes: [Int] = []
        private(set) var postProcessCount = 0

        func onAdd(data: [MarkerOverlayAddParams]) async -> [FakeMarker?] {
            addBatchSizes.append(data.count)
            return data.map { FakeMarker(id: $0.state.id) }
        }

        func onChange(data: [MarkerOverlayChangeParams<FakeMarker>]) async -> [FakeMarker?] {
            changeBatchSizes.append(data.count)
            return data.map { FakeMarker(id: $0.current.state.id) }
        }

        func onRemove(data: [MarkerEntity<FakeMarker>]) async {
            removeBatchSizes.append(data.count)
        }

        func onAnimate(entity: MarkerEntity<FakeMarker>) async {}

        func onPostProcess() async {
            postProcessCount += 1
        }
    }

    final class FakeMarker {
        let id: String
        init(id: String) { self.id = id }
    }

    /// `find(position:)` が `fatalError` なので具象サブクラスを用意する。
    final class TestMarkerController: AbstractMarkerController<FakeMarker, RecordingRenderer> {
        override func find(position: GeoPointProtocol) -> MarkerEntity<FakeMarker>? { nil }
    }

    // MARK: - Helpers

    private func states(_ count: Int) -> [MarkerState] {
        (0..<count).map { index in
            MarkerState(
                position: GeoPoint(
                    latitude: 35.0 + Double(index) * 1e-5,
                    longitude: 139.0 + Double(index) * 1e-5
                ),
                id: "marker-\(index)"
            )
        }
    }

    private func makeController() -> (TestMarkerController, RecordingRenderer) {
        let renderer = RecordingRenderer()
        let controller = TestMarkerController(
            markerManager: MarkerManager<FakeMarker>(),
            renderer: renderer
        )
        return (controller, renderer)
    }

    // MARK: - Tests

    /// 500 件ちょうどは 1 バッチ。
    func testAddAtBatchSizeIsSingleBatch() async {
        let (controller, renderer) = makeController()
        await controller.add(data: states(markerRenderBatchSize))
        XCTAssertEqual(renderer.addBatchSizes, [500])
    }

    /// 500 件を超えたら 500 + 余りに分割される（android-sdk の `chunked` と同じ）。
    func testAddSplitsIntoBatchesOf500() async {
        let (controller, renderer) = makeController()
        await controller.add(data: states(1250))
        XCTAssertEqual(renderer.addBatchSizes, [500, 500, 250])
    }

    /// 分割してもすべてのマーカーが MarkerManager に登録される。
    func testAllMarkersRegisteredAcrossBatches() async {
        let (controller, _) = makeController()
        await controller.add(data: states(1250))
        XCTAssertEqual(controller.markerManager.allEntities().count, 1250)
        // 各バッチ内の index がグローバル index とずれていないこと（`batch[index]` の検証）。
        for index in [0, 499, 500, 999, 1000, 1249] {
            let entity = controller.markerManager.getEntity("marker-\(index)")
            XCTAssertEqual(entity?.marker?.id, "marker-\(index)", "index \(index) がずれている")
        }
    }

    /// 2 回目の add は既存 id を `onChange` 側へ回し、そちらも 500 件で分割される。
    func testUpdateSplitsIntoBatchesOf500() async {
        let (controller, renderer) = makeController()
        let initial = states(1250)
        await controller.add(data: initial)

        // 位置を動かして fingerPrint を変える
        let moved = initial.map { $0.copy(position: GeoPoint(latitude: 36.0, longitude: 140.0)) }
        await controller.add(data: moved)

        XCTAssertEqual(renderer.changeBatchSizes, [500, 500, 250])
    }

    /// 空入力ではレンダラのバッチ呼び出しが起きない。
    func testEmptyInputProducesNoBatches() async {
        let (controller, renderer) = makeController()
        await controller.add(data: [])
        XCTAssertTrue(renderer.addBatchSizes.isEmpty)
        XCTAssertTrue(renderer.changeBatchSizes.isEmpty)
    }

    /// 削除は android-sdk と同じく 1 回の `onRemove` にまとめて渡される。
    func testRemoveIsDeliveredAsOneCall() async {
        let (controller, renderer) = makeController()
        await controller.add(data: states(600))
        await controller.add(data: [])
        XCTAssertEqual(renderer.removeBatchSizes, [600])
    }
}
