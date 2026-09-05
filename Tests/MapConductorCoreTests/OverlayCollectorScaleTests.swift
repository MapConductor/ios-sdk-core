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
