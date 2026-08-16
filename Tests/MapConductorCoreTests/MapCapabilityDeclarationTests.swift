import XCTest

@testable import MapConductorCore

/// capability 宣言の意味論テスト。
///
/// android-sdk の `MapCapabilityDeclarationTest` と 1 対 1 で対応する。
/// 守りたい不変条件は 2 つ:
///  - **「未宣言」と「非対応」を混同しない。** 初期化途中のマップと、その SDK では
///    原理的にできないことを、呼び出し側が区別できること。
///  - **登録トークンで自分の登録だけを外せる。** キー名を列挙した撤収コードを
///    書かなくて済むこと（`removeProviderRegistrations()` が固定 2 キーを
///    ハードコードしていた形の解消）。
final class MapCapabilityDeclarationTests: XCTestCase {
    private enum PlainKey: MapServiceKey {
        typealias Value = String
    }

    private enum DragKey: MapServiceKey {
        typealias Value = String
        static var capability: MapCapability? { .markerDrag }
    }

    // ── 未宣言 vs 非対応 ────────────────────────────────────────────────

    func testUnknownIsNotUnsupported() {
        let registry = MutableMapServiceRegistry()
        let status = registry.capabilityStatus(.groundImage)

        XCTAssertEqual(status, .unknown)
        XCTAssertFalse(status.isKnownUnsupported, "未宣言を非対応と断定してはいけない")
        XCTAssertFalse(status.isUsable)
        XCTAssertNil(status.reason)
    }

    func testDeclareUnsupportedCarriesAReason() {
        let registry = MutableMapServiceRegistry()
        registry.declareUnsupported(
            .screenProjectionSync,
            "Longdo JS bridge has no synchronous unproject"
        )

        let status = registry.capabilityStatus(.screenProjectionSync)
        XCTAssertTrue(status.isKnownUnsupported)
        XCTAssertFalse(status.isUsable)
        XCTAssertEqual(status.reason, "Longdo JS bridge has no synchronous unproject")
    }

    func testDegradedAndApproximatedAreUsableButNotFull() {
        let registry = MutableMapServiceRegistry()
        registry.declare(.polygonHoles, .degraded("fill becomes a union"))
        registry.declare(.circle, .approximated("drawn as a polygon"))

        let holes = registry.capabilityStatus(.polygonHoles)
        XCTAssertTrue(holes.isUsable)
        XCTAssertFalse(holes.isFullySupported)
        XCTAssertFalse(holes.isKnownUnsupported)

        let circle = registry.capabilityStatus(.circle)
        XCTAssertTrue(circle.isUsable)
        XCTAssertFalse(circle.isFullySupported)
    }

    // ── put による自動宣言 ──────────────────────────────────────────────

    func testPuttingAKeyWithCapabilityDeclaresSupported() {
        let registry = MutableMapServiceRegistry()
        XCTAssertEqual(registry.capabilityStatus(.markerDrag), .unknown)

        registry.put(DragKey.self, "impl")

        XCTAssertEqual(registry.capabilityStatus(.markerDrag), .supported)
    }

    func testKeyWithoutCapabilityDeclaresNothing() {
        let registry = MutableMapServiceRegistry()
        registry.put(PlainKey.self, "impl")

        XCTAssertTrue(registry.has(PlainKey.self))
        XCTAssertTrue(registry.declaredCapabilities().isEmpty)
    }

    func testHasReportsRegistration() {
        let registry = MutableMapServiceRegistry()
        XCTAssertFalse(registry.has(PlainKey.self))
        registry.put(PlainKey.self, "impl")
        XCTAssertTrue(registry.has(PlainKey.self))
    }

    // ── 登録トークン ────────────────────────────────────────────────────

    func testDisposeRemovesOnlyItsOwnRegistration() {
        let registry = MutableMapServiceRegistry()
        let plain = registry.register(PlainKey.self, "plain")
        registry.put(DragKey.self, "drag")

        plain.dispose()

        XCTAssertNil(registry.get(PlainKey.self))
        XCTAssertEqual(registry.get(DragKey.self), "drag")
        XCTAssertEqual(registry.capabilityStatus(.markerDrag), .supported)
    }

    func testDisposeAlsoRollsBackTheCapabilityDeclaration() {
        let registry = MutableMapServiceRegistry()
        let registration = registry.register(DragKey.self, "drag")
        XCTAssertEqual(registry.capabilityStatus(.markerDrag), .supported)

        registration.dispose()

        XCTAssertEqual(registry.capabilityStatus(.markerDrag), .unknown)
    }

    func testDisposeAfterOverwriteKeepsTheNewValue() {
        let registry = MutableMapServiceRegistry()
        let first = registry.register(PlainKey.self, "first")
        registry.put(PlainKey.self, "second")

        first.dispose()

        XCTAssertEqual(registry.get(PlainKey.self), "second", "上書き後の値まで消してはいけない")
    }

    func testDisposeRestoresThePreviousDeclaration() {
        let registry = MutableMapServiceRegistry()
        registry.declare(.cameraTilt, .supported)
        let second = registry.declare(.cameraTilt, .degraded("emulated"))

        second.dispose()

        XCTAssertEqual(registry.capabilityStatus(.cameraTilt), .supported)
    }

    func testRegistrationsDisposeAll() {
        let registry = MutableMapServiceRegistry()
        let registrations = MapServiceRegistrations()
        registrations.add(registry.register(PlainKey.self, "plain"))
        registrations.add(registry.register(DragKey.self, "drag"))
        registrations.add(registry.declareUnsupported(.groundImage, "no API"))

        registrations.disposeAll()

        XCTAssertNil(registry.get(PlainKey.self))
        XCTAssertNil(registry.get(DragKey.self))
        XCTAssertEqual(registry.capabilityStatus(.markerDrag), .unknown)
        XCTAssertEqual(registry.capabilityStatus(.groundImage), .unknown)
    }

    func testDisposeAllTwiceIsSafe() {
        let registry = MutableMapServiceRegistry()
        let registrations = MapServiceRegistrations()
        registrations.add(registry.register(PlainKey.self, "plain"))

        registrations.disposeAll()
        registrations.disposeAll()

        XCTAssertNil(registry.get(PlainKey.self))
    }

    // ── 既存 API との共存 ───────────────────────────────────────────────

    func testRemoveAlsoWithdrawsTheDeclaration() {
        let registry = MutableMapServiceRegistry()
        registry.put(DragKey.self, "drag")

        registry.remove(DragKey.self)

        XCTAssertNil(registry.get(DragKey.self))
        XCTAssertEqual(registry.capabilityStatus(.markerDrag), .unknown)
    }

    func testClearAlsoClearsDeclarations() {
        let registry = MutableMapServiceRegistry()
        registry.put(DragKey.self, "drag")
        registry.declareUnsupported(.groundImage, "no API")

        registry.clear()

        XCTAssertEqual(registry.capabilityStatus(.markerDrag), .unknown)
        XCTAssertEqual(registry.capabilityStatus(.groundImage), .unknown)
    }

    func testEmptyRegistryIsAlwaysUnknown() {
        XCTAssertEqual(EmptyMapServiceRegistry.shared.capabilityStatus(.marker), .unknown)
        XCTAssertFalse(EmptyMapServiceRegistry.shared.has(PlainKey.self))
    }

    func testCapabilityIdsAreUniqueAndResolvable() {
        let ids = MapCapability.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "id が重複している")
        for capability in MapCapability.allCases {
            XCTAssertEqual(MapCapability.fromId(capability.id), capability)
        }
        XCTAssertNil(MapCapability.fromId("nope"))
    }
}
