import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// `Markers` / `Circles` / `Polylines` / `Polygons` の onAddStart / onAddProgress / onAddEnd
/// （AddProgressTracker / AddProgressHost）。js-sdk-react の `addProgress.test.mjs`、
/// android-sdk-compose の `AddProgressTrackerTest` と同じ内容に、iOS だけの事情を足す:
///
/// - リストを渡したら onAddStart(total)。total は地図に未だ無い state の数（削除・更新だけなら 0、空のあとの空は何も呼ばない）。
/// - 全部載り、タイルの描画も止まって静かになったら onAddProgress(total, total) と onAddEnd(total)。
/// - タイルの描画だけ（カメラの移動）は一定時間続いたら onAddStart(0)。それより短ければ何も呼ばない。
/// - content は描き直しのたびに作り直される。同じ配列なら何もしない。
/// - コレクションは書かれた場所で見分ける。content から消えたら数え直し。
/// - コールバックはビューの更新中には呼ばない（start はその直後）。
///
/// 待ち時間は本番（静か 0.4 秒・描画だけ 0.2 秒）を短くして、本物のメインキューで待つ。
@MainActor
final class AddProgressTests: XCTestCase {
    private var calls: [String] = []
    private var clock: TimeInterval = 1000
    private let settle: TimeInterval = 0.05
    private let drawStart: TimeInterval = 0.03

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
        AddProgressTracker(now: { [unowned self] in self.clock }, settleDelay: settle, drawStartDelay: drawStart)
    }

    /// Lets the calls deferred out of the view update, and the timers, run.
    private func drain(_ seconds: TimeInterval = 0) {
        let done = expectation(description: "main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    /// Long enough for the quiet stretch before an end.
    private func settleDown() { drain(settle * 3) }

    private func drainAsync(_ seconds: TimeInterval = 0) async {
        let done = expectation(description: "main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        await fulfillment(of: [done], timeout: seconds + 2)
    }

    func testAllOnTheMapStartProgressEndOnceQuiet() {
        let tracker = tracker()
        let states = [circle("a"), circle("b"), circle("c")]
        tracker.sync(request(states))
        XCTAssertEqual(calls, [], "nothing during the view update")
        drain()
        XCTAssertEqual(calls, ["start 3"])
        tracker.arrived([states[0]])
        tracker.arrived([states[1], states[2]])
        XCTAssertEqual(calls, ["start 3", "progress 1/3"])
        settleDown()
        XCTAssertEqual(calls, ["start 3", "progress 1/3", "progress 3/3", "end 3"])
    }

    func testAnArrivalAheadOfTheDeferredStartStillStartsFirst() {
        let tracker = tracker()
        let states = [circle("a")]
        tracker.sync(request(states))
        tracker.arrived(states)
        settleDown()
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
        settleDown()
        XCTAssertEqual(calls.last, "end 5")
    }

    func testTheSameArrayAgainDoesNothing() {
        let tracker = tracker()
        let states = [circle("a"), circle("b")]
        tracker.sync(request(states))
        drain()
        tracker.arrived(states)
        settleDown()
        calls.removeAll()
        for _ in 0..<3 { tracker.sync(request(states)) }
        settleDown()
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
        settleDown()
        XCTAssertEqual(Array(calls.suffix(2)), ["progress 2/2", "end 2"])
    }

    func testRemovingTheRestEndsOnceQuiet() {
        let tracker = tracker()
        let (a, b) = (circle("a"), circle("b"))
        tracker.sync(request([a, b]))
        drain()
        tracker.arrived([a])
        tracker.sync(request([a]))
        settleDown()
        XCTAssertEqual(Array(calls.suffix(2)), ["progress 1/1", "end 1"])
    }

    func testAStillComingStateHandedOverAsANewObjectIsCountedByTheNewOne() {
        let tracker = tracker()
        tracker.sync(request([circle("a")]))
        let a2 = circle("a")
        tracker.sync(request([a2]))
        tracker.arrived([a2])
        settleDown()
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
        settleDown()
        XCTAssertEqual(calls, ["start 2", "start 1", "progress 1/1", "end 1"])
    }

    func testUpdatesAndRemovalsStartAndEndWithZeroAndOtherStatesDoNotCount() {
        let tracker = tracker()
        let (a, b) = (circle("a"), circle("b"))
        tracker.sync(request([a, b]))
        drain()
        tracker.arrived([a, b])
        settleDown()
        calls.removeAll()
        tracker.sync(request([circle("a")]))
        tracker.arrived([circle("other"), circle("a")])
        drain()
        XCTAssertEqual(calls, ["start 0"])
        settleDown()
        XCTAssertEqual(calls, ["start 0", "end 0"])
    }

    func testAnEmptyListAfterNothingCallsNothing() {
        let tracker = tracker()
        tracker.sync(request([]))
        settleDown()
        XCTAssertEqual(calls, [])
    }

    func testDrawingKeepsTheEndWaitingUntilItHasBeenQuiet() {
        let tracker = tracker()
        let a = circle("a")
        tracker.sync(request([a]))
        tracker.arrived([a])
        tracker.drawingChanged(true)
        drain(settle * 4)
        XCTAssertEqual(calls, ["start 1"])
        tracker.drawingChanged(false)
        settleDown()
        XCTAssertEqual(calls, ["start 1", "progress 1/1", "end 1"])
    }

    func testDrawingAloneStartsAfterTheDelayAndEndsOnceQuiet() {
        let tracker = tracker()
        tracker.sync(request([])) // a collection with nothing in it yet
        tracker.drawingChanged(true)
        drain(drawStart * 3)
        XCTAssertEqual(calls, ["start 0"])
        tracker.drawingChanged(false)
        settleDown()
        XCTAssertEqual(calls, ["start 0", "end 0"])
    }

    func testBriefDrawingCallsNothing() {
        let tracker = tracker()
        tracker.sync(request([])) // a collection with nothing in it yet
        tracker.drawingChanged(true)
        tracker.drawingChanged(false)
        drain(drawStart * 3)
        settleDown()
        XCTAssertEqual(calls, [])
    }

    /// The tracker follows the tilers it is handed with the list.
    func testATilerDrawingIsFollowed() {
        let tracker = tracker()
        let activity = TileActivity()
        var request = request([])
        request.activity = [activity]
        tracker.sync(request)
        activity.begin()
        drain(drawStart * 3)
        XCTAssertEqual(calls, ["start 0"])
        activity.end()
        settleDown()
        XCTAssertEqual(calls, ["start 0", "end 0"])
    }

    /// The host: one tracker per place in the content; arrivals come through the listener.
    func testHostHearsArrivalsAndStartsOverWhenACollectionComesBack() async {
        let host = AddProgressHost()
        let states = [circle("a"), circle("b")]
        host.sync([request(states, line: 10)])
        await drainAsync()
        await OverlayAddedTracker.notify(states)
        await drainAsync(0.6)
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
