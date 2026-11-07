import XCTest
@testable import MapConductorCore

/// computeSignedArea の符号の約束: 北が上の地図で時計回りのリングが正、反時計回りが負。
/// js-sdk-core の `SignedAreaSign.test.mjs`、android-sdk の `SignedAreaSignTest` と同じ観点。
final class SignedAreaSignTests: XCTestCase {
    private let sw = GeoPoint(latitude: 35.0, longitude: 139.0)
    private let se = GeoPoint(latitude: 35.0, longitude: 140.0)
    private let ne = GeoPoint(latitude: 36.0, longitude: 140.0)
    private let nw = GeoPoint(latitude: 36.0, longitude: 139.0)

    private func check(_ signedArea: ([GeoPointProtocol]) -> Double, file: StaticString = #filePath, line: UInt = #line) {
        let cw = signedArea([sw, nw, ne, se])
        let ccw = signedArea([sw, se, ne, nw])
        XCTAssertGreaterThan(cw, 0, file: file, line: line)
        XCTAssertLessThan(ccw, 0, file: file, line: line)
        XCTAssertEqual(cw, -ccw, accuracy: 1e-3, file: file, line: line)
    }

    func testSphericalClockwiseIsPositive() {
        check(Spherical.computeSignedArea)
    }

    func testWGS84GeodesicClockwiseIsPositive() {
        check(WGS84Geodesic.computeSignedArea)
    }
}
