import XCTest

@testable import MapConductorCore

/// ``ScreenProjectionRequirement`` の意味論テスト。
///
/// android-sdk の `ScreenProjectionRequirementTest` と 1 対 1 で対応する。
///
/// 守りたい不変条件は 1 つ:
/// **未宣言（``MapCapabilityStatus/unknown``）を非対応と断定しない。**
///
/// 宣言が無いのは「まだ宣言していない」か「地図の初期化途中」であって
/// 「使えない」ではない。ここで誤って機能を落とすと、宣言をまだ書いていない
/// プロバイダで InfoBubble やマーカーアニメーションが動かなくなる。
final class ScreenProjectionRequirementTests: XCTestCase {
    private static let recorded = Recorder()

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func append(_ message: String) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        func drain() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }

        func reset() {
            lock.lock()
            messages.removeAll()
            lock.unlock()
        }
    }

    private var messages: [String] { Self.recorded.drain() }

    override func setUp() {
        super.setUp()
        Self.recorded.reset()
        MapDiagnostics.sink = { Self.recorded.append($0) }
        MapDiagnostics.resetWarnings()
    }

    override func tearDown() {
        MapDiagnostics.sink = { print("MapConductor: \($0)") }
        MapDiagnostics.resetWarnings()
        super.tearDown()
    }

    func testUndeclaredIsLetThrough() {
        let registry = MutableMapServiceRegistry()
        XCTAssertTrue(ScreenProjectionRequirement.check(registry: registry, provider: "Whatever", feature: "InfoBubble"))
        XCTAssertTrue(messages.isEmpty, "未宣言で警告を出してはいけない")
    }

    func testSupportedIsLetThrough() {
        let registry = MutableMapServiceRegistry()
        registry.declare(.screenProjectionSync, .supported)
        XCTAssertTrue(ScreenProjectionRequirement.check(registry: registry, provider: "MapLibre", feature: "InfoBubble"))
        XCTAssertTrue(messages.isEmpty)
    }

    func testUnsupportedIsDroppedWithAReason() throws {
        let registry = MutableMapServiceRegistry()
        registry.declareUnsupported(
            .screenProjectionSync,
            "Longdo runs on a WebView bridge with no synchronous project/unproject"
        )

        XCTAssertFalse(ScreenProjectionRequirement.check(registry: registry, provider: "Longdo", feature: "InfoBubble"))

        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(message.hasPrefix("InfoBubble"), "何が動かないのかを出す")
        XCTAssertTrue(message.contains("WebView bridge"), "理由を出す")
        XCTAssertTrue(message.contains("Longdo"), "どのプロバイダかを出す")
    }

    func testItReportsOnlyOnce() {
        let registry = MutableMapServiceRegistry()
        registry.declareUnsupported(.screenProjectionSync, "no sync")
        for _ in 0 ..< 100 {
            _ = ScreenProjectionRequirement.check(registry: registry, provider: "Longdo", feature: "InfoBubble")
        }
        XCTAssertEqual(messages.count, 1)
    }

    func testDegradedAndApproximatedAreNotDropped() {
        // 「使えるが完全ではない」は動かす。落とすのは unsupported のときだけ。
        for status in [MapCapabilityStatus.degraded("partially"), .approximated("rounded")] {
            MapDiagnostics.resetWarnings()
            Self.recorded.reset()
            let registry = MutableMapServiceRegistry()
            registry.declare(.screenProjectionSync, status)
            XCTAssertTrue(
                ScreenProjectionRequirement.check(registry: registry, provider: "P", feature: "InfoBubble"),
                "\(status) で落としてはいけない"
            )
            XCTAssertTrue(messages.isEmpty)
        }
    }
}
