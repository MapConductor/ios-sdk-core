import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// `onAdded` of every overlay state: once each time it goes from "not on the map"
/// to "on the map", on the main actor.
///
/// - Native drawing: after the renderer's `onAdd` returned the native object.
/// - Tiles: after the tile layer's URL template was handed to the map.
/// - Not for an in-place change, a move between native and tiles, or `clear`.
/// - Again after a remove and a later add.
@MainActor
final class OverlayOnAddedTests: XCTestCase {
    // MARK: - Polygons

    private final class PolygonRenderer: AbstractPolygonOverlayRenderer<String> {
        var created: [String] = []
        override func createPolygon(state: PolygonState) async -> String? {
            created.append(state.id)
            return state.id
        }
        override func updatePolygonProperties(
            polygon: String, current: PolygonEntity<String>, prev: PolygonEntity<String>
        ) async -> String? { polygon }
        override func removePolygon(entity: PolygonEntity<String>) async {}
    }

    /// Counts calls per id and checks each one runs on the main thread.
    private final class Recorder {
        var calls: [String] = []
        var offMain = 0
        var onCall: ((String) -> Void)?
        func record(_ id: String) {
            if !Thread.isMainThread { offMain += 1 }
            calls.append(id)
            onCall?(id)
        }
        func count(_ id: String) -> Int { calls.filter { $0 == id }.count }
    }

    private func polygons(_ count: Int, recorder: Recorder) -> [PolygonState] {
        (0..<count).map { i in
            let lat = 42.30 + Double(i / 100) * 0.001, lng = -71.10 + Double(i % 100) * 0.001
            return PolygonState(
                points: [
                    GeoPoint(latitude: lat, longitude: lng),
                    GeoPoint(latitude: lat, longitude: lng + 0.0005),
                    GeoPoint(latitude: lat + 0.0005, longitude: lng + 0.0005),
                    GeoPoint(latitude: lat + 0.0005, longitude: lng),
                ],
                id: "p\(i)",
                fillColor: .red,
                onAdded: { [recorder] state in recorder.record(state.id) }
            )
        }
    }

    private func polygonController(tileFrom minCount: Int? = nil)
        -> (PolygonController<String, PolygonRenderer>, PolygonRenderer, PolygonTiler?) {
        let renderer = PolygonRenderer()
        let controller = PolygonController<String, PolygonRenderer>(
            polygonManager: PolygonManager<String>(), renderer: renderer
        )
        var tiler: PolygonTiler?
        if let minCount {
            tiler = PolygonTiler(options: PolygonTilingOptions(minPolygonCount: minCount))
            controller.tiler = tiler
        }
        return (controller, renderer, tiler)
    }

