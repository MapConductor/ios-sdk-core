import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// 地図を回したとき、コントローラが描画担当に並びの付け直しを頼むこと。
@MainActor
final class MarkerDrawOrderFrameDispatchTests: XCTestCase {
    final class FakeMarker {}

    final class ReorderingRenderer: MarkerOverlayRendererProtocol, MarkerDrawOrderFrameReceiver {
        typealias ActualMarker = FakeMarker

        var animateStartListener: OnMarkerEventHandler?
        var animateEndListener: OnMarkerEventHandler?
        private(set) var frames: [MarkerDrawOrder.Frame] = []
        private(set) var entityCounts: [Int] = []

        func onAdd(data: [MarkerOverlayAddParams]) async -> [FakeMarker?] { data.map { _ in FakeMarker() } }
        func onChange(data: [MarkerOverlayChangeParams<FakeMarker>]) async -> [FakeMarker?] { data.map { _ in FakeMarker() } }
        func onRemove(data: [MarkerEntity<FakeMarker>]) async {}
        func onAnimate(entity: MarkerEntity<FakeMarker>) async {}
        func onPostProcess() async {}

        func onDrawOrderFrameChanged(_ frame: MarkerDrawOrder.Frame, entities: [MarkerEntity<FakeMarker>]) async {
            frames.append(frame)
            entityCounts.append(entities.count)
        }
    }

    final class TestMarkerController: AbstractMarkerController<FakeMarker, ReorderingRenderer> {
        override func find(position: GeoPointProtocol) -> MarkerEntity<FakeMarker>? { nil }
    }

    private func camera(bearing: Double, longitude: Double = 139) -> MapCameraPosition {
        MapCameraPosition(position: GeoPoint(latitude: 35, longitude: longitude), zoom: 10, bearing: bearing)
    }

    func testRotationReachesTheRendererButPansAndSmallTurnsDoNot() async {
        let renderer = ReorderingRenderer()
        let controller = TestMarkerController(markerManager: MarkerManager<FakeMarker>(), renderer: renderer)
        await controller.add(data: [
            MarkerState(position: GeoPoint(latitude: 35, longitude: 139), id: "a"),
            MarkerState(position: GeoPoint(latitude: 35.01, longitude: 139), id: "b"),
        ])

        await controller.onCameraChanged(mapCameraPosition: camera(bearing: 0, longitude: 100))
        XCTAssertTrue(renderer.frames.isEmpty, "north-up pan must not reorder")

        await controller.onCameraChanged(mapCameraPosition: camera(bearing: 180))
        XCTAssertEqual(renderer.frames.map(\.headingDegrees), [180])
        XCTAssertEqual(renderer.entityCounts, [2])

        await controller.onCameraChanged(mapCameraPosition: camera(bearing: 180.2, longitude: 140))
        XCTAssertEqual(renderer.frames.count, 1, "turns under 0.5° are ignored")

        await controller.onCameraChanged(mapCameraPosition: camera(bearing: 0))
        XCTAssertEqual(renderer.frames.map(\.headingDegrees), [180, 0])
    }
}
