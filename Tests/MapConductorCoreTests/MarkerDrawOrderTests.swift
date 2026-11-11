import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// マーカー帯の中の重なり順: zIndex → 回したあとの画面で下 → 左（北が上なら南 → 西）。
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

    // ── 地図の向き ─────────────────────────────────────────────

    private func frame(_ heading: Double, origin: Double = 139) -> MarkerDrawOrder.Frame {
        MarkerDrawOrder.Frame(headingDegrees: heading, originLongitude: origin)
    }

    private func front(_ a: GeoPoint, _ b: GeoPoint, _ f: MarkerDrawOrder.Frame) -> GeoPoint {
        MarkerDrawOrder.key(zIndex: nil, position: a, frame: f) > MarkerDrawOrder.key(zIndex: nil, position: b, frame: f) ? a : b
    }

    func testNorthUpFrameKeepsTheSameOrderAsTheDefault() {
        let points = [p(35, 139), p(35.01, 139), p(35, 139.01), p(-33.9, 151.2), p(0, -179.9), p(60, 10)]
        let byDefault = points.sorted { MarkerDrawOrder.key(zIndex: nil, position: $0) < MarkerDrawOrder.key(zIndex: nil, position: $1) }
        let byFrame = points.sorted {
            MarkerDrawOrder.key(zIndex: nil, position: $0, frame: frame(0, origin: 0))
                < MarkerDrawOrder.key(zIndex: nil, position: $1, frame: frame(0, origin: 0))
        }
        XCTAssertEqual(byDefault.map(\.latitude), byFrame.map(\.latitude))
        XCTAssertEqual(byDefault.map(\.longitude), byFrame.map(\.longitude))
    }

    func testLowerOnScreenIsInFrontAtEveryHeading() {
        let north = p(35.01, 139), south = p(35, 139), east = p(35, 139.01), west = p(35, 139)
        // 0°: 南が下。
        XCTAssertEqual(front(north, south, frame(0)).latitude, 35)
        // 90°（東が上）: 西が下。
        XCTAssertEqual(front(east, west, frame(90)).longitude, 139)
        // 180°（南が上）: 北が下。
        XCTAssertEqual(front(north, south, frame(180)).latitude, 35.01)
        // 270°（西が上）: 東が下。
        XCTAssertEqual(front(east, west, frame(270)).longitude, 139.01)
    }

    func testSameScreenRowFallsBackToLeft() {
        // 90°（東が上）では北が左。南北に並んだ 2 つは同じ高さになり、左（北）が手前。
        let north = p(35.01, 139), south = p(35, 139)
        XCTAssertEqual(front(north, south, frame(90)).latitude, 35.01)
        // 270°（西が上）では南が左。
        XCTAssertEqual(front(north, south, frame(270)).latitude, 35)
    }

    func testZIndexWinsAtEveryHeading() {
        for heading in stride(from: 0.0, to: 360.0, by: 15.0) {
            for (a, b) in [(p(35, 139), p(35.01, 139)), (p(-34, 151), p(-33.9, 151.1)), (p(0, 179.99), p(0, -179.99))] {
                let raised = MarkerDrawOrder.key(zIndex: 1, position: a, frame: frame(heading))
                let unset = MarkerDrawOrder.key(zIndex: nil, position: b, frame: frame(heading))
                XCTAssertGreaterThan(raised, unset, "heading \(heading)")
                let raisedInt = MarkerDrawOrder.integerKey(zIndex: 1, position: a, tieSteps: 1 << 19, frame: frame(heading))
                let unsetInt = MarkerDrawOrder.integerKey(zIndex: nil, position: b, tieSteps: 1 << 19, frame: frame(heading))
                XCTAssertGreaterThan(raisedInt, unsetInt, "heading \(heading)")
                let fraction = MarkerDrawOrder.key(zIndex: 0, position: b, frame: frame(heading))
                XCTAssertTrue((0.0..<0.5).contains(fraction), "\(fraction)")
            }
        }
    }

    func testAntimeridianUsesTheOriginLongitude() {
        // 180° 経線をまたいだ 2 つ。179.99E は 179.99W の 0.02° 西。
        let westOfLine = p(0, 179.99), eastOfLine = p(0, -179.99)
        // 90°（東が上）: 西にある方が下 → 手前。
        XCTAssertEqual(front(westOfLine, eastOfLine, frame(90, origin: 180)).longitude, 179.99)
        // 270°（西が上）: 東にある方が下。
        XCTAssertEqual(front(westOfLine, eastOfLine, frame(270, origin: 180)).longitude, -179.99)
    }

    func testNeedsReorderIgnoresSmallTurnsAndPans() {
        XCTAssertFalse(MarkerDrawOrder.Frame.northUp.needsReorder(from: .northUp))
        XCTAssertFalse(frame(0.3).needsReorder(from: frame(0)))
        XCTAssertTrue(frame(0.6).needsReorder(from: frame(0)))
        XCTAssertFalse(frame(10, origin: 0).needsReorder(from: frame(10, origin: 90)))
        XCTAssertFalse(frame(359.8).needsReorder(from: frame(0.1)))
        XCTAssertTrue(frame(180).needsReorder(from: nil))
    }

    func testFrameFromCameraConvertsBearingToHeading() {
        // MapConductor の bearing は地図の回転角。90 なら画面の上が西（heading 270）。
        let camera = MapCameraPosition(position: p(35, 139), zoom: 10, bearing: 90)
        XCTAssertEqual(MarkerDrawOrder.Frame(camera: camera).headingDegrees, 270, accuracy: 1e-9)
        XCTAssertEqual(MarkerDrawOrder.Frame(camera: camera).originLongitude, 139, accuracy: 1e-9)
    }
}
