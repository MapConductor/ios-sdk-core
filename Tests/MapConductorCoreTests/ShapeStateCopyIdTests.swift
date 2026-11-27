import UIKit
import XCTest

@testable import MapConductorCore

/// Circle / Polyline / Polygon / GroundImage の `copy()` は id を引き継がず、新しい中身から
/// 計算し直す（`MarkerState.copy()` と同じ）。描画側は図形を id で区別するので、引き継ぐと
/// copy で増やした図形が元の図形を上書きし、1 つにしか見えなかった。
/// `id` を渡したときだけその id を使う。
final class ShapeStateCopyIdTests: XCTestCase {

    private func p(_ latitude: Double, _ longitude: Double) -> GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    func testCircleCopyRecomputesId() {
        let base = CircleState(center: p(35, 139), radiusMeters: 10, id: "c1")
        let moved = base.copy(center: p(36, 140))

        XCTAssertNotEqual(moved.id, "c1")
        XCTAssertEqual(moved.id, CircleState(center: p(36, 140), radiusMeters: 10).id)
        XCTAssertEqual(base.copy(center: p(36, 140), id: "c1").id, "c1")
    }

    func testPolylineCopyRecomputesId() {
        let base = PolylineState(points: [p(35, 139), p(36, 140)], id: "l1")
        let moved = base.copy(points: [p(35, 139), p(37, 141)])

        XCTAssertNotEqual(moved.id, "l1")
        XCTAssertEqual(moved.id, PolylineState(points: [p(35, 139), p(37, 141)]).id)
        XCTAssertEqual(base.copy(points: [p(35, 139), p(37, 141)], id: "l1").id, "l1")
    }

    func testPolygonCopyRecomputesId() {
        let ring = [p(35, 139), p(35, 140), p(36, 140), p(35, 139)]
        let other = [p(35, 139), p(35, 141), p(37, 141), p(35, 139)]
        let base = PolygonState(points: ring, id: "g1")
        let moved = base.copy(points: other)

        XCTAssertNotEqual(moved.id, "g1")
        XCTAssertEqual(moved.id, PolygonState(points: other).id)
        XCTAssertEqual(base.copy(points: other, id: "g1").id, "g1")
    }

    func testGroundImageCopyRecomputesId() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        let bounds = GeoRectBounds(southWest: p(35, 139), northEast: p(36, 140))
        let otherBounds = GeoRectBounds(southWest: p(37, 141), northEast: p(38, 142))
        let base = GroundImageState(bounds: bounds, image: image, id: "i1")
        let moved = base.copy(bounds: otherBounds)

        XCTAssertNotEqual(moved.id, "i1")
        XCTAssertEqual(moved.id, GroundImageState(bounds: otherBounds, image: image).id)
        XCTAssertEqual(base.copy(bounds: otherBounds, id: "i1").id, "i1")
    }
}
