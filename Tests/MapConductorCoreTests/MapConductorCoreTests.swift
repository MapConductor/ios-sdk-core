import XCTest

@testable import MapConductorCore

final class MapConductorCoreTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertTrue(true)
    }

    func testParsesStandardTileCoordinate() {
        XCTAssertEqual(parseTileCoordinate("100.png"), TileCoordinate(y: 100, pixelRatio: 1))
    }

    func testParsesTomTomRetinaTileCoordinate() {
        XCTAssertEqual(parseTileCoordinate("100@2x.png"), TileCoordinate(y: 100, pixelRatio: 2))
    }

    func testRejectsInvalidTileCoordinate() {
        XCTAssertNil(parseTileCoordinate("tile@2x.png"))
        XCTAssertNil(parseTileCoordinate("100@4x.png"))
    }
}
