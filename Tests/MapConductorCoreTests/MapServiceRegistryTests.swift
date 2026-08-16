import XCTest

@testable import MapConductorCore

/// ``MutableMapServiceRegistry`` の意味論テスト。
///
/// android-sdk の `MapServiceRegistryTest` と 1 対 1 で対応する。
/// 特に ``MutableMapServiceRegistry/remove(_:)`` は「他の capability を残したまま
/// 1件だけ取り下げる」点が ``MutableMapServiceRegistry/clear()`` との違いなので、
/// そこを明示的に押さえる。
final class MapServiceRegistryTests: XCTestCase {
    private enum KeyA: MapServiceKey {
        typealias Value = String
    }

    private enum KeyB: MapServiceKey {
        typealias Value = String
    }

    func testGetReturnsWhatWasPut() {
        let registry = MutableMapServiceRegistry()
        registry.put(KeyA.self, "a")
        XCTAssertEqual(registry.get(KeyA.self), "a")
    }

    func testUnregisteredKeyIsNil() {
        let registry = MutableMapServiceRegistry()
        XCTAssertNil(registry.get(KeyA.self))
    }

    func testPutOverwritesTheSameKey() {
        let registry = MutableMapServiceRegistry()
        registry.put(KeyA.self, "first")
        registry.put(KeyA.self, "second")
        XCTAssertEqual(registry.get(KeyA.self), "second")
    }

    func testRemoveOnlyWithdrawsTheGivenKey() {
        let registry = MutableMapServiceRegistry()
        registry.put(KeyA.self, "a")
        registry.put(KeyB.self, "b")

        registry.remove(KeyA.self)

        XCTAssertNil(registry.get(KeyA.self))
        XCTAssertEqual(registry.get(KeyB.self), "b", "remove は他のキーに影響しないこと")
    }

    func testRemovingAnUnregisteredKeyDoesNothing() {
        let registry = MutableMapServiceRegistry()
        registry.put(KeyB.self, "b")

        registry.remove(KeyA.self)

        XCTAssertEqual(registry.get(KeyB.self), "b")
    }

    func testClearWithdrawsEverything() {
        let registry = MutableMapServiceRegistry()
        registry.put(KeyA.self, "a")
        registry.put(KeyB.self, "b")

        registry.clear()

        XCTAssertNil(registry.get(KeyA.self))
        XCTAssertNil(registry.get(KeyB.self))
    }

    func testEmptyRegistryAlwaysReturnsNil() {
        XCTAssertNil(EmptyMapServiceRegistry.shared.get(KeyA.self))
    }
}
