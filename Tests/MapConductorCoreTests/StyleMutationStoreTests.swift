import XCTest

@testable import MapConductorCore

/**
 The two things a provider would otherwise have to remember on its own, and
 both of which look fine until they do not: a replaced set has to undo what
 it dropped, and a style load wipes everything that was applied.

 Kept in step with `StyleMutationStoreTest` on Android.
 */
final class StyleMutationStoreTests: XCTestCase {
    private var applied: [StyleMutation] = []

    override func setUp() {
        super.setUp()
        applied = []
    }

    private func store(unsupported: @escaping (StyleMutation) -> Bool = { _ in false })
        -> StyleMutationStore
    {
        StyleMutationStore { [weak self] mutations in
            self?.applied.append(contentsOf: mutations)
            return mutations.filter(unsupported)
        }
    }

    private func paint(_ layer: String, _ key: String, _ value: String, _ previous: String)
        -> StyleMutation
    {
        .setPaint(layerId: layer, key: key, value: value, previous: previous)
    }

    func testReplacingASetPutsBackWhatTheNewOneNoLongerMentions() {
        let store = store()
        _ = store.apply([
            paint("roads", "line-color", "\"#fff\"", "\"#888\""),
            paint("water", "fill-color", "\"#000\"", "\"#a0c8f0\""),
        ])
        applied = []

        // The second set drops the water rule entirely.
        _ = store.apply([paint("roads", "line-color", "\"#f00\"", "\"#888\"")])

        XCTAssertEqual(
            applied,
            [
                paint("water", "fill-color", "\"#a0c8f0\"", "\"#000\""),
                paint("roads", "line-color", "\"#f00\"", "\"#888\""),
            ],
            "water goes back to the style's own colour, then roads take the new one"
        )
    }

    /// The restore has to be sent before the new value, or a property that
    /// both sets touch would be put back to the style's value after being
    /// given its new one.
    func testRestoresGoOutBeforeTheNewValues() {
        let store = store()
        _ = store.apply([paint("a", "line-color", "\"#1\"", "\"#0\"")])
        applied = []
        _ = store.apply([paint("b", "line-color", "\"#2\"", "\"#0\"")])

        XCTAssertEqual(applied.first?.layerId, "a")
        XCTAssertEqual(applied.last?.layerId, "b")
    }

    func testClearPutsEverythingBack() {
        let store = store()
        _ = store.apply([paint("roads", "line-color", "\"#fff\"", "\"#888\"")])
        applied = []

        store.clear()

        XCTAssertEqual(applied, [paint("roads", "line-color", "\"#888\"", "\"#fff\"")])
        XCTAssertTrue(store.applied.isEmpty)
    }

    /// A design change, a provider reloading, anything: the renderer comes
    /// back with the document's values and nothing that was applied over
    /// them. Without this the adjustment survives until the first basemap
    /// switch and then quietly stops.
    func testAStyleLoadPutsTheWholeSetOnAgain() {
        let store = store()
        let mutations = [paint("roads", "line-color", "\"#fff\"", "\"#888\"")]
        _ = store.apply(mutations)
        applied = []

        store.onStyleLoaded()

        XCTAssertEqual(applied, mutations)
    }

    func testNothingAppliedMeansNothingToDoOnAStyleLoad() {
        store().onStyleLoaded()
        XCTAssertTrue(applied.isEmpty)
    }

    /// MapLibre here cannot set every spec key by name. The caller has to be
    /// told which ones, rather than being left to assume the map looks the
    /// way the rules asked.
    func testWhatTheMapCouldNotDoComesBack() {
        let store = store(unsupported: { mutation in
            if case let .setPaint(_, key, _, _) = mutation { return key == "line-gradient" }
            return false
        })
        let failed = store.apply([
            paint("roads", "line-color", "\"#fff\"", "\"#888\""),
            paint("roads", "line-gradient", "[\"interpolate\"]", "null"),
        ])
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.target, "paint|roads|line-gradient")
    }

    func testReadsWhatTheCompilerWrites() {
        let parsed = StyleMutation.parseList(
            """
            [
              {"op":"setPaint","layerId":"roads","key":"line-color","value":"#fff","previous":null},
              {"op":"setLayout","layerId":"labels","key":"visibility","value":"none","previous":"visible"},
              {"op":"setFilter","layerId":"roads","value":["==","class","motorway"],"previous":null},
              {"op":"setZoomRange","layerId":"roads","minZoom":5,"maxZoom":null,
               "previousMinZoom":null,"previousMaxZoom":null},
              {"op":"addLayer","layerId":"bg","layer":{"id":"bg","type":"background"},"beforeId":"water"},
              {"op":"somethingFromTheFuture","layerId":"roads"}
            ]
            """
        )

        XCTAssertEqual(parsed.count, 5, "the unknown op is dropped, the rest survive")
        // A string value keeps its quotes, or no renderer could read it back.
        XCTAssertEqual(parsed[0], paint("roads", "line-color", "\"#fff\"", "null"))
        XCTAssertEqual(
            parsed[2],
            .setFilter(layerId: "roads", value: "[\"==\",\"class\",\"motorway\"]", previous: "null")
        )
        XCTAssertEqual(
            parsed[3],
            .setZoomRange(
                layerId: "roads", minZoom: 5, maxZoom: nil,
                previousMinZoom: nil, previousMaxZoom: nil
            )
        )
        XCTAssertEqual(parsed[4].layerId, "bg")
    }

    /// Rubbish in must not take the map down; it means no adjustment.
    func testAnswersWithNothingRatherThanThrowing() {
        XCTAssertTrue(StyleMutation.parseList("not json").isEmpty)
        XCTAssertTrue(StyleMutation.parseList("{}").isEmpty)
        XCTAssertTrue(StyleMutation.parseList("[{\"op\":\"setPaint\"}]").isEmpty)
    }

    /// Applying a set and then its reverse has to leave the map where it
    /// started, whatever the values were.
    func testEveryMutationUndoesItself() {
        let mutations: [StyleMutation] = [
            paint("a", "line-color", "\"#fff\"", "\"#888\""),
            .setLayout(layerId: "b", key: "visibility", value: "\"none\"", previous: "null"),
            .setFilter(layerId: "c", value: "[\"all\"]", previous: "null"),
            .setZoomRange(
                layerId: "d", minZoom: 5, maxZoom: 12, previousMinZoom: nil, previousMaxZoom: 22
            ),
        ]
        for mutation in mutations {
            XCTAssertEqual(
                mutation.reversed()?.reversed(), mutation,
                "\(mutation.target) did not survive a round trip"
            )
        }
    }

    func testAddingALayerIsUndoneByRemovingIt() {
        let add = StyleMutation.addLayer(
            layerId: "bg", layer: #"{"id":"bg","type":"background"}"#, beforeId: nil)
        XCTAssertEqual(add.reversed(), .removeLayer(layerId: "bg"))
    }

    /// Booleans arrive from `JSONSerialization` as `NSNumber` and must not
    /// come out as `1`: a renderer reading back `1` where the style said
    /// `true` is a renderer given a different style.
    func testWritesBooleansAsBooleans() {
        XCTAssertEqual(StyleMutation.jsonText(of: true), "true")
        XCTAssertEqual(StyleMutation.jsonText(of: false), "false")
        XCTAssertEqual(StyleMutation.jsonText(of: 2), "2")
        XCTAssertEqual(StyleMutation.jsonText(of: "it \"quotes\""), "\"it \\\"quotes\\\"\"")
        XCTAssertEqual(StyleMutation.jsonText(of: nil), "null")
    }
}
