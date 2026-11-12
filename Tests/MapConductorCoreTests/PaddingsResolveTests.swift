import XCTest

@testable import MapConductorCore

/// `paddings` の省略された辺だけが現在のカメラの同じ辺から引き継がれ、
/// 明示された 0 はそのまま使われることを確認する。
final class PaddingsResolveTests: XCTestCase {
    private let tokyo = GeoPoint(latitude: 35.6812, longitude: 139.7671)
    private let osaka = GeoPoint(latitude: 34.7025, longitude: 135.4959)

    private var current: MapCameraPosition {
        MapCameraPosition(
            position: tokyo, zoom: 12, bearing: 30, tilt: 45,
            paddings: MapPaddings(top: 10, left: 20, bottom: 30, right: 40)
        )
    }

    private func sides(_ paddings: MapPaddingsProtocol?) -> [Double] {
        guard let paddings else { return [] }
        return [paddings.top, paddings.left, paddings.bottom, paddings.right]
    }

    func testUnsetSidesComeFromTheCurrentCamera() {
        let resolved = MapCameraPosition(position: osaka, zoom: 15, bearing: 0, tilt: 0, paddings: MapPaddings(top: 300))
            .resolved(onto: current)
        XCTAssertEqual(sides(resolved.paddings), [300, 20, 30, 40])
        let paddings = MapPaddings.from(paddings: resolved.paddings!)
        XCTAssertTrue(paddings.isFullySpecified)
    }

    func testAllSidesUnsetCopiesEverySide() {
        let resolved = MapCameraPosition(position: osaka, zoom: 15, bearing: 0, tilt: 0, paddings: MapPaddings())
            .resolved(onto: current)
        XCTAssertEqual(sides(resolved.paddings), [10, 20, 30, 40])
    }

    func testExplicitZeroIsHonoured() {
        let resolved = MapCameraPosition(position: osaka, zoom: 15, bearing: 0, tilt: 0, paddings: MapPaddings(top: 0, left: 0))
            .resolved(onto: current)
        XCTAssertEqual(sides(resolved.paddings), [0, 0, 30, 40])
    }

    func testCurrentWithoutPaddingsFillsZero() {
        let bare = MapCameraPosition(position: tokyo, zoom: 12, paddings: nil)
        let resolved = MapCameraPosition(position: osaka, paddings: MapPaddings(right: 5)).resolved(onto: bare)
        XCTAssertEqual(sides(resolved.paddings), [0, 0, 0, 5])
    }

    func testUnresolvedReadsZeroForUnsetSides() {
        let paddings = MapPaddings(top: 300)
        XCTAssertEqual(sides(paddings), [300, 0, 0, 0])
        XCTAssertTrue(paddings.isTopSpecified)
        XCTAssertFalse(paddings.isLeftSpecified)
        XCTAssertFalse(paddings.isFullySpecified)
        XCTAssertTrue(MapPaddings.Zeros.isFullySpecified)
    }

    func testFromAndCopyKeepUnsetSides() {
        let partial = MapPaddings(bottom: 80)
        XCTAssertFalse(MapPaddings.from(paddings: partial).isTopSpecified)
        let camera = MapCameraPosition(position: osaka, zoom: 15, bearing: 0, tilt: 0, paddings: partial)
        let copied = camera.copy(zoom: 16)
        XCTAssertEqual(sides(copied.resolved(onto: current).paddings), [10, 20, 80, 40])
    }

    func testFastPathIsNotTakenWithAnUnsetSide() {
        let camera = MapCameraPosition(position: osaka, zoom: 15, bearing: 0, tilt: 0, paddings: MapPaddings(top: 1))
        XCTAssertFalse(camera.resolved(onto: current) === camera)
        let full = MapCameraPosition(position: osaka, zoom: 15, bearing: 0, tilt: 0, paddings: MapPaddings(top: 1, left: 2, bottom: 3, right: 4))
        XCTAssertTrue(full.resolved(onto: current) === full)
    }

    func testDefaultPaddingsAreFullySpecifiedZeros() {
        // `paddings` を渡さなければ今までどおり 0 で、引き継がない。
        let resolved = MapCameraPosition(position: osaka, zoom: 15, bearing: 0, tilt: 0).resolved(onto: current)
        XCTAssertEqual(sides(resolved.paddings), [0, 0, 0, 0])
    }

    func testMoveCameraToCopiesUnsetSidesFromState() {
        let state = MapViewState<Int>(initialCameraPosition: current)
        state.moveCameraTo(cameraPosition: MapCameraPosition(position: osaka, paddings: MapPaddings(left: 7)))
        XCTAssertEqual(sides(state.cameraPosition.paddings), [10, 7, 30, 40])
    }
}
