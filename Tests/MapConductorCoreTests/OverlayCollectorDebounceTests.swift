import Combine
import XCTest

@testable import MapConductorCore

/// ``OverlayCollector`` の 2 つの配信チャネルの間引き。
///
/// 3 プラットフォームで同じ形にそろえてある:
/// - membership（追加・削除）は **debounce**（5ms の無入力窓、イベントで窓を延長）
/// - in-place 変更は **sample**（1 state につき 1 窓 1 回、最新の値だけ）
///
/// android-sdk の `OverlayCollector` が `debounceBatch(5ms, maxSize)` と
/// `sample(updateDebounce)` で行っているものと同じ。
@MainActor
final class OverlayCollectorDebounceTests: XCTestCase {

    /// テスト用の最小 state。`overlayChangePublisher()` を手で叩ける。
    private final class TestState: OverlayCollectableState {
        let id: String
        private let subject = PassthroughSubject<Void, Never>()

        init(id: String) { self.id = id }

        func overlayChangePublisher() -> AnyPublisher<Void, Never> {
            subject.eraseToAnyPublisher()
        }

        /// in-place 変更が起きたことにする。
        func mutate() { subject.send(()) }
    }

    /// 窓（5ms）より十分長く待つ。
    private func waitForWindow(_ multiplier: Int = 8) async {
        let ns = UInt64(Settings.Default.composeEventDebounce * multiplier) * 1_000_000
        try? await Task.sleep(nanoseconds: ns)
    }

    // MARK: - membership は debounce

    /// 窓の中の連続 sync は 1 回の membership 配信にまとまる。
    func testConsecutiveSyncsCoalesceIntoOneMembershipEmission() async {
        let collector = OverlayCollector<TestState>()
        var emissions: [Int] = []
        collector.onMembershipChange { emissions.append($0.count) }

        var states: [TestState] = []
        for i in 0..<10 {
            states.append(TestState(id: "s\(i)"))
            collector.sync(states)
        }

        // 窓の中はまだ配信されない
        XCTAssertTrue(emissions.isEmpty, "窓が閉じる前に配信されている")
        // ただしコレクション自体は同期で最新（react-sdk の values() と同じ約束）
        XCTAssertEqual(collector.values().count, 10)

        await waitForWindow()

        XCTAssertEqual(emissions, [10], "窓が閉じたときに最新の全件を 1 回だけ配るべき")
    }

    /// membership が変わらない sync は配信を起こさない。
    func testUnchangedSyncDoesNotEmit() async {
        let collector = OverlayCollector<TestState>()
        var emissions = 0
        collector.onMembershipChange { _ in emissions += 1 }

        let states = [TestState(id: "a"), TestState(id: "b")]
        collector.sync(states)
        await waitForWindow()
        XCTAssertEqual(emissions, 1)

        // 同じインスタンス・同じ id をもう一度流しても membership は変わっていない
        collector.sync(states)
        collector.sync(states)
        await waitForWindow()
        XCTAssertEqual(emissions, 1, "membership が変わっていないのに再配信された")
    }

    /// 打ち切り弁: 窓の中で合流した sync が閾値に達したら待たずに出す。
    /// android-sdk の `debounceBatch(window, maxSize)` の maxSize と同じ役割。
    func testMaxBatchFlushesWithoutWaitingForTheWindow() {
        let collector = OverlayCollector<TestState>()
        var emissions = 0
        collector.onMembershipChange { _ in emissions += 1 }

        var states: [TestState] = []
        for i in 0..<100 {
            states.append(TestState(id: "s\(i)"))
            collector.sync(states)
        }

        // await を挟んでいないので、窓ではなく打ち切り弁で出たことが分かる
        XCTAssertEqual(emissions, 1, "閾値に達しても窓を待ってしまっている")
    }

    /// レンダラ未準備（`shouldApply` が false）の間は溜めておき、`flush()` で配る。
    func testPendingMembershipIsHeldUntilShouldApplyFlips() async {
        var ready = false
        let collector = OverlayCollector<TestState>(shouldApply: { ready })
        var emissions: [Int] = []
        collector.onMembershipChange { emissions.append($0.count) }

        collector.sync([TestState(id: "a"), TestState(id: "b")])
        await waitForWindow()
        XCTAssertTrue(emissions.isEmpty, "レンダラ未準備なのに配信された")

        ready = true
        collector.flush()
        XCTAssertEqual(emissions, [2])
    }

    // MARK: - in-place 変更は sample

    /// 同じ state を何度も変更しても、1 窓につき 1 回しか配らない。
    func testInPlaceChangesAreSampledPerWindow() async {
        let collector = OverlayCollector<TestState>()
        var updates: [String] = []
        collector.onStateChange { updates.append($0.id) }

        let state = TestState(id: "a")
        collector.sync([state])
        await waitForWindow()

        // ドラッグ相当: 1 窓の中で何度も発火させる
        for _ in 0..<20 { state.mutate() }
        await waitForWindow()

        XCTAssertEqual(updates, ["a"], "1 窓につき 1 回にまとまっていない")

        // 次の窓の変更はきちんと届く（debounce と違い枯れない）
        state.mutate()
        await waitForWindow()
        XCTAssertEqual(updates, ["a", "a"])
    }

    /// membership がまだ保留のうちに in-place 変更が来ても、add が先に届く。
    func testMembershipIsDeliveredBeforeInPlaceUpdate() async {
        let collector = OverlayCollector<TestState>()
        var log: [String] = []
        collector.onMembershipChange { _ in log.append("membership") }
        collector.onStateChange { log.append("update(\($0.id))") }

        let state = TestState(id: "a")
        collector.sync([state])
        // 窓が閉じる前に in-place 変更
        state.mutate()

        await waitForWindow()

        XCTAssertEqual(log, ["membership", "update(a)"], "update が add より先に届いている")
    }

    /// コレクションから外れた state の保留分は配らない。
    func testPendingUpdateForRemovedStateIsDropped() async {
        let collector = OverlayCollector<TestState>()
        var updates: [String] = []
        collector.onStateChange { updates.append($0.id) }

        let a = TestState(id: "a")
        let b = TestState(id: "b")
        collector.sync([a, b])
        await waitForWindow()

        a.mutate()
        b.mutate()
        // 窓が閉じる前に a を外す
        collector.sync([b])
        await waitForWindow()

        XCTAssertEqual(updates, ["b"], "外した state の更新が配られている")
    }

    /// clear() 後は保留分を含めて何も配らない。
    func testClearDropsPendingWork() async {
        let collector = OverlayCollector<TestState>()
        var emissions = 0
        var updates = 0
        collector.onMembershipChange { _ in emissions += 1 }
        collector.onStateChange { _ in updates += 1 }

        let state = TestState(id: "a")
        collector.sync([state])
        state.mutate()
        collector.clear()

        await waitForWindow()

        XCTAssertEqual(emissions, 0)
        XCTAssertEqual(updates, 0)
        XCTAssertTrue(collector.values().isEmpty)
    }
}
