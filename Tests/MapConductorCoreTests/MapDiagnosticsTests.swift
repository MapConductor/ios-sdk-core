import XCTest

@testable import MapConductorCore

/// ``MapDiagnostics`` の意味論テスト。
///
/// android-sdk の `MapDiagnosticsTest` と 1 対 1 で対応する。
/// 元の ``MapUISettingsDiagnostics/warnIfRequested(_:gesture:provider:reason:)`` が
/// 持っていた 2 つの性質（要求されたときだけ / provider+capability ごとに 1 回だけ）を、
/// 一般化後も保っていることを押さえる。あわせて既存の warnIfRequested が同じ挙動の
/// ままであることも確認する（公開 API なので壊せない）。
final class MapDiagnosticsTests: XCTestCase {
    private static let recorded = MessageRecorder()

    /// `sink` はグローバルなので、記録先も 1 つに固定してテストごとに空にする。
    private final class MessageRecorder: @unchecked Sendable {
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

    func testReportLogsOnlyOnce() {
        XCTAssertTrue(
            MapDiagnostics.report(
                capability: .groundImage,
                level: .unsupported,
                provider: "Longdo",
                reason: "no ground overlay API"
            )
        )
        XCTAssertFalse(
            MapDiagnostics.report(
                capability: .groundImage,
                level: .unsupported,
                provider: "Longdo",
                reason: "no ground overlay API"
            )
        )
        XCTAssertEqual(messages.count, 1)
    }

    func testDifferentProvidersEachLog() {
        MapDiagnostics.report(capability: .groundImage, level: .unsupported, provider: "Longdo", reason: "x")
        MapDiagnostics.report(capability: .groundImage, level: .unsupported, provider: "MapTiler", reason: "y")
        XCTAssertEqual(messages.count, 2)
    }

    func testDifferentLevelsEachLog() {
        MapDiagnostics.report(capability: .polygonHoles, level: .degraded, provider: "HERE", reason: "union fill")
        MapDiagnostics.report(capability: .polygonHoles, level: .unsupported, provider: "HERE", reason: "union fill")
        XCTAssertEqual(messages.count, 2)
    }

    func testReportIfRequestedStaysQuietWhenNotRequested() {
        XCTAssertFalse(
            MapDiagnostics.reportIfRequested(
                false,
                capability: .markerDrag,
                level: .unsupported,
                provider: "Longdo",
                reason: "no drag"
            )
        )
        XCTAssertTrue(messages.isEmpty)
    }

    func testSubjectDefaultsToTheCapabilityId() {
        MapDiagnostics.report(capability: .markerDrag, level: .unsupported, provider: "Longdo", reason: "no drag")
        XCTAssertEqual(messages.first, "markerDrag is not supported by Longdo (no drag); the request is ignored.")
    }

    func testResetWarningsLetsItLogAgain() {
        MapDiagnostics.report(capability: .marker, level: .unsupported, provider: "P", reason: "r")
        MapDiagnostics.resetWarnings()
        MapDiagnostics.report(capability: .marker, level: .unsupported, provider: "P", reason: "r")
        XCTAssertEqual(messages.count, 2)
    }

    // ── 既存 API の非破壊 ───────────────────────────────────────────────

    func testWarnIfRequestedOnlyWarnsWhenDisablingIsAsked() {
        // true = ジェスチャを有効のままにしたい → 常に達成できるので警告不要。
        MapUISettingsDiagnostics.warnIfRequested(true, gesture: .rotate, provider: "MapTiler", reason: "single recogniser")
        XCTAssertTrue(messages.isEmpty)

        // false = 無効化したいができない → 警告する。
        MapUISettingsDiagnostics.warnIfRequested(false, gesture: .rotate, provider: "MapTiler", reason: "single recogniser")
        XCTAssertEqual(messages.count, 1)
    }

    func testWarnIfRequestedUsesTheSettingName() {
        MapUISettingsDiagnostics.warnIfRequested(false, gesture: .scroll, provider: "MapTiler", reason: "single recogniser")
        XCTAssertEqual(
            messages.first,
            "scrollGesture cannot be changed on MapTiler (single recogniser); the setting is ignored."
        )
    }

    func testWarnIfRequestedLogsOncePerProviderAndGesture() {
        for _ in 0 ..< 5 {
            MapUISettingsDiagnostics.warnIfRequested(false, gesture: .tilt, provider: "MapTiler", reason: "r")
        }
        MapUISettingsDiagnostics.warnIfRequested(false, gesture: .zoom, provider: "MapTiler", reason: "r")
        MapUISettingsDiagnostics.warnIfRequested(false, gesture: .tilt, provider: "Longdo", reason: "r")
        XCTAssertEqual(messages.count, 3)
    }

    func testEveryGestureMapsToACapability() {
        XCTAssertEqual(MapGesture.scroll.capability, .gestureScroll)
        XCTAssertEqual(MapGesture.zoom.capability, .gestureZoom)
        XCTAssertEqual(MapGesture.rotate.capability, .gestureRotate)
        XCTAssertEqual(MapGesture.tilt.capability, .gestureTilt)
    }
}
