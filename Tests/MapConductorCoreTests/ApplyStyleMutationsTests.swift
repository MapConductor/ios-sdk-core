import XCTest

@testable import MapConductorCore

/**
 The body of every provider's mutation support, against a renderer that only
 records.

 Kept in step with `ApplyStyleMutationsTest` on Android and
 `applyStyleMutations.test.mjs` on the web.
 */
final class ApplyStyleMutationsTests: XCTestCase {
    private final class Recorder: StyleMutationTarget {
        var calls: [String] = []
        var layers: Set<String> = ["roads", "labels"]
        var refuse: String?
        var ready = true

        var isReady: Bool { ready }

        func hasLayer(_ layerId: String) -> Bool { layers.contains(layerId) }

        func setPaint(_ layerId: String, _ key: String, _ valueJson: String) throws {
            if key == refuse { throw Failure.refused }
            calls.append("paint \(layerId) \(key)=\(valueJson)")
        }

        func setLayout(_ layerId: String, _ key: String, _ valueJson: String) throws {
            calls.append("layout \(layerId) \(key)=\(valueJson)")
        }

        func setFilter(_ layerId: String, _ filterJson: String) throws {
            calls.append("filter \(layerId)=\(filterJson)")
        }

        func setZoomRange(_ layerId: String, _ minZoom: Double, _ maxZoom: Double) throws {
            calls.append("zoom \(layerId)=\(minZoom)..\(maxZoom)")
        }

        func addLayer(_ layerId: String, _ layerJson: String, _ beforeId: String?) throws {
            calls.append("add \(layerId) \(layerJson) before=\(beforeId ?? "nil")")
        }

        func removeLayer(_ layerId: String) throws {
            layers.remove(layerId)
            calls.append("remove \(layerId)")
        }

        enum Failure: Error { case refused }
    }

    func testSetsPaintAndLayoutProperties() {
        let target = Recorder()
        let unapplied = applyStyleMutations(
            target,
            [
                .setPaint(layerId: "roads", key: "line-color", value: "\"#fff\"", previous: "\"#888\""),
                .setLayout(layerId: "labels", key: "visibility", value: "\"none\"", previous: "null"),
            ]
        )

        XCTAssertTrue(unapplied.isEmpty)
        XCTAssertEqual(
            target.calls,
            ["paint roads line-color=\"#fff\"", "layout labels visibility=\"none\""]
        )
    }

    /// Every renderer takes both ends of a zoom range at once, so a mutation
    /// that changes one has to restate the other — and a layer that named
    /// neither gets the spec's own defaults.
    func testAZoomRangeRestatesBothEnds() {
        let target = Recorder()
        _ = applyStyleMutations(
            target,
            [
                .setZoomRange(
                    layerId: "roads", minZoom: 5, maxZoom: nil,
                    previousMinZoom: nil, previousMaxZoom: nil
                ),
            ]
        )
        XCTAssertEqual(target.calls, ["zoom roads=5.0..24.0"])
    }

    /// A layer the style does not have is not a crash and not a silent pass:
    /// it comes back, and the caller says so.
    func testWhatTheStyleHasNoLayerForComesBack() {
        let target = Recorder()
        let unapplied = applyStyleMutations(
            target,
            [
                .setPaint(layerId: "roads", key: "line-color", value: "\"#fff\"", previous: "null"),
                .setPaint(layerId: "nope", key: "line-color", value: "\"#fff\"", previous: "null"),
            ]
        )
        XCTAssertEqual(unapplied.count, 1)
        XCTAssertEqual(unapplied.first?.layerId, "nope")
        XCTAssertEqual(target.calls.count, 1, "the good one still went through")
    }

    /// One property the renderer rejects must not cost the other three hundred.
    func testAThrowingPropertyIsReportedNotPropagated() {
        let target = Recorder()
        target.refuse = "line-gradient"
        let unapplied = applyStyleMutations(
            target,
            [
                .setPaint(layerId: "roads", key: "line-gradient", value: "[]", previous: "null"),
                .setPaint(layerId: "roads", key: "line-color", value: "\"#fff\"", previous: "null"),
            ]
        )
        XCTAssertEqual(unapplied.count, 1)
        XCTAssertEqual(target.calls, ["paint roads line-color=\"#fff\""])
    }

