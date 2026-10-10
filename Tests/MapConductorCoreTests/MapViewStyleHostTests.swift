import XCTest

@testable import MapConductorCore

/**
 The decision table of ``MapViewStyleHost/apply(_:onDiagnostics:)``.

 The only part of this class that carries a decision is when to install
 again and when to leave things alone; the rest is handing things through to
 a provider. And that condition was once inverted, unnoticed: **the same key
 called `update`** (recompile → diagnostics → state → another `body` →
 round again, which the user saw as the bottom-left panel flickering), and
 **a changed key never called `update`** (dispose and install every time,
 which is the reload the whole delta-compiling design exists to avoid).
 Both are the kind of break that compiles and still draws a map, so the
 table is written down here.

 Kept in step with android-sdk's `MapViewStyleHostTest` and js-sdk-core's
 `MapViewStyleHost.test.mjs`.
 */
final class MapViewStyleHostTests: XCTestCase {
    /// Records what it was asked to do, and nothing else.
    private struct RecordingStyle: MapViewStyle {
        let key: String
        let calls: Calls
        /// Whether `update` takes it. False means the caller disposes and
        /// installs from scratch. A closure so the answer can change after
        /// the style is installed (see `testAnAcceptedUpdateResetsTheRun`).
        let takesUpdates: () -> Bool

        func install(host: MapStyleHost) -> MapStyleInstallation {
            calls.record("install(\(key))")
            let key = key
            let calls = calls
            let takesUpdates = takesUpdates
            return MapStyleInstallation(
                dispose: { calls.record("dispose(\(key))") },
                update: { next in
                    calls.record("update(\(key) -> \(next.key))")
                    return takesUpdates()
                }
            )
        }
    }

    /// A reference box, because `MapViewStyle` is a value and the closures
    /// it hands out are captured.
    private final class Calls {
        private(set) var recorded: [String] = []
        func record(_ call: String) { recorded.append(call) }
        func clear() { recorded = [] }
    }

    private var calls = Calls()

    override func setUp() {
        super.setUp()
        calls = Calls()
    }

    private func host() -> MapViewStyleHost {
        MapViewStyleHost(serviceRegistry: MutableMapServiceRegistry())
    }

    private func style(_ key: String, takesUpdates: Bool = true) -> RecordingStyle {
        RecordingStyle(key: key, calls: calls, takesUpdates: { takesUpdates })
    }

    private func style(_ key: String, takesUpdates: @escaping () -> Bool) -> RecordingStyle {
        RecordingStyle(key: key, calls: calls, takesUpdates: takesUpdates)
    }

    func testTheFirstApplyInstalls() {
        // Held in a `let`: the host disposes what it installed when it goes,
        // so a temporary would install and immediately take it back off.
        let host = host()
        host.apply(style("a"))
        XCTAssertEqual(calls.recorded, ["install(a)"])
    }

    /**
     An unchanged key does nothing. Inverted, this was the flicker: the
     recompile is not merely wasted work, it re-reports the diagnostics, and
     an app that renders them sets state and asks for another `body`.
     */
    func testAnUnchangedKeyDoesNothing() {
        let host = host()
        host.apply(style("a"))
        calls.clear()

        // Different values, same content -- which is what a style built
        // inline in a `body` produces on every evaluation.
        host.apply(style("a"))
        host.apply(style("a"))

        XCTAssertEqual(calls.recorded, [])
    }

    /**
     A changed key is offered to what is installed before anything is torn
     down. A slider that does not reload the map is this one line.
     */
    func testAChangedKeyIsOfferedBeforeBeingReinstalled() {
        let host = host()
        host.apply(style("a"))
        calls.clear()

        host.apply(style("b"))

        XCTAssertEqual(calls.recorded, ["update(a -> b)"])
    }

    /// Once an update is taken, the new key is what "unchanged" means.
    func testAnAcceptedKeyBecomesTheInstalledOne() {
        let host = host()
        host.apply(style("a"))
        host.apply(style("b"))
        calls.clear()

        host.apply(style("b"))

        XCTAssertEqual(calls.recorded, [])
    }

    func testARefusedUpdateDisposesAndInstalls() {
        let host = host()
        host.apply(style("a", takesUpdates: false))
        calls.clear()

        host.apply(style("b", takesUpdates: false))

        XCTAssertEqual(calls.recorded, ["update(a -> b)", "dispose(a)", "install(b)"])
    }

    /**
     A style with no `update` of its own takes the protocol's default,
     which is "refused". If that ever read as "took it", a new key would be
     recorded against an installation that never saw it.
     */
    func testAStyleThatCannotUpdateIsReinstalled() {
        struct Plain: MapViewStyle {
            let key: String
            let calls: Calls

            func install(host: MapStyleHost) -> MapStyleInstallation {
                calls.record("install(\(key))")
                let key = key
                let calls = calls
                return MapStyleInstallation(dispose: { calls.record("dispose(\(key))") })
            }
        }
        let host = host()
        host.apply(Plain(key: "a", calls: calls))
        calls.clear()

        host.apply(Plain(key: "b", calls: calls))

        XCTAssertEqual(calls.recorded, ["dispose(a)", "install(b)"])
    }

    /// Nil takes it off: the app gets the map it had, not the one the style
    /// left behind.
    func testNilTakesItOff() {
        let host = host()
        host.apply(style("a"))
        calls.clear()

        host.apply(nil)
        XCTAssertEqual(calls.recorded, ["dispose(a)"])

        // And the same key afterwards installs rather than being left alone.
        calls.clear()
        host.apply(style("a"))
        XCTAssertEqual(calls.recorded, ["install(a)"])
    }

    /**
     Only a *run* of refusals is a problem, so one that is taken starts the
     count over.

     The diagnostic itself is not asserted here: ``MCLog`` writes to
     `os_log` with no seam to read it back, unlike android-sdk's
     `MapDiagnostics.sink`. What is checked is that the run is counted the
     way the threshold assumes -- consecutively.
     */
    func testAnAcceptedUpdateResetsTheRun() {
        let host = host()
        var takes = false
        host.apply(style("k0", takesUpdates: { takes }))
        for index in 0..<4 { host.apply(style("r\(index)", takesUpdates: { takes })) }
        calls.clear()

        takes = true
        host.apply(style("ok", takesUpdates: { takes }))

        // Taken in place: nothing torn down, nothing installed again.
        XCTAssertEqual(calls.recorded, ["update(r3 -> ok)"])
    }
}
