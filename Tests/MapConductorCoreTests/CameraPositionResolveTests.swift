import XCTest

@testable import MapConductorCore

/// 未指定の zoom / bearing / tilt だけが現在のカメラから引き継がれ、
/// 明示された 0 はそのまま使われることを確認する。
final class CameraPositionResolveTests: XCTestCase {
    private let tokyo = GeoPoint(latitude: 35.6812, longitude: 139.7671)
    private let osaka = GeoPoint(latitude: 34.7025, longitude: 135.4959)

    private var current: MapCameraPosition {
        MapCameraPosition(position: tokyo, zoom: 12, bearing: 30, tilt: 45)
    }

    func testPositionOnlyKeepsEverythingElse() {
        let resolved = MapCameraPosition(position: osaka).resolved(onto: current)
        XCTAssertEqual(GeoPoint.from(position: resolved.position), osaka)
        XCTAssertEqual(resolved.zoom, 12)
        XCTAssertEqual(resolved.bearing, 30)
        XCTAssertEqual(resolved.tilt, 45)
    }

    func testExplicitZeroIsHonoured() {
        let resolved = MapCameraPosition(position: osaka, zoom: 0, bearing: 0, tilt: 0)
            .resolved(onto: current)
        XCTAssertEqual(resolved.zoom, 0)
        XCTAssertEqual(resolved.bearing, 0)
        XCTAssertEqual(resolved.tilt, 0)
    }

    func testEachPropertyIsInheritedOnItsOwn() {
        let zoomOnly = MapCameraPosition(position: osaka, zoom: 0).resolved(onto: current)
        XCTAssertEqual(zoomOnly.zoom, 0)
        XCTAssertEqual(zoomOnly.bearing, 30)
        XCTAssertEqual(zoomOnly.tilt, 45)

        let bearingOnly = MapCameraPosition(position: osaka, bearing: 0).resolved(onto: current)
        XCTAssertEqual(bearingOnly.zoom, 12)
        XCTAssertEqual(bearingOnly.bearing, 0)
        XCTAssertEqual(bearingOnly.tilt, 45)

        let tiltOnly = MapCameraPosition(position: osaka, tilt: 0).resolved(onto: current)
        XCTAssertEqual(tiltOnly.zoom, 12)
        XCTAssertEqual(tiltOnly.bearing, 30)
        XCTAssertEqual(tiltOnly.tilt, 0)
    }

    func testUnspecifiedReadsAsZeroBeforeResolving() {
        let camera = MapCameraPosition(position: osaka)
        XCTAssertEqual(camera.zoom, 0)
        XCTAssertFalse(camera.isZoomSpecified)
        XCTAssertFalse(camera.isBearingSpecified)
        XCTAssertFalse(camera.isTiltSpecified)
        XCTAssertTrue(MapCameraPosition.Default.isZoomSpecified)
    }

    func testCopyKeepsUnspecifiedUnlessGiven() {
        let copied = MapCameraPosition(position: osaka).copy(position: tokyo)
        XCTAssertFalse(copied.isZoomSpecified)

        let withZoom = MapCameraPosition(position: osaka).copy(zoom: 0)
        XCTAssertTrue(withZoom.isZoomSpecified)
        XCTAssertFalse(withZoom.isBearingSpecified)
    }

    func testMapViewStateMergesUnsetPropertiesFromCurrentCamera() {
        let state = MapViewState<Int>(initialCameraPosition: current)

        state.moveCameraTo(cameraPosition: MapCameraPosition(position: osaka, bearing: 0))
        XCTAssertEqual(state.cameraPosition.zoom, 12)
        XCTAssertEqual(state.cameraPosition.bearing, 0)
        XCTAssertEqual(state.cameraPosition.tilt, 45)

        state.moveCameraTo(cameraPosition: MapCameraPosition(position: osaka, zoom: 0))
        XCTAssertEqual(state.cameraPosition.zoom, 0)
    }
}
