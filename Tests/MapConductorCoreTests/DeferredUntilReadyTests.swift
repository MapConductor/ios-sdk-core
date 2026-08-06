import XCTest

@testable import MapConductorCore

/// 「描画側が受け取れるまで保留し、できたら流す」門の意味論。
///
/// 捨てるのではなく遅らせること、準備後は素通しになること、繰り返しの
/// `markReady()`（スタイルは何度も読み込まれる）で壊れないことを固定する。
@MainActor
final class DeferredUntilReadyTests: XCTestCase {

    func testHoldsInputUntilReady() {
        var applied: [[Int]] = []
        let gate = DeferredUntilReady<[Int]> { applied.append($0) }

        gate.submit([1, 2])
        XCTAssertTrue(applied.isEmpty, "準備前に適用されている")
        XCTAssertEqual(gate.latest, [1, 2], "保留中でも最新は参照できるべき")

        gate.markReady()
        XCTAssertEqual(applied, [[1, 2]], "準備できたら保留分を 1 回流すべき")
    }

    /// 準備前に何度も来たら、最後の 1 件だけを流す（途中経過は描く意味がない）。
    func testOnlyTheLastPendingInputIsApplied() {
        var applied: [[Int]] = []
        let gate = DeferredUntilReady<[Int]> { applied.append($0) }

        gate.submit([1])
        gate.submit([1, 2])
        gate.submit([1, 2, 3])
        gate.markReady()

        XCTAssertEqual(applied, [[1, 2, 3]])
    }

    func testAppliesImmediatelyOnceReady() {
        var applied: [[Int]] = []
        let gate = DeferredUntilReady<[Int]> { applied.append($0) }
        gate.markReady()

        gate.submit([1])
        gate.submit([2])

        XCTAssertEqual(applied, [[1], [2]])
    }

    /// 何も渡されていないうちに準備できても、空振りで流さない。
    func testMarkReadyWithoutInputAppliesNothing() {
        var applied: [[Int]] = []
        let gate = DeferredUntilReady<[Int]> { applied.append($0) }

        gate.markReady()

        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(gate.isReady)
    }

    /// スタイルは地図デザインの変更で何度も読み込まれる。そのたびに最新を流し直す。
    func testMarkReadyIsRepeatable() {
        var applied: [[Int]] = []
        let gate = DeferredUntilReady<[Int]> { applied.append($0) }

        gate.submit([1])
        gate.markReady()
        gate.markReady()

        XCTAssertEqual(applied, [[1], [1]], "再読み込みのたびに描き直せること")
    }

    /// reset 後は準備前に戻り、古い保留も残さない。
    func testResetDropsPendingAndReadiness() {
        var applied: [[Int]] = []
        let gate = DeferredUntilReady<[Int]> { applied.append($0) }

        gate.submit([1])
        gate.reset()
        XCTAssertFalse(gate.isReady)
        XCTAssertNil(gate.latest)

        gate.markReady()
        XCTAssertTrue(applied.isEmpty, "reset したのに古い保留が流れている")
    }
}
