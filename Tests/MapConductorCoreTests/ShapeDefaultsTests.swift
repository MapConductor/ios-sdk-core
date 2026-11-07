import UIKit
import XCTest
@testable import MapConductorCore

/// 図形・地表画像の既定値。コンポーネント形（`Circle(center:...)` など）と state 形で
/// 同じ値になるよう 3 プラットフォームで揃えている:
/// Circle / Polygon / Polyline の strokeWidth = 1、GroundImage の opacity = 1.0。
/// js-sdk-core の `ShapeDefaults.test.mjs`、android-sdk の `ShapeDefaultsTest` と同じ観点。
final class ShapeDefaultsTests: XCTestCase {
    private let p1 = GeoPoint(latitude: 35.0, longitude: 139.0)
    private let p2 = GeoPoint(latitude: 35.0, longitude: 140.0)
    private let p3 = GeoPoint(latitude: 36.0, longitude: 140.0)

    func testCircleStrokeWidthDefaultsTo1() {
        XCTAssertEqual(CircleState(center: p1, radiusMeters: 100).strokeWidth, 1.0)
        XCTAssertEqual(Circle(center: p1, radiusMeters: 100).state.strokeWidth, 1.0)
    }

    func testPolygonStrokeWidthDefaultsTo1() {
        XCTAssertEqual(PolygonState(points: [p1, p2, p3]).strokeWidth, 1.0)
        XCTAssertEqual(Polygon(points: [p1, p2, p3]).state.strokeWidth, 1.0)
    }

    func testPolylineStrokeWidthDefaultsTo1() {
        XCTAssertEqual(PolylineState(points: [p1, p2]).strokeWidth, 1.0)
        XCTAssertEqual(Polyline(points: [p1, p2]).state.strokeWidth, 1.0)
    }

    func testGroundImageOpacityDefaultsTo1() {
        let bounds = GeoRectBounds(southWest: p1, northEast: p3)
        let image = UIImage()
        XCTAssertEqual(GroundImageState(bounds: bounds, image: image).opacity, 1.0)
        XCTAssertEqual(GroundImage(bounds: bounds, image: image).state.opacity, 1.0)
    }
}
