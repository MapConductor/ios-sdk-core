import Combine
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// `MarkerState.onChange`: what a marker controller hears a marker's writes by,
/// in place of a subscription to `asFlow()`.
///
/// - 書き込みのあと、メインキューで呼ぶ。購読した時点では呼ばない。
/// - トークンを cancel するか手放したら呼ばない。
/// - 聞き手は 1 つ。新しい聞き手が来たら古いほうには来ず、古いトークンを cancel
///   しても新しい聞き手は残る（プロバイダ切り替えで古い地図が後から片付く）。
@MainActor
final class MarkerChangeListenerTests: XCTestCase {
    private func marker() -> MarkerState {
        MarkerState(position: GeoPoint(latitude: 35.68, longitude: 139.76), id: "m")
    }

    private func drain() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testAWriteIsHeardOnTheMainQueueAndListeningAloneCallsNothing() {
        let state = marker()
        var calls = 0
        let token = state.onChange { calls += 1 }
        drain()
        XCTAssertEqual(calls, 0)
        state.position = GeoPoint(latitude: 35.69, longitude: 139.77)
        XCTAssertEqual(calls, 0, "not during the write")
        drain()
        XCTAssertEqual(calls, 1)
        state.icon = DefaultMarkerIcon()
        state.zIndex = 3
        drain()
        XCTAssertEqual(calls, 3)
        token.cancel()
    }

    func testACancelledOrReleasedTokenHearsNothing() {
        let state = marker()
        var calls = 0
        let token = state.onChange { calls += 1 }
        token.cancel()
        state.clickable = false
        drain()
        XCTAssertEqual(calls, 0)

        var released: AnyCancellable? = state.onChange { calls += 1 }
        XCTAssertNotNil(released)
        released = nil
        state.draggable = true
        drain()
        XCTAssertEqual(calls, 0)
    }

    /// A provider switch: the new map listens first, then the old one is taken down.
    func testCancellingAReplacedListenerLeavesTheNewOne() {
        let state = marker()
        var old = 0, new = 0
        let oldToken = state.onChange { old += 1 }
        let newToken = state.onChange { new += 1 }
        oldToken.cancel()
        state.position = GeoPoint(latitude: 35.7, longitude: 139.78)
        drain()
        XCTAssertEqual(old, 0)
        XCTAssertEqual(new, 1)
        newToken.cancel()
    }
}