    func testNativePolygonsAreReportedAfterTheRendererCreatedThem() async {
        let recorder = Recorder()
        let (controller, renderer, _) = polygonController()
        recorder.onCall = { id in XCTAssertTrue(renderer.created.contains(id), "\(id) reported before it was drawn") }
        let all = polygons(3, recorder: recorder)
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.sorted(), ["p0", "p1", "p2"])
        XCTAssertEqual(recorder.offMain, 0)
    }

    func testTiledPolygonsAreReportedAfterTheTemplateReachedTheMap() async {
        let recorder = Recorder()
        let (controller, renderer, tiler) = polygonController(tileFrom: 10)
        var templateHandedOver = false
        tiler?.onTemplate = { template, _ in
            // The provider's raster upsert: suspends before it returns.
            await Task.yield()
            if template != nil { templateHandedOver = true }
        }
        recorder.onCall = { _ in XCTAssertTrue(templateHandedOver, "reported before the tile layer reached the map") }
        await controller.add(data: polygons(20, recorder: recorder))
        XCTAssertTrue(renderer.created.isEmpty)
        XCTAssertEqual(recorder.calls.count, 20)
        XCTAssertEqual(Set(recorder.calls).count, 20)
        XCTAssertEqual(recorder.offMain, 0)
    }

    func testInPlaceChangesAreNotReported() async {
        let recorder = Recorder()
        for tileFrom in [nil, 10] as [Int?] {
            recorder.calls = []
            let (controller, _, tiler) = polygonController(tileFrom: tileFrom)
            tiler?.onTemplate = { _, _ in }
            let all = polygons(20, recorder: recorder)
            await controller.add(data: all)
            XCTAssertEqual(recorder.calls.count, 20)

            all[3].fillColor = .blue
            await controller.update(state: all[3])
            // The list sync after the change, with a new fingerprint.
            all[4].strokeWidth = 4
            await controller.add(data: all)
            // The same list again.
            await controller.add(data: all)
            XCTAssertEqual(recorder.calls.count, 20, "tileFrom=\(String(describing: tileFrom))")
        }
    }

    func testMovingBetweenNativeAndTilesIsNotReported() async {
        let recorder = Recorder()
        let (controller, renderer, tiler) = polygonController(tileFrom: 10)
        tiler?.onTemplate = { _, _ in }
        let all = polygons(20, recorder: recorder)

        await controller.add(data: Array(all.prefix(5)))
        XCTAssertEqual(renderer.created.count, 5)
        XCTAssertEqual(recorder.calls.count, 5)

        // Over the threshold: all 20 go to tiles; only the 15 new ones are reported.
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.count, 20)
        XCTAssertEqual(Set(recorder.calls).count, 20)

        // Back under: the 5 that stay are drawn natively again, but never left the map.
        await controller.add(data: Array(all.prefix(5)))
        XCTAssertEqual(renderer.created.count, 10)
        XCTAssertEqual(recorder.calls.count, 20)
    }

    func testRemovedAndAddedAgainIsReportedAgain() async {
        let recorder = Recorder()
        for tileFrom in [nil, 10] as [Int?] {
            recorder.calls = []
            let (controller, _, tiler) = polygonController(tileFrom: tileFrom)
            tiler?.onTemplate = { _, _ in }
            let all = polygons(20, recorder: recorder)
            await controller.add(data: all)
            await controller.add(data: Array(all.dropFirst()))
            XCTAssertEqual(recorder.count("p0"), 1)
            await controller.add(data: all)
            XCTAssertEqual(recorder.count("p0"), 2, "tileFrom=\(String(describing: tileFrom))")
            XCTAssertEqual(recorder.count("p1"), 1)
        }
    }

    func testClearIsNotReportedButTheNextAddIs() async {
        let recorder = Recorder()
        let (controller, _, _) = polygonController()
        let all = polygons(3, recorder: recorder)
        await controller.add(data: all)
        await controller.clear()
        XCTAssertEqual(recorder.calls.count, 3)
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.count, 6)
    }

    func testAHandlerThatChangesOtherStatesDoesNotStopTheRest() async {
        // Swift handlers cannot throw, so "an exception in one handler" cannot
        // happen. The closest thing: a handler that edits the list's other
        // states (clears their handler, changes their color) while the calls
        // are being made. Every polygon that still has a handler is reported.
        let recorder = Recorder()
        let (controller, _, _) = polygonController()
        let all = polygons(4, recorder: recorder)
        all[0].onAdded = { state in
            recorder.record(state.id)
            for other in all.dropFirst() { other.fillColor = .green }
        }
        all[2].onAdded = nil
        await controller.add(data: all)
        XCTAssertEqual(Set(recorder.calls), ["p0", "p1", "p3"])
    }

    func testOnAddedIsNotPartOfIdentityAndDoesNotRedraw() {
        let a = PolygonState(points: [GeoPoint(latitude: 1, longitude: 1)], fillColor: .red)
        let b = PolygonState(points: [GeoPoint(latitude: 1, longitude: 1)], fillColor: .red, onAdded: { _ in })
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.fingerPrint(), b.fingerPrint())
        XCTAssertEqual(a.hashCode(), b.hashCode())
        XCTAssertEqual(a, b)

        var mutated = 0
        b.mutations.listen { mutated += 1 }
        b.onAdded = nil
        b.onAdded = { _ in }
        XCTAssertEqual(mutated, 0)

        XCTAssertNotNil(b.copy().onAdded)
        XCTAssertNotNil(a.copy(onAdded: { _ in }).onAdded)

        let m1 = MarkerState(position: GeoPoint(latitude: 1, longitude: 1))
        let m2 = MarkerState(position: GeoPoint(latitude: 1, longitude: 1), onAdded: { _ in })
        XCTAssertEqual(m1.id, m2.id)
        XCTAssertEqual(m1.fingerPrint(), m2.fingerPrint())
        XCTAssertNotNil(m2.copy().onAdded)

        let c1 = CircleState(center: GeoPoint(latitude: 1, longitude: 1), radiusMeters: 10)
        let c2 = CircleState(center: GeoPoint(latitude: 1, longitude: 1), radiusMeters: 10, onAdded: { _ in })
        XCTAssertEqual(c1.id, c2.id)
        XCTAssertEqual(c1.fingerPrint(), c2.fingerPrint())
        XCTAssertNotNil(c2.copy().onAdded)

        let l1 = PolylineState(points: [GeoPoint(latitude: 1, longitude: 1)])
        let l2 = PolylineState(points: [GeoPoint(latitude: 1, longitude: 1)], onAdded: { _ in })
        XCTAssertEqual(l1.id, l2.id)
        XCTAssertEqual(l1.fingerPrint(), l2.fingerPrint())
        XCTAssertNotNil(l2.copy().onAdded)

        let r1 = RasterLayerState(source: .urlTemplate(template: "https://t/{z}/{x}/{y}.png", tileSize: 256))
        let r2 = RasterLayerState(
            source: .urlTemplate(template: "https://t/{z}/{x}/{y}.png", tileSize: 256), onAdded: { _ in }
        )
        XCTAssertEqual(r1.id, r2.id)
        XCTAssertEqual(r1.fingerPrint(), r2.fingerPrint())
        XCTAssertNotNil(r2.copy().onAdded)

        let bounds = GeoRectBounds(
            southWest: GeoPoint(latitude: 0, longitude: 0), northEast: GeoPoint(latitude: 1, longitude: 1)
        )
        let image = UIImage()
        let g1 = GroundImageState(bounds: bounds, image: image)
        let g2 = GroundImageState(bounds: bounds, image: image, onAdded: { _ in })
        XCTAssertEqual(g1.id, g2.id)
        XCTAssertEqual(g1.fingerPrint(), g2.fingerPrint())
        XCTAssertNotNil(g2.copy().onAdded)
    }

    // MARK: - Circles, polylines, ground images, raster layers (native only)

    private final class CircleRenderer: AbstractCircleOverlayRenderer<String> {
        override func createCircle(state: CircleState) async -> String? { state.id }
        override func updateCircleProperties(
            circle: String, current: CircleEntity<String>, prev: CircleEntity<String>
        ) async -> String? { circle }
        override func removeCircle(entity: CircleEntity<String>) async {}
    }

    func testCircles() async {
        let recorder = Recorder()
        let controller = CircleController<String, CircleRenderer>(
            circleManager: CircleManager<String>(), renderer: CircleRenderer()
        )
        let all = (0..<3).map { i in
            CircleState(
                center: GeoPoint(latitude: Double(i), longitude: 0), radiusMeters: 10, id: "c\(i)",
                onAdded: { recorder.record($0.id) }
            )
        }
        await controller.add(data: all)
        all[0].radiusMeters = 20
        await controller.update(state: all[0])
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.sorted(), ["c0", "c1", "c2"])
        await controller.add(data: [all[1]])
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.sorted(), ["c0", "c0", "c1", "c2", "c2"])
        await controller.clear()
        XCTAssertEqual(recorder.calls.count, 5)
        XCTAssertEqual(recorder.offMain, 0)
    }

    private final class PolylineRenderer: AbstractPolylineOverlayRenderer<String> {
        override func createPolyline(state: PolylineState) async -> String? { state.id }
        override func updatePolylineProperties(
            polyline: String, current: PolylineEntity<String>, prev: PolylineEntity<String>
        ) async -> String? { polyline }
        override func removePolyline(entity: PolylineEntity<String>) async {}
    }

    func testPolylines() async {
        let recorder = Recorder()
        let controller = PolylineController<String, PolylineRenderer>(
            polylineManager: PolylineManager<String>(), renderer: PolylineRenderer()
        )
        let all = (0..<3).map { i in
            PolylineState(
                points: [GeoPoint(latitude: Double(i), longitude: 0), GeoPoint(latitude: Double(i), longitude: 1)],
                id: "l\(i)",
                onAdded: { recorder.record($0.id) }
            )
        }
        await controller.add(data: all)
        all[0].strokeWidth = 5
        await controller.update(state: all[0])
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.sorted(), ["l0", "l1", "l2"])
        await controller.add(data: [])
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.count, 6)
        XCTAssertEqual(recorder.offMain, 0)
    }

    private final class GroundImageRenderer: AbstractGroundImageOverlayRenderer<String> {
        override func createGroundImage(state: GroundImageState) async -> String? { state.id }
        override func updateGroundImageProperties(
            groundImage: String, current: GroundImageEntity<String>, prev: GroundImageEntity<String>
        ) async -> String? { groundImage }
        override func removeGroundImage(entity: GroundImageEntity<String>) async {}
    }

    func testGroundImages() async {
        let recorder = Recorder()
        let controller = GroundImageController<String, GroundImageRenderer>(
            groundImageManager: GroundImageManager<String>(), renderer: GroundImageRenderer()
        )
        let bounds = GeoRectBounds(
            southWest: GeoPoint(latitude: 0, longitude: 0), northEast: GeoPoint(latitude: 1, longitude: 1)
        )
        let state = GroundImageState(bounds: bounds, image: UIImage(), id: "g0", onAdded: { recorder.record($0.id) })
        await controller.add(data: [state])
        state.opacity = 0.5
        await controller.update(state: state)
        await controller.add(data: [state])
        XCTAssertEqual(recorder.calls, ["g0"])
        await controller.add(data: [])
        await controller.add(data: [state])
        XCTAssertEqual(recorder.calls, ["g0", "g0"])
    }

    private final class RasterRenderer: AbstractRasterLayerOverlayRenderer<String> {
        override func createLayer(state: RasterLayerState) async -> String? { state.id }
        override func updateLayerProperties(
            layer: String, current: RasterLayerEntity<String>, prev: RasterLayerEntity<String>
        ) async -> String? { layer }
        override func removeLayer(entity: RasterLayerEntity<String>) async {}
    }

    func testRasterLayers() async {
        let recorder = Recorder()
        let controller = RasterLayerController<String, RasterRenderer>(
            rasterLayerManager: RasterLayerManager<String>(), renderer: RasterRenderer()
        )
        let state = RasterLayerState(
            source: .urlTemplate(template: "https://t/{z}/{x}/{y}.png", tileSize: 256), id: "r0",
            onAdded: { recorder.record($0.id) }
        )
        await controller.add(data: [state])
        state.opacity = 0.5
        await controller.update(state: state)
        await controller.add(data: [state])
        XCTAssertEqual(recorder.calls, ["r0"])
        await controller.clear()
        await controller.add(data: [state])
        XCTAssertEqual(recorder.calls, ["r0", "r0"])
    }

    // MARK: - Markers

    private final class MarkerRenderer: MarkerOverlayRendererProtocol {
        typealias ActualMarker = String
        var animateStartListener: OnMarkerEventHandler?
        var animateEndListener: OnMarkerEventHandler?
        var flushed: Set<String> = []
        private var pending: [String] = []
        func onAdd(data: [MarkerOverlayAddParams]) async -> [String?] {
            pending += data.map(\.state.id)
            return data.map { $0.state.id }
        }
        func onChange(data: [MarkerOverlayChangeParams<String>]) async -> [String?] {
            data.map { $0.current.state.id }
        }
        func onRemove(data: [MarkerEntity<String>]) async {}
        func onAnimate(entity: MarkerEntity<String>) async {}
        /// Like the GeoJSON-backed renderers: markers reach the map here.
        func onPostProcess() async {
            flushed.formUnion(pending)
            pending = []
        }
    }

    private final class MarkerController: AbstractMarkerController<String, MarkerRenderer> {
        override func find(position: GeoPointProtocol) -> MarkerEntity<String>? { nil }
    }

    private func markers(_ count: Int, recorder: Recorder) -> [MarkerState] {
        (0..<count).map { i in
            MarkerState(
                position: GeoPoint(latitude: 35 + Double(i) * 1e-4, longitude: 139),
                id: "m\(i)",
                onAdded: { recorder.record($0.id) }
            )
        }
    }

    func testMarkersThroughTheAbstractController() async {
        let recorder = Recorder()
        let renderer = MarkerRenderer()
        let controller = MarkerController(markerManager: MarkerManager<String>(), renderer: renderer)
        recorder.onCall = { id in XCTAssertTrue(renderer.flushed.contains(id), "\(id) reported before the flush") }
        // More than one render batch.
        let all = markers(1_200, recorder: recorder)
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.count, 1_200)
        all[0].position = GeoPoint(latitude: 0, longitude: 0)
        await controller.update(state: all[0])
        await controller.add(data: all)
        XCTAssertEqual(recorder.calls.count, 1_200)
        await controller.add(data: Array(all.dropFirst()))
        await controller.add(data: all)
        XCTAssertEqual(recorder.count("m0"), 2)
        await controller.clear()
        XCTAssertEqual(recorder.calls.count, 1_201)
        XCTAssertEqual(recorder.offMain, 0)
    }

    func testMarkersThroughTheIngestionEngine() async {
        let recorder = Recorder()
        let renderer = MarkerRenderer()
        let manager = MarkerManager<String>()
        let tracker = OverlayAddedTracker()
        var tiledIds: Set<String> = []
        let all = markers(10, recorder: recorder)
        var tileThese: Set<String> = ["m5", "m6", "m7", "m8", "m9"]

        func ingest() async -> MarkerIngestionEngine.Result {
            await MarkerIngestionEngine.ingest(
                data: all, markerManager: manager, renderer: renderer,
                defaultMarkerIcon: DefaultMarkerIcon().toBitmapIcon(), tilingEnabled: true,
                tiledMarkerIds: &tiledIds, addedTracker: tracker,
                shouldTile: { [tileThese] in tileThese.contains($0.id) }
            )
        }

        var result = await ingest()
        // Native ones right away; the tiled ones wait for the provider's tile layer.
        XCTAssertEqual(recorder.calls.sorted(), ["m0", "m1", "m2", "m3", "m4"])
        XCTAssertEqual(result.tiledAdded.map(\.id).sorted(), ["m5", "m6", "m7", "m8", "m9"])
        await tracker.admitAndNotify(result.tiledAdded)
        XCTAssertEqual(recorder.calls.count, 10)

        // Native -> tiles and tiles -> native: still on the map.
        tileThese = ["m0", "m1", "m2", "m3", "m4"]
        result = await ingest()
        XCTAssertTrue(result.tiledAdded.isEmpty)
        await tracker.admitAndNotify(result.tiledAdded)
        XCTAssertEqual(recorder.calls.count, 10)
        XCTAssertEqual(recorder.offMain, 0)
    }
}
