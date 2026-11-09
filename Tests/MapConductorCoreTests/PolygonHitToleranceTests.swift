import XCTest

@testable import MapConductorCore

/// A tap counts as on a polygon's edge only when it is within `eps` (1e-6°,
/// about 0.1 m) of that edge. Taps outside the polygon's bounding box never get
/// that far, so the tolerance only matters on and just inside the outline.
///
/// js-sdk-core の `PolygonHitTolerance.test.mjs`、android-sdk の `PolygonHitToleranceTest` と
/// 1 対 1 で対応する。
///
/// 辺上の判定が度の 2 乗の量（内積）を 1e-6 と比べていて、短い辺から約 100 m 以内の
/// タップをすべて「辺上」として拾っていた。建物の輪郭のように辺が数 m のポリゴンを
/// 並べると、タップした建物ではなく、リストで先にある近所の建物が返る。大きな図形では
/// 起きないので、サンプルの六角形では見えなかった。
final class PolygonHitToleranceTests: XCTestCase {
    // ボストン中心部の、一辺が約 10 m の建物
    private let building: [GeoPointProtocol] = [
        GeoPoint(latitude: 42.3550, longitude: -71.0600),
        GeoPoint(latitude: 42.3550, longitude: -71.0599),
        GeoPoint(latitude: 42.3551, longitude: -71.0599),
        GeoPoint(latitude: 42.3551, longitude: -71.0600),
        GeoPoint(latitude: 42.3550, longitude: -71.0600),
    ]

    private func managerWith(_ states: PolygonState...) -> PolygonManager<Void> {
        let manager = PolygonManager<Void>()
        for state in states {
            manager.registerEntity(PolygonEntity<Void>(polygon: nil, state: state))
        }
        return manager
    }

    func test50mAwayDoesNotHitABuildingWithShortEdges() {
        let manager = managerWith(PolygonState(points: building, id: "small"))
        // 建物の東の辺から東へ約 50 m（経度 0.0006°）
        XCTAssertNil(manager.find(position: GeoPoint(latitude: 42.35505, longitude: -71.0593)))
        // 北へ約 50 m
        XCTAssertNil(manager.find(position: GeoPoint(latitude: 42.3556, longitude: -71.05995)))
    }

    func testInsideAndOnTheEdgeHitButHalfAMetreOutDoesNot() {
        let manager = managerWith(PolygonState(points: building, id: "small"))
        XCTAssertEqual(manager.find(position: GeoPoint(latitude: 42.35505, longitude: -71.05995))?.state.id, "small")
        XCTAssertEqual(
            manager.find(position: GeoPoint(latitude: 42.3550, longitude: -71.05995))?.state.id, "small",
            "南の辺の上"
        )
        XCTAssertNil(
            manager.find(position: GeoPoint(latitude: 42.354995, longitude: -71.05995)),
            "南の辺から外へ約 0.6 m"
        )
    }

    func testReturnsTheTappedBuildingNotItsNeighbour() {
        // 西隣（約 20 m 西）にもう 1 棟。リストでは先に入れる
        let west: [GeoPointProtocol] = building.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude - 0.00025)
        }
        let manager = managerWith(
            PolygonState(points: west, id: "west"),
            PolygonState(points: building, id: "tapped")
        )
        XCTAssertEqual(manager.find(position: GeoPoint(latitude: 42.35505, longitude: -71.05995))?.state.id, "tapped")
    }
}
