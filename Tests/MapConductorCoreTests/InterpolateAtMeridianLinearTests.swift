import XCTest

@testable import MapConductorCore

/// Android 版 InterpolateAtMeridianLinearTest と同じケースを検証する。
final class InterpolateAtMeridianLinearTests: XCTestCase {
    func testEastwardCrossingInterpolatesLatitudeAtMidpoint() {
        // 170°E → -170°(=190°E) の横断。180° はちょうど中間なので緯度も中間になる
        let result = interpolateAtMeridianLinear(
            from: GeoPoint(latitude: 10, longitude: 170),
            to: GeoPoint(latitude: 20, longitude: -170)
        )
        XCTAssertEqual(result.longitude, 180.0, accuracy: 1e-9)
        XCTAssertEqual(result.latitude, 15.0, accuracy: 1e-9)
    }

    func testWestwardCrossingInterpolatesLatitudeAtMidpoint() {
        let result = interpolateAtMeridianLinear(
            from: GeoPoint(latitude: 10, longitude: -170),
            to: GeoPoint(latitude: 20, longitude: 170)
        )
        XCTAssertEqual(result.longitude, -180.0, accuracy: 1e-9)
        XCTAssertEqual(result.latitude, 15.0, accuracy: 1e-9)
    }

    func testAsymmetricCrossingLatitudeProportionalToShortWaySpan() {
        // 175°E → -165°(=195°E)、横断点 180° は区間の 1/4 地点
        let result = interpolateAtMeridianLinear(
            from: GeoPoint(latitude: 0, longitude: 175),
            to: GeoPoint(latitude: 40, longitude: -165)
        )
        XCTAssertEqual(result.longitude, 180.0, accuracy: 1e-9)
        XCTAssertEqual(result.latitude, 10.0, accuracy: 1e-9)
    }
}