    func testAddsAndRemovesALayer() {
        let target = Recorder()
        _ = applyStyleMutations(
            target,
            [.addLayer(layerId: "bg", layer: #"{"id":"bg","type":"background"}"#, beforeId: "roads")]
        )
        XCTAssertEqual(target.calls, [#"add bg {"id":"bg","type":"background"} before=roads"#])

        target.calls = []
        _ = applyStyleMutations(target, [.removeLayer(layerId: "roads")])
        XCTAssertEqual(target.calls, ["remove roads"])
    }

    /**
     Adding and removing go through whatever the layer is, every time.

     The renderer decides what to do about a layer that is already there, or
     already gone — only it can say. Putting the whole set back after a style
     reload depends on this: a layer missing from the reloaded style must
     still be added, and `hasLayer` cannot be trusted to notice.
     */
    func testAddAndRemoveAreNotGuardedHere() {
        let target = Recorder()
        let unapplied = applyStyleMutations(
            target,
            [
                .addLayer(layerId: "roads", layer: #"{"id":"roads","type":"background"}"#, beforeId: nil),
                .removeLayer(layerId: "gone"),
            ]
        )
        XCTAssertTrue(unapplied.isEmpty)
        XCTAssertEqual(
            target.calls,
            [#"add roads {"id":"roads","type":"background"} before=nil"#, "remove gone"]
        )
    }

    /**
     No style yet is "not done" rather than "cannot be done".

     Conflating the two is what told an app "N adjustments were not applied:
     this map cannot set those properties" about a map that was merely still
     loading — and under the reloading policy it then handed the map the
     adjusted document, which is the reload this design exists to avoid.
     Nothing is lost by waiting: the store puts the whole set back when the
     style loads.
     */
    func testNothingIsReportedWhileThereIsNoStyle() {
        let target = Recorder()
        target.ready = false

        let unapplied = applyStyleMutations(
            target,
            [
                .setPaint(layerId: "roads", key: "line-color", value: "\"#fff\"", previous: "null"),
                .setPaint(layerId: "nope", key: "line-color", value: "\"#fff\"", previous: "null"),
            ]
        )

        XCTAssertTrue(unapplied.isEmpty)
        XCTAssertTrue(target.calls.isEmpty, "not even attempted")
    }

    /// Once it is ready, the judgement comes back exactly as before.
    func testTheJudgementComesBackOnceReady() {
        let target = Recorder()
        let paint = StyleMutation.setPaint(
            layerId: "nope", key: "line-color", value: "\"#fff\"", previous: "null")

        target.ready = false
        XCTAssertTrue(applyStyleMutations(target, [paint]).isEmpty)

        target.ready = true
        XCTAssertEqual(applyStyleMutations(target, [paint]).count, 1)
    }

    /**
     The default is "always ready", so a driver outside this repo that has
     not implemented it behaves as it did before — a compatibility default,
     not a recommendation.
     */
    func testIsReadyDefaultsToTrue() {
        struct Plain: StyleMutationTarget {
            func hasLayer(_ layerId: String) -> Bool { false }
            func setPaint(_ layerId: String, _ key: String, _ valueJson: String) throws {}
            func setLayout(_ layerId: String, _ key: String, _ valueJson: String) throws {}
            func setFilter(_ layerId: String, _ filterJson: String) throws {}
            func setZoomRange(_ layerId: String, _ minZoom: Double, _ maxZoom: Double) throws {}
            func addLayer(_ layerId: String, _ layerJson: String, _ beforeId: String?) throws {}
            func removeLayer(_ layerId: String) throws {}
        }

        XCTAssertTrue(Plain().isReady)
        XCTAssertEqual(
            applyStyleMutations(
                Plain(),
                [
                    .setPaint(
                        layerId: "roads", key: "line-color", value: "\"#fff\"", previous: "null")
                ]
            ).count,
            1
        )
    }
}
