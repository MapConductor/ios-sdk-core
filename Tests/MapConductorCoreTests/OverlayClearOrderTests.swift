import UIKit
import XCTest

@testable import MapConductorCore

/// clear() の後、地図に何も残らないこと。
///
/// MapLibre / Mapbox / Mappls / MapTiler などの GL 系の描画担当は、remove では何もせず、
/// onPostProcess で manager の全部を描き直す。ここの偽レンダラも同じ作りにしてあり、
/// `drawn` は最後の onPostProcess で描いたもの（＝地図に見えているもの）を表す。
///
/// clear() が manager を空にする前に onPostProcess を呼ぶと、全部を描き直して残る。
/// 呼ばなければ、前に描いたものが残る。android-sdk の OverlayClearOrderTest と同じ。
final class OverlayClearOrderTests: XCTestCase {
    private let a = GeoPoint(latitude: 35.0, longitude: 139.0)
    private let b = GeoPoint(latitude: 35.1, longitude: 139.1)
    private let c = GeoPoint(latitude: 35.0, longitude: 139.1)

    // MARK: - Polygon

    private final class PolygonGL: PolygonOverlayRendererProtocol {
        let manager: PolygonManager<String>
        var drawn: [String] = []
        init(_ manager: PolygonManager<String>) { self.manager = manager }
        func onAdd(data: [PolygonOverlayAddParams]) async -> [String?] { data.map { $0.state.id } }
        func onChange(data: [PolygonOverlayChangeParams<String>]) async -> [String?] { data.map { $0.current.state.id } }
        func onRemove(data: [PolygonEntity<String>]) async {}
        func onPostProcess() async { drawn = manager.allEntities().map { $0.state.id }.sorted() }
    }

    func testPolygonClearLeavesNothingDrawn() async {
        let manager = PolygonManager<String>()
        let renderer = PolygonGL(manager)
        let controller = PolygonController(polygonManager: manager, renderer: renderer)
        await controller.add(data: [
            PolygonState(points: [a, b, c], id: "p1"),
            PolygonState(points: [a, b, c], id: "p2"),
        ])
        XCTAssertEqual(renderer.drawn, ["p1", "p2"])

        await controller.clear()

        XCTAssertEqual(renderer.drawn, [])
    }

    // MARK: - Polyline

    private final class PolylineGL: PolylineOverlayRendererProtocol {
        let manager: PolylineManager<String>
        var drawn: [String] = []
        init(_ manager: PolylineManager<String>) { self.manager = manager }
        func onAdd(data: [PolylineOverlayAddParams]) async -> [String?] { data.map { $0.state.id } }
        func onChange(data: [PolylineOverlayChangeParams<String>]) async -> [String?] { data.map { $0.current.state.id } }
        func onRemove(data: [PolylineEntity<String>]) async {}
        func onPostProcess() async { drawn = manager.allEntities().map { $0.state.id }.sorted() }
    }

    func testPolylineClearLeavesNothingDrawn() async {
        let manager = PolylineManager<String>()
        let renderer = PolylineGL(manager)
        let controller = PolylineController(polylineManager: manager, renderer: renderer)
        await controller.add(data: [
            PolylineState(points: [a, b], id: "l1"),
            PolylineState(points: [b, c], id: "l2"),
        ])
        XCTAssertEqual(renderer.drawn, ["l1", "l2"])

        await controller.clear()

        XCTAssertEqual(renderer.drawn, [])
    }

    // MARK: - Circle

    private final class CircleGL: CircleOverlayRendererProtocol {
        let manager: CircleManager<String>
        var drawn: [String] = []
        init(_ manager: CircleManager<String>) { self.manager = manager }
        func onAdd(data: [CircleOverlayAddParams]) async -> [String?] { data.map { $0.state.id } }
        func onChange(data: [CircleOverlayChangeParams<String>]) async -> [String?] { data.map { $0.current.state.id } }
        func onRemove(data: [CircleEntity<String>]) async {}
        func onPostProcess() async { drawn = manager.allEntities().map { $0.state.id }.sorted() }
    }

    func testCircleClearLeavesNothingDrawn() async {
        let manager = CircleManager<String>()
        let renderer = CircleGL(manager)
        let controller = CircleController(circleManager: manager, renderer: renderer)
        await controller.add(data: [
            CircleState(center: a, radiusMeters: 100, id: "c1"),
            CircleState(center: b, radiusMeters: 50, id: "c2"),
        ])
        XCTAssertEqual(renderer.drawn, ["c1", "c2"])

        await controller.clear()

        XCTAssertEqual(renderer.drawn, [])
    }

