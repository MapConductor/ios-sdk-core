import XCTest

@testable import MapConductorCore

/// `OverlayControllerRegistry` の性質テスト。
///
/// android-sdk の `BaseMapViewController` が担っている「登録済みオーバーレイへ
/// カメラ変更を伝播する」役割を iOS で受け持つ部品なので、
/// 登録・解除・伝播・破棄の 4 つを押さえる。
final class OverlayControllerRegistryTests: XCTestCase {

    /// カメラ変更を数えるだけのテスト用コントローラ。
    private final class SpyController: OverlayControllerProtocol {
        // Void を使うと `((Void) -> Void)?` の綴りが要求されて警告が出るので、
        // テストでは素直な具体型にしておく。
        typealias StateType = Int
        typealias EntityType = Int
        typealias EventType = Int

        let zIndex: Int
        var clickListener: ((Int) -> Void)?

        private(set) var receivedZooms: [Double] = []
        private(set) var destroyCount = 0

        init(zIndex: Int = 0) {
            self.zIndex = zIndex
        }

        func add(data: [Int]) async {}
        func update(state: Int) async {}
        func clear() async {}
        func find(position: GeoPointProtocol) -> Int? { nil }

        func onCameraChanged(mapCameraPosition: MapCameraPosition) async {
            receivedZooms.append(mapCameraPosition.zoom)
        }

        func destroy() { destroyCount += 1 }
    }

    private func camera(zoom: Double) -> MapCameraPosition {
        MapCameraPosition(position: GeoPoint(latitude: 35.68, longitude: 139.77), zoom: zoom)
    }

    /// 登録したコントローラにカメラ変更が届く。
    func testDispatchReachesRegisteredController() async throws {
        let registry = OverlayControllerRegistry()
        let spy = SpyController()
        registry.register(spy)

        registry.dispatchCameraChanged(camera(zoom: 12.0))

        try await waitUntil { spy.receivedZooms == [12.0] }
    }

    /// 解除したコントローラには届かない。
    func testUnregisterStopsDispatch() async throws {
        let registry = OverlayControllerRegistry()
        let spy = SpyController()
        registry.register(spy)
        registry.unregister(spy)

        registry.dispatchCameraChanged(camera(zoom: 12.0))

        // 届かないことの確認なので、少し待ってから空であることを見る。
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(spy.receivedZooms, [])
    }

    /// 同じインスタンスを 2 回登録しても配送は 1 回。
    func testDoubleRegistrationDeliversOnce() async throws {
        let registry = OverlayControllerRegistry()
        let spy = SpyController()
        registry.register(spy)
        registry.register(spy)

        registry.dispatchCameraChanged(camera(zoom: 9.0))

        try await waitUntil { spy.receivedZooms == [9.0] }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(spy.receivedZooms, [9.0], "2 回登録しても 2 回配送されてはいけない")
    }

    /// 複数のコントローラすべてに届く。拡張が 2 つ載っても互いを潰さないことの確認で、
    /// これがコントローラの単一スロットリスナーを直接使うのとの違い。
    func testDispatchReachesEveryController() async throws {
        let registry = OverlayControllerRegistry()
        let first = SpyController(zIndex: 0)
        let second = SpyController(zIndex: 10)
        registry.register(first)
        registry.register(second)

        registry.dispatchCameraChanged(camera(zoom: 15.5))

        try await waitUntil { first.receivedZooms == [15.5] && second.receivedZooms == [15.5] }
    }

    /// `all()` は zIndex の昇順。
    func testAllIsSortedByZIndex() {
        let registry = OverlayControllerRegistry()
        let high = SpyController(zIndex: 10)
        let low = SpyController(zIndex: 0)
        registry.register(high)
        registry.register(low)

        let sorted = registry.all()
        XCTAssertEqual(sorted.count, 2)
        XCTAssertTrue(sorted[0] === low)
        XCTAssertTrue(sorted[1] === high)
    }

    /// `destroyAll()` は全件を破棄して登録簿を空にする。
    func testDestroyAllEmptiesRegistry() {
        let registry = OverlayControllerRegistry()
        let spy = SpyController()
        registry.register(spy)

        registry.destroyAll()

        XCTAssertEqual(spy.destroyCount, 1)
        XCTAssertTrue(registry.all().isEmpty)
    }

    /// 配送は `Task` で投げるので、条件が満たされるまで短く待つ。
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("条件が \(timeout) 秒以内に満たされなかった")
    }
}
