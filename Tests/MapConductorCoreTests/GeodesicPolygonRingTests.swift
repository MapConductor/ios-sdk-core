import Foundation
import XCTest

@testable import MapConductorCore

/// geodesic ポリゴンの閉じる辺（末尾 → 先頭）も大圏で補間すること。
///
/// js-sdk-core の `GeodesicPolygonRing.test.mjs`、android-sdk の `GeodesicPolygonRingTest` と 1 対 1 で対応する。
///
/// `WGS84Geodesic.createInterpolatePoints` は隣り合う点の間しか補間しない。ポリゴンの点は開いたリング
/// （末尾 ≠ 先頭）で渡されるので、塗りのリングは閉じる辺だけが補間されず直線の弦になっていた。
/// 輪郭はリングを閉じてからポリラインとして密度化するので大圏になり、「輪郭は曲線、塗りの一辺だけ直線」になる。
/// Google のように塗りと輪郭を 1 つのネイティブポリゴンで描くプロバイダは、輪郭まで直線になる。
final class GeodesicPolygonRingTests: XCTestCase {
    private let boston = GeoPoint(latitude: 42.36, longitude: -71.06)
    private let london = GeoPoint(latitude: 51.5, longitude: -0.12)
    private let iceland = GeoPoint(latitude: 64.1, longitude: -21.9)

    // 実機検証と同じ順序。閉じる辺は アイスランド → ボストン。
    private var triangle: [GeoPointProtocol] { [boston, london, iceland] }

    private func same(_ a: GeoPointProtocol, _ b: GeoPointProtocol) -> Bool {
        abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
    }

    private func assertSamePoints(
        _ expected: [GeoPointProtocol],
        _ actual: [GeoPointProtocol],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(expected.count, actual.count, file: file, line: line)
        guard expected.count == actual.count else { return }
        for i in expected.indices where !same(expected[i], actual[i]) {
            XCTFail("point \(i): \(actual[i]) != \(expected[i])", file: file, line: line)
            return
        }
    }

    /// 輪郭（閉じたリングをポリラインとして密度化）から、末尾の重複点を除いたもの。
    private func outlineOf(_ points: [GeoPointProtocol], geodesic: Bool) -> [GeoPointProtocol] {
        Array(buildUnwrappedPolylinePath(points + [points[0]], geodesic: geodesic).dropLast())
    }

    func testGreatCircleMidpointBostonToIcelandBulgesNorthwestByAboutFourDegrees() {
        let mid = WGS84Geodesic.interpolate(from: boston, to: iceland, fraction: 0.5)
        // Web メルカトルでの直線（弦）が同じ経度で通る緯度。
        func merc(_ lat: Double) -> Double { log(tan(Double.pi / 4 + lat * Double.pi / 360)) }
        let t = (mid.longitude - boston.longitude) / (iceland.longitude - boston.longitude)
        let y = merc(boston.latitude) + t * (merc(iceland.latitude) - merc(boston.latitude))
        let chordLat = (2 * atan(exp(y)) - Double.pi / 2) * 180 / Double.pi
        XCTAssertEqual(mid.latitude, 55.63, accuracy: 0.05)
        XCTAssertEqual(chordLat, 51.6, accuracy: 0.05)
    }

    func testDensifyGeodesicRingInterpolatesClosingEdgeAndKeepsRingOpen() {
        let ring = densifyGeodesicRing(triangle)
        XCTAssertTrue(same(boston, ring[0]))
        // 先頭の重複点を末尾に付けない（閉じて補間した結果から末尾の 1 点だけを除いた長さ）。
        // createInterpolatePoints は分割比を足し込むため、末尾の手前に終点とほぼ同じ点が残ることがある。
        XCTAssertEqual(WGS84Geodesic.createInterpolatePoints(triangle + [boston]).count - 1, ring.count)
        let expected = WGS84Geodesic.createInterpolatePoints([iceland, boston])
        assertSamePoints(Array(expected.dropFirst().dropLast()), Array(ring.suffix(expected.count - 2)))
    }

    func testDensifyGeodesicRingKeepsClosedRingClosed() {
        let closed = triangle + [boston]
        assertSamePoints(WGS84Geodesic.createInterpolatePoints(closed), densifyGeodesicRing(closed))
    }

    func testUnwrappedGeodesicFillMatchesOutline() {
        let fill = buildUnwrappedPolygonRings(points: triangle, holes: [], geodesic: true).outerRings[0]
        assertSamePoints(outlineOf(triangle, geodesic: true), fill)
        let mid = WGS84Geodesic.interpolate(from: iceland, to: boston, fraction: 0.5)
        let nearest = fill.map { hypot($0.latitude - mid.latitude, $0.longitude - mid.longitude) }.min() ?? .infinity
        XCTAssertLessThan(nearest, 0.1)
    }

    func testSplitGeodesicFillInterpolatesClosingEdge() {
        let rings = buildPolygonRings(points: triangle, holes: [], geodesic: true).outerRings
        XCTAssertEqual(rings.count, 1)
        assertSamePoints(outlineOf(triangle, geodesic: true), rings[0])
    }

    func testNonGeodesicFillIsUnchanged() {
        let legacy = Planar.createInterpolatePoints(triangle).map { $0.normalize() }
        let fill = buildUnwrappedPolygonRings(points: triangle, holes: [], geodesic: false).outerRings[0]
        assertSamePoints(legacy, fill)
        XCTAssertTrue(same(iceland, fill[fill.count - 1]))
        assertSamePoints(legacy, buildPolygonRings(points: triangle, holes: [], geodesic: false).outerRings[0])
    }

    func testGeodesicHolesInterpolateClosingEdge() {
        let outer: [GeoPointProtocol] = [
            GeoPoint(latitude: 30.0, longitude: -80.0),
            GeoPoint(latitude: 30.0, longitude: 10.0),
            GeoPoint(latitude: 70.0, longitude: 10.0),
            GeoPoint(latitude: 70.0, longitude: -80.0),
        ]
        let hole = triangle
        let unwrapped = buildUnwrappedPolygonRings(points: outer, holes: [hole], geodesic: true)
        assertSamePoints(outlineOf(hole, geodesic: true), unwrapped.holeRings[0])
        assertSamePoints(outlineOf(outer, geodesic: true), unwrapped.outerRings[0])
        assertSamePoints(
            outlineOf(hole, geodesic: true),
            buildPolygonRings(points: outer, holes: [hole], geodesic: true).holeRings[0]
        )
        assertSamePoints(
            Planar.createInterpolatePoints(hole).map { $0.normalize() },
            buildUnwrappedPolygonRings(points: outer, holes: [hole], geodesic: false).holeRings[0]
        )
    }

    func testHitTestFollowsGreatCircleOnClosingEdge() {
        // 弦と大圏の間（北西へ膨らんだ部分）の点。
        let mid = WGS84Geodesic.interpolate(from: iceland, to: boston, fraction: 0.5)
        let t = (mid.longitude - iceland.longitude) / (boston.longitude - iceland.longitude)
        let chordLat = iceland.latitude + t * (boston.latitude - iceland.latitude)
        let bulge = GeoPoint(latitude: (mid.latitude + chordLat) / 2, longitude: mid.longitude)

        let manager = PolygonManager<Int>()
        let state = PolygonState(points: triangle, id: "g", geodesic: true)
        manager.registerEntity(PolygonEntity(polygon: 0, state: state))
        XCTAssertEqual(manager.find(position: bulge)?.state.id, "g")

        state.geodesic = false
        XCTAssertNil(manager.find(position: bulge))
    }
}
