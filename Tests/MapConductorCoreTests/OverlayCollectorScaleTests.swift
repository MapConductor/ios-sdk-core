import Combine
import XCTest

@testable import MapConductorCore

/// What one subscription per state costs when there are a lot of states.
///
/// android-sdk had the opposite problem: it watched every state through a
/// single snapshot observer, which cost the size of the collection on every
/// commit and made a drag with 144k markers stall for 350 ms a frame. iOS and
/// the web SDK already push — each state publishes its own changes — so that
/// cost does not exist here. What does exist is the setup: `asFlow()` builds a
/// CombineLatest of a CombineLatest4 per marker, and the collector wraps each
/// in `receive(on:)` and a sink.
///
/// Tokyo's street trees are 144,183 markers. This measures the shape of the
/// curve rather than asserting a number, because a number would be about the
/// machine; the test fails only if it does not finish.
@MainActor
final class OverlayCollectorScaleTests: XCTestCase {

    private func markers(_ count: Int) -> [MarkerState] {
        (0..<count).map { index in
            MarkerState(
                position: GeoPoint(
                    latitude: 35.6 + Double(index % 500) * 0.0005,
                    longitude: 139.7 + Double(index / 500) * 0.0005
                ),
                id: String(index)
            )
        }
    }

    func testSyncCostAgainstStateCount() {
        for count in [1_000, 10_000, 50_000, 144_183] {
            let states = markers(count)
            let collector = OverlayCollector<MarkerState>()
            var membership = 0
            collector.onMembershipChange { _ in membership += 1 }
            collector.onStateChange { _ in }

            let started = Date()
            collector.sync(states)
            let elapsed = Date().timeIntervalSince(started)

            print(String(format: "IOSCOLLECTOR n=%d sync=%.0fms", count, elapsed * 1000))
            XCTAssertEqual(collector.values().count, count)
            collector.clear()
        }
    }

    /// SwiftUI re-evaluates the map's content on every camera frame and hands the
    /// collector the same list again. That must not cost the size of the list in
    /// sets and listeners (it was 260 ms a frame for Boston's 98,843 parcels on an
    /// iPad Pro, and every pan ran at 5 fps), and must not count as a change.
    func testResyncingTheSameListIsFreeAndChangesNothing() async {
        let states = (0..<100_000).map { i in
            PolygonState(
                points: [
                    GeoPoint(latitude: 42.3, longitude: -71.1 + Double(i) * 1e-5),
                    GeoPoint(latitude: 42.3, longitude: -71.1 + Double(i) * 1e-5 + 5e-6),
                    GeoPoint(latitude: 42.3001, longitude: -71.1 + Double(i) * 1e-5),
                ],
                id: "p\(i)"
            )
        }
        let collector = OverlayCollector<PolygonState>()
        var memberships = 0
        var updates: [String] = []
        collector.onMembershipChange { _ in memberships += 1 }
        collector.onStateChange { updates.append($0.id) }
        let first = Date()
        collector.sync(states)
        let firstSync = Date().timeIntervalSince(first)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(memberships, 1)

        let started = Date()
        for _ in 0..<10 { collector.sync(Array(states)) }
        let perSync = Date().timeIntervalSince(started) / 10
        print(String(format: "IOSCOLLECTOR n=100000 first=%.1fms resync=%.1fms", firstSync * 1000, perSync * 1000))
        // A pointer comparison per state, not a diff (the test build is unoptimised,
        // so this is a ratio rather than a number of milliseconds).
        XCTAssertLessThan(perSync, firstSync / 4)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(memberships, 1, "同じ一覧は membership の変化ではない")

        // 変更の通知はこれまでどおり届く。
        states[7].fillColor = .red
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(updates, ["p7"])

        // 1 件差し替えた一覧は、同じ長さでも変化として扱う。
        var replaced = states
        replaced[3] = PolygonState(points: states[3].points, id: "p3")
        collector.sync(replaced)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(memberships, 2)
    }

    /// The per-state publisher on its own, with the collector out of the way.
    func testPublisherSetupCost() {
        for count in [1_000, 10_000, 50_000] {
            let states = markers(count)
            var bag: [AnyCancellable] = []
            bag.reserveCapacity(count)

            let started = Date()
            for state in states {
                bag.append(state.asFlow().sink { _ in })
            }
            let elapsed = Date().timeIntervalSince(started)

            print(String(format: "IOSPUBLISHER n=%d subscribe=%.0fms", count, elapsed * 1000))
            XCTAssertEqual(bag.count, count)
        }
    }
}