    // MARK: - GroundImage

    private final class GroundImageGL: GroundImageOverlayRendererProtocol {
        let manager: GroundImageManager<String>
        var drawn: [String] = []
        init(_ manager: GroundImageManager<String>) { self.manager = manager }
        func onAdd(data: [GroundImageOverlayAddParams]) async -> [String?] { data.map { $0.state.id } }
        func onChange(data: [GroundImageOverlayChangeParams<String>]) async -> [String?] { data.map { $0.current.state.id } }
        func onRemove(data: [GroundImageEntity<String>]) async {}
        func onPostProcess() async { drawn = manager.allEntities().map { $0.state.id }.sorted() }
    }

    func testGroundImageClearLeavesNothingDrawn() async {
        let manager = GroundImageManager<String>()
        let renderer = GroundImageGL(manager)
        let controller = GroundImageController(groundImageManager: manager, renderer: renderer)
        let bounds = GeoRectBounds(southWest: a, northEast: b)
        await controller.add(data: [
            GroundImageState(bounds: bounds, image: UIImage(), id: "g1"),
            GroundImageState(bounds: bounds, image: UIImage(), id: "g2"),
        ])
        XCTAssertEqual(renderer.drawn, ["g1", "g2"])

        await controller.clear()

        XCTAssertEqual(renderer.drawn, [])
    }

    // MARK: - RasterLayer

    private final class RasterGL: RasterLayerOverlayRendererProtocol {
        let manager: RasterLayerManager<String>
        var drawn: [String] = []
        init(_ manager: RasterLayerManager<String>) { self.manager = manager }
        func onAdd(data: [RasterLayerOverlayAddParams]) async -> [String?] { data.map { $0.state.id } }
        func onChange(data: [RasterLayerOverlayChangeParams<String>]) async -> [String?] { data.map { $0.current.state.id } }
        func onRemove(data: [RasterLayerEntity<String>]) async {}
        func onPostProcess() async { drawn = manager.allEntities().map { $0.state.id }.sorted() }
    }

    func testRasterLayerClearLeavesNothingDrawn() async {
        let manager = RasterLayerManager<String>()
        let renderer = RasterGL(manager)
        let controller = RasterLayerController(rasterLayerManager: manager, renderer: renderer)
        await controller.add(data: [
            RasterLayerState(source: .urlTemplate(template: "https://example.com/a/{z}/{x}/{y}.png"), id: "r1"),
            RasterLayerState(source: .urlTemplate(template: "https://example.com/b/{z}/{x}/{y}.png"), id: "r2"),
        ])
        XCTAssertEqual(renderer.drawn, ["r1", "r2"])

        await controller.clear()

        XCTAssertEqual(renderer.drawn, [])
    }

    // MARK: - Marker

    /// MapLibre / Mapbox / Mappls / MapTiler のマーカーの描画担当と同じ作り: onRemove は
    /// アニメーションやアイコンの記録を捨てるだけで、地図のソースは onPostProcess が描き直す。
    @MainActor
    private final class MarkerGL: MarkerOverlayRendererProtocol {
        typealias ActualMarker = String
        let manager: MarkerManager<String>
        var drawn: [String] = []
        var animateStartListener: OnMarkerEventHandler?
        var animateEndListener: OnMarkerEventHandler?
        init(_ manager: MarkerManager<String>) { self.manager = manager }
        func onAdd(data: [MarkerOverlayAddParams]) async -> [String?] { data.map { $0.state.id } }
        func onChange(data: [MarkerOverlayChangeParams<String>]) async -> [String?] { data.map { $0.current.state.id } }
        func onRemove(data: [MarkerEntity<String>]) async {}
        func onAnimate(entity: MarkerEntity<String>) async {}
        func onPostProcess() async { drawn = manager.allEntities().map { $0.state.id }.sorted() }
    }

    /// `find(position:)` が `fatalError` なので具象サブクラスを用意する。
    private final class MarkerControllerGL: AbstractMarkerController<String, MarkerGL> {
        override func find(position: GeoPointProtocol) -> MarkerEntity<String>? { nil }
    }

    @MainActor
    func testMarkerClearLeavesNothingDrawn() async {
        let manager = MarkerManager<String>()
        let renderer = MarkerGL(manager)
        let controller = MarkerControllerGL(markerManager: manager, renderer: renderer)
        await controller.add(data: [
            MarkerState(position: a, id: "m1"),
            MarkerState(position: b, id: "m2"),
        ])
        XCTAssertEqual(renderer.drawn, ["m1", "m2"])

        await controller.clear()

        XCTAssertEqual(renderer.drawn, [])
    }
}
