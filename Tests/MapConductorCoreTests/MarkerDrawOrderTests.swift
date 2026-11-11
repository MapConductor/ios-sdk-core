import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// マーカー帯の中の重なり順: zIndex → 南 → 西。
final class MarkerDrawOrderTests: XCTestCase {
    private func p(_ lat: Double, _ lng: Double) -> GeoPoint { GeoPoint(latitude: lat, longitude: lng) }

    func testExplicitZIndexBeatsUnsetInBothHemispheres() {
        for lat in [35.68, -33.87, 0.0, 84.9, -84.9] {
            let unset = MarkerDrawOrder.key(zIndex: nil, position: p(lat - 1, 139))
            let raised = MarkerDrawOrder.key(zIndex: 1, position: p(lat, 139))
            XCTAssertGreaterThan(raised, unset, "lat \(lat)")
            let unsetInt = MarkerDrawOrder.integerKey(zIndex: nil, position: p(lat - 1, 139), tieSteps: 1 << 19)
            let raisedInt = MarkerDrawOrder.integerKey(zIndex: 1, position: p(lat, 139), tieSteps: 1 << 19)
            XCTAssertGreaterThan(raisedInt, unsetInt, "lat \(lat)")
        }
    }

    func testLowerZIndexStaysBehindUnset() {
        XCTAssertLessThan(
            MarkerDrawOrder.key(zIndex: -1, position: p(-80, 0)),
            MarkerDrawOrder.key(zIndex: nil, position: p(80, 0))
        )
    }

    func testSouthIsInFrontAtTheSameZIndex() {
        XCTAssertGreaterThan(
            MarkerDrawOrder.key(zIndex: nil, position: p(35.0, 139)),
            MarkerDrawOrder.key(zIndex: nil, position: p(35.0001, 139))
        )
        XCTAssertGreaterThan(
            MarkerDrawOrder.key(zIndex: 3, position: p(-34, 151)),
            MarkerDrawOrder.key(zIndex: 3, position: p(-33.9, 151))
        )
        XCTAssertGreaterThan(
            MarkerDrawOrder.integerKey(zIndex: nil, position: p(35.0, 139), tieSteps: 1 << 19),
            MarkerDrawOrder.integerKey(zIndex: nil, position: p(35.001, 139), tieSteps: 1 << 19)
        )
    }

    func testWestIsInFrontAtTheSameLatitude() {
        XCTAssertGreaterThan(
            MarkerDrawOrder.key(zIndex: nil, position: p(35, 139.0)),
            MarkerDrawOrder.key(zIndex: nil, position: p(35, 139.1))
        )
    }

    func testTieFractionStaysBelowHalf() {
        for point in [p(-90, -180), p(90, 180), p(0, 0), p(-89.999, -179.999)] {
            let key = MarkerDrawOrder.key(zIndex: 2, position: point)
            XCTAssertGreaterThanOrEqual(key, 2.0)
            XCTAssertLessThan(key, 2.5)
            let int = MarkerDrawOrder.integerKey(zIndex: 2, position: point, tieSteps: 100)
            XCTAssertTrue((200..<300).contains(int), "\(int)")
        }
    }

    func testZIndexIsClampedToTheSpan() {
        XCTAssertEqual(
            MarkerDrawOrder.key(zIndex: 1_000_000, position: p(0, 0)),
            MarkerDrawOrder.key(zIndex: MarkerDrawOrder.zIndexSpan, position: p(0, 0))
        )
        let maxInt = MarkerDrawOrder.integerKey(zIndex: Int.max / 2, position: p(-90, -180), tieSteps: 1 << 19)
        XCTAssertLessThan(maxInt, Int(Int32.max))
    }
}
