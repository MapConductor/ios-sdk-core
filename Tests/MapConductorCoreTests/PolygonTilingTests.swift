import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// ポリゴンのタイル描画を支える部品。js-sdk-core の `PolygonTiling.test.mjs`、
/// android-sdk の `PolygonTilingTest` と 1 対 1 で対応する。
///
/// - しきい値: ポリゴン数か頂点数のどちらかが届けばタイル。判定はここ 1 か所。
/// - 穴のユニオンの近道: 交わらない穴は計算しない。道路網の区画（穴 80 個・穴の頂点
///   8,000）で 1 個数秒かかっていた二乗の計算を、交わる穴があるときだけに絞る。
///
/// web の Encoded Polyline のテストに当たるものは無い。ネイティブはタイル描画が同じ
/// プロセスにあり、座標を文字列にして渡さない。
final class PolygonTilingTests: XCTestCase {
    private func square(_ lat: Double, _ lng: Double, _ size: Double) -> [GeoPointProtocol] {
        [
            GeoPoint(latitude: lat, longitude: lng),
            GeoPoint(latitude: lat, longitude: lng + size),
            GeoPoint(latitude: lat + size, longitude: lng + size),
            GeoPoint(latitude: lat + size, longitude: lng),
        ]
    }

    func testTilesOnceEitherThePolygonOrTheVertexCountIsReached() {
        let o = PolygonTilingOptions.Default
        XCTAssertFalse(o.shouldUseTiles(polygonCount: 1999, vertexCount: 49_999))
        XCTAssertTrue(o.shouldUseTiles(polygonCount: 2000, vertexCount: 0))
        XCTAssertTrue(o.shouldUseTiles(polygonCount: 10, vertexCount: 50_000))
        XCTAssertFalse(PolygonTilingOptions.Disabled.shouldUseTiles(polygonCount: 100_000, vertexCount: 10_000_000))
    }

    func testDisjointHolesComeBackAsTheyAreWithoutTheUnion() throws {
        let holes = [square(0, 0, 1), square(0, 2, 1), square(2, 0, 1)]
        let result = try XCTUnwrap(unionHoleRings(holes))
        XCTAssertEqual(result.count, 3)
        // 同じ点の集合（向きは時計回りにそろえる）。
        for (out, input) in zip(result, holes) {
            XCTAssertEqual(Set(out.map { "\($0.latitude),\($0.longitude)" }),
                           Set(input.map { "\($0.latitude),\($0.longitude)" }))
        }
    }

    func testOverlappingNestedAndTouchingHolesAreStillMergedIntoOne() throws {
        XCTAssertEqual(try XCTUnwrap(unionHoleRings([square(0, 0, 2), square(1, 1, 2)])).count, 1, "重なる")
        XCTAssertEqual(try XCTUnwrap(unionHoleRings([square(0, 0, 4), square(1, 1, 1)])).count, 1, "中に入った")
        XCTAssertEqual(try XCTUnwrap(unionHoleRings([square(0, 0, 1), square(0, 1, 1)])).count, 1, "辺で接する")
    }

    func testManyDisjointHolesAreFast() throws {
        // 穴 80 個 x 100 頂点
        var holes: [[GeoPointProtocol]] = []
        for i in 0..<80 {
            let cx = Double(i % 10) * 3, cy = Double(i / 10) * 3
            holes.append((0..<100).map { k in
                let a = 2 * Double.pi * Double(k) / 100
                return GeoPoint(latitude: cy + sin(a), longitude: cx + cos(a))
            })
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try XCTUnwrap(unionHoleRings(holes))
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertEqual(result.count, 80)
        XCTAssertLessThan(ms, 200, String(format: "%.1f ms", ms))
    }

    func testOnlyNonGeodesicPolygonsNarrowerThanHalfTheWorldAreTiled() {
        XCTAssertTrue(PolygonTileSet.canTile(PolygonState(points: square(42, -71, 0.001))))
        XCTAssertFalse(PolygonTileSet.canTile(PolygonState(points: square(42, -71, 0.001), geodesic: true)))
        XCTAssertFalse(PolygonTileSet.canTile(PolygonState(points: [
            GeoPoint(latitude: 0, longitude: -100), GeoPoint(latitude: 0, longitude: 100), GeoPoint(latitude: 10, longitude: 0),
        ])))
        XCTAssertFalse(PolygonTileSet.canTile(PolygonState(points: Array(square(0, 0, 1).prefix(2)))))
        XCTAssertEqual(PolygonTileSet.vertexCount([
            PolygonState(points: square(0, 0, 3), holes: [square(1, 1, 1)]),
            PolygonState(points: square(5, 5, 1)),
        ]), 12)
    }
}
