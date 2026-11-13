import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// `Markers` / `Circles` / `Polylines` / `Polygons` の onAddStart / onAddProgress / onAddEnd
/// （AddProgressTracker / AddProgressHost）。js-sdk-react の `addProgress.test.mjs`、
/// android-sdk-compose の `AddProgressTrackerTest` と同じ内容に、iOS だけの事情を足す:
///
/// - content は描き直しのたびに作り直される。同じ配列なら何もしない。
/// - コレクションは書かれた場所で見分ける。content から消えたら数え直し。
/// - コールバックはビューの更新中には呼ばない（start と end はその直後）。
@MainActor
final class AddProgressTests: XCTestCase {
    private var calls: [String] = []
    private var clock: TimeInterval = 1000

    private func circle(_ id: String) -> CircleState {
        CircleState(center: GeoPoint(latitude: 42.35, longitude: -71.06), radiusMeters: 5, id: id)
    }

    private var callbacks: AddProgressCallbacks {
        AddProgressCallbacks(
            onAddStart: { [weak self] in self?.calls.append("start \($0)") },
            onAddProgress: { [weak self] in self?.calls.append("progress \($0)/\($1)") },
            onAddEnd: { [weak self] in self?.calls.append("end \($0)") }
        )
    }

    private func request(_ states: [CircleState], line: UInt = 1) -> AddProgressRequest {
        AddProgressRequest(kind: "circles", states: states, callbacks: callbacks, fileID: "Test.swift", line: line, column: 1)
    }

    private func tracker() -> AddProgressTracker {
        AddProgressTracker(now: { [unowned self] in self.clock })
    }

    /// Lets the calls deferred out of the view update run.
    private func drain(_ seconds: TimeInterval = 0) {
        let done = expectation(description: "main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    private func drainAsync() async {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
    }

    func testAllOnTheMapStartProgressEnd() {
        let tracker = tracker()
        let states = [circle("a"), circle("b"), circle("c")]
        tracker.sync(request(states))
        XCTAssertEqual(calls, [], "nothing during the view update")
        drain()
        XCTAssertEqual(calls, ["start 3"])
        tracker.arrived([states[0]])
        tracker.arrived([states[1], states[2]])
        XCTAssertEqual(calls, ["start 3", "progress 1/3", "progress 3/3", "end 3"])
    }

    func testAnArrivalAheadOfTheDeferredStartStillStartsFirst() {
        let tracker = tracker()
        let states = [circle("a")]
        tracker.sync(request(states))
        tracker.arrived(states)
        drain()
        XCTAssertEqual(calls, ["start 1", "progress 1/1", "end 1"])
    }

    func testProgressAtMostEvery100ms() {
        let tracker = tracker()
        let states = (0..<5).map { circle("s\($0)") }
        tracker.sync(request(states))
        drain()
        tracker.arrived([states[0]])
        clock += 0.01
        tracker.arrived([states[1]])
        tracker.arrived([states[2]])
        XCTAssertEqual(calls, ["start 5", "progress 1/5"])
        clock += 0.1
        drain(0.15)
        XCTAssertEqual(calls, ["start 5", "progress 1/5", "progress 3/5"])
        tracker.arrived([states[3], states[4]])
        XCTAssertEqual(calls.last, "end 5")
    }

    func testTheSameArrayAgainDoesNothing() {
        let tracker = tracker()
        let states = [circle("a"), circle("b")]
        tracker.sync(request(states))
        drain()
        tracker.arrived(states)
        calls.removeAll()
        for _ in 0..<3 { tracker.sync(request(states)) }
        drain()
        XCTAssertEqual(calls, [])
    }

    func testAStateRemovedBeforeItArrivedNoLongerCounts() {
        let tracker = tracker()
        let (a, b, c) = (circle("a"), circle("b"), circle("c"))
        tracker.sync(request([a, b, c]))
        drain()
        tracker.arrived([a])
        tracker.sync(request([a, b]))
        tracker.arrived([b])
        XCTAssertEqual(Array(calls.suffix(2)), ["progress 2/2", "end 2"])
    }

    func testRemovingTheRestEndsRightAfter() {
        let tracker = tracker()
        let (a, b) = (circle("a"), circle("b"))
        tracker.sync(request([a, b]))
        drain()
        tracker.arrived([a])
        tracker.sync(request([a]))
        drain()
        XCTAssertEqual(Array(calls.suffix(2)), ["progress 1/1", "end 1"])
    }

    func testAStillComingStateHandedOverAsANewObjectIsCountedByTheNewOne() {
        let tracker = tracker()
        tracker.sync(request([circle("a")]))
        let a2 = circle("a")
        tracker.sync(request([a2]))
        tracker.arrived([a2])
        drain()
        XCTAssertEqual(calls, ["start 1", "progress 1/1", "end 1"])
    }

    func testNewStatesWhileOthersAreComingStartOverWithoutAnEnd() {
        let tracker = tracker()
        let (a, b, c) = (circle("a"), circle("b"), circle("c"))
        tracker.sync(request([a, b]))
        drain()
        tracker.sync(request([a, b, c]))
        drain()
        XCTAssertEqual(calls, ["start 2", "start 1"])
        tracker.arrived([a, b])
        tracker.arrived([c])
        XCTAssertEqual(calls, ["start 2", "start 1", "progress 1/1", "end 1"])
    }

    func testUpdatesRemovalsAndOtherStatesCallNothing() {
        let tracker = tracker()
        let (a, b) = (circle("a"), circle("b"))
        tracker.sync(request([a, b]))
        drain()
        tracker.arrived([a, b])
        calls.removeAll()
        tracker.sync(request([circle("a")]))
        tracker.arrived([circle("other"), circle("a")])
        drain()
        XCTAssertEqual(calls, [])
    }

    /// The host: one tracker per place in the content; arrivals come through the listener.
    func testHostHearsArrivalsAndStartsOverWhenACollectionComesBack() async {
        let host = AddProgressHost()
        let states = [circle("a"), circle("b")]
        host.sync([request(states, line: 10)])
        await drainAsync()
        await OverlayAddedTracker.notify(states)
        XCTAssertEqual(calls, ["start 2", "progress 2/2", "end 2"])

        calls.removeAll()
        host.sync([]) // the collection left the content
        host.sync([request(states, line: 10)]) // and came back with the same array
        await drainAsync()
        XCTAssertEqual(calls, ["start 2"])

        host.sync([])
        XCTAssertFalse(OverlayAddedListeners.isActive, "no collection, no listener")
    }

    func testCollectionsWithoutCallbacksAddNoRequest() {
        var content = MapViewContent()
        Circles([circle("a")]).append(to: &content)
        XCTAssertTrue(content.addProgressRequests.isEmpty)
        Circles([circle("a")], onAddEnd: { _ in }).append(to: &content)
        XCTAssertEqual(content.addProgressRequests.count, 1)
    }
}
