import XCTest

@testable import MapConductorCore

/// android-sdk の CircleGeometryTest / SplitRingByMeridianTest / OverlayGeometryTest
/// （unwrap 版）と同じケースを検証する。
final class GeometryPipelineTests: XCTestCase {
    private let tokyo = GeoPoint(latitude: 35.68, longitude: 139.76)
    private let newYork = GeoPoint(latitude: 40.71, longitude: -74.0)

    // MARK: - circleToRing

    func testGeodesicRingPointsAreEquidistantFromCenter() {
        let radius = 50_000.0
        let ring = circleToRing(center: tokyo, radiusMeters: radius, geodesic: true)
        XCTAssertEqual(ring.count, defaultCircleSegments)
        for p in ring {
            XCTAssertEqual(Spherical.computeDistanceBetween(from: tokyo, to: p), radius, accuracy: 1.0)
        }
    }

    func testPlanarRingApproximatesRadiusAtMidLatitude() {
        let radius = 10_000.0
        let ring = circleToRing(center: tokyo, radiusMeters: radius, geodesic: false)
        XCTAssertEqual(ring.count, defaultCircleSegments)
        for p in ring {
            let d = GeographicLibCalculator.computeDistanceBetween(from: tokyo, to: p)
            XCTAssertTrue(d >= radius * 0.99 && d <= radius * 1.01, "distance=\(d)")
        }
    }

    func testRingNearAntimeridianIsUnwrappedAndContinuous() {
        let center = GeoPoint(latitude: 21.3, longitude: -157.85)
        let ring = circleToRing(center: center, radiusMeters: 2_800_000.0, geodesic: true)
        XCTAssertFalse(ring.isEmpty)
        for i in 0 ..< ring.count - 1 {
            let diff = abs(ring[i + 1].longitude - ring[i].longitude)
            XCTAssertTrue(diff < 180.0, "jump=\(diff)")
        }
    }

    func testNormalizedAndSplitRingStaysWithinLongitudeRange() {
        let center = GeoPoint(latitude: 21.3, longitude: -157.85)
        let normalized = circleToRing(center: center, radiusMeters: 2_800_000.0, geodesic: true)
            .map { $0.normalize() }
        let fragments = splitRingByMeridian(normalized, geodesic: true)
        XCTAssertFalse(fragments.isEmpty)
        for fragment in fragments {
            for p in fragment {
                XCTAssertTrue(p.longitude >= -180.0 && p.longitude <= 180.0, "lng=\(p.longitude)")
            }
        }
    }

    func testCircleDegenerateInputsReturnEmpty() {
        XCTAssertTrue(circleToRing(center: tokyo, radiusMeters: 0.0, geodesic: true).isEmpty)
        XCTAssertTrue(circleToRing(center: tokyo, radiusMeters: -1.0, geodesic: false).isEmpty)
        XCTAssertTrue(circleToRing(center: tokyo, radiusMeters: 100.0, geodesic: true, segments: 2).isEmpty)
    }

    // MARK: - splitRingByMeridian

    func testNonCrossingRingReturnsSingleFragmentUnchanged() {
        let ring = circleToRing(center: GeoPoint(latitude: 35.0, longitude: 139.0), radiusMeters: 10_000.0, geodesic: true)
            .map { $0.normalize() }
        let fragments = splitRingByMeridian(ring, geodesic: true)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].count, ring.count)
    }

    func testAntimeridianCrossingCircleSplitsIntoExactlyTwoPieces() {
        let ring = circleToRing(center: GeoPoint(latitude: 10.0, longitude: 178.0), radiusMeters: 500_000.0, geodesic: true)
            .map { $0.normalize() }
        let fragments = splitRingByMeridian(ring, geodesic: true)
        XCTAssertEqual(fragments.count, 2)
        for fragment in fragments {
            XCTAssertTrue(fragment.count >= 3)
            for i in 0 ..< fragment.count - 1 {
                XCTAssertTrue(abs(fragment[i + 1].longitude - fragment[i].longitude) <= 180.0)
            }
        }
        // 全頂点数 = 元リング + 交差ごとの挿入点（2 交差 × 2 点）
        XCTAssertEqual(fragments.reduce(0) { $0 + $1.count }, ring.count + 4)
    }

    // MARK: - unwrap パイプライン

    // MARK: - 分割版パイプライン + OverlayGeoJson（±180 制約 SDK 向け・android 互換）

    func testSplitPolylineSegmentsAcrossAntimeridian() {
        let segments = buildPolylineSegments([tokyo, newYork], geodesic: true)
        XCTAssertGreaterThanOrEqual(segments.count, 2) // 太平洋横断で分割される
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.count, 2)
            for i in 0 ..< segment.count - 1 {
                XCTAssertTrue(abs(segment[i + 1].longitude - segment[i].longitude) <= 180.0)
            }
        }
    }

    func testSplitPolygonRingsDropsHolesWhenOuterSplits() {
        let outer: [GeoPointProtocol] = [
            GeoPoint(latitude: 10.0, longitude: 170.0),
            GeoPoint(latitude: 10.0, longitude: -170.0),
            GeoPoint(latitude: 20.0, longitude: -170.0),
            GeoPoint(latitude: 20.0, longitude: 170.0),
        ]
        let hole: [GeoPointProtocol] = [
            GeoPoint(latitude: 14.0, longitude: 178.0),
            GeoPoint(latitude: 14.0, longitude: 179.0),
            GeoPoint(latitude: 15.0, longitude: 179.0),
        ]
        let rings = buildPolygonRings(points: outer, holes: [hole], geodesic: false)
        XCTAssertGreaterThanOrEqual(rings.outerRings.count, 2)
        XCTAssertTrue(rings.holeRings.isEmpty) // 外周分割時は穴を含めない
    }

    func testOverlayGeoJsonMatchesLegacyFormat() {
        let segments = buildPolylineSegments([tokyo, newYork], geodesic: true)
        let coords = segments.map { seg in
            "[" + seg.map { "[\($0.longitude),\($0.latitude)]" }.joined(separator: ",") + "]"
        }.joined(separator: ",")
        let expected = "{\"type\":\"Feature\",\"geometry\":"
            + "{\"type\":\"MultiLineString\",\"coordinates\":[\(coords)]},\"properties\":{}}"
        XCTAssertEqual(OverlayGeoJson.multiLineStringFeature(segments), expected)
        XCTAssertNil(OverlayGeoJson.multiLineStringFeature([]))
        XCTAssertNil(OverlayGeoJson.polygonFeature(PolygonRings(outerRings: [], holeRings: [])))
    }

    func testUnwrappedPolylineAntimeridianCrossingIsSingleContinuousPath() {
        let path = buildUnwrappedPolylinePath([tokyo, newYork], geodesic: true)
        XCTAssertTrue(path.count >= 2)
        for i in 0 ..< path.count - 1 {
            let diff = abs(path[i + 1].longitude - path[i].longitude)
            XCTAssertTrue(diff < 180.0, "jump=\(diff)")
        }
    }

    func testUnwrappedPolygonAntimeridianCrossingKeepsSingleOuterAndHoles() {
        let outer: [GeoPointProtocol] = [
            GeoPoint(latitude: 10.0, longitude: 170.0),
            GeoPoint(latitude: 10.0, longitude: -170.0),
            GeoPoint(latitude: 20.0, longitude: -170.0),
            GeoPoint(latitude: 20.0, longitude: 170.0),
        ]
        let hole: [GeoPointProtocol] = [
            GeoPoint(latitude: 14.0, longitude: -178.0),
            GeoPoint(latitude: 14.0, longitude: -176.0),
            GeoPoint(latitude: 16.0, longitude: -176.0),
            GeoPoint(latitude: 16.0, longitude: -178.0),
        ]
        let rings = buildUnwrappedPolygonRings(points: outer, holes: [hole], geodesic: false)
        XCTAssertEqual(rings.outerRings.count, 1)
        XCTAssertEqual(rings.holeRings.count, 1)

        let outerRing = rings.outerRings[0]
        for i in 0 ..< outerRing.count - 1 {
            XCTAssertTrue(abs(outerRing[i + 1].longitude - outerRing[i].longitude) < 180.0)
        }
        // 穴は外周と同じ連続座標系に配置される（外周の経度範囲内に収まる）
        let outerMin = outerRing.map(\.longitude).min()!
        let outerMax = outerRing.map(\.longitude).max()!
        for p in rings.holeRings[0] {
            XCTAssertTrue(p.longitude >= outerMin && p.longitude <= outerMax, "hole lng=\(p.longitude)")
        }
    }

    func testCloseRingAppendsFirstPointOnlyWhenOpen() {
        let open: [GeoPointProtocol] = [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 1, longitude: 1),
            GeoPoint(latitude: 1, longitude: 0),
        ]
        let closed = closeRing(open)
        XCTAssertEqual(closed.count, 4)
        XCTAssertEqual(closed.last!.latitude, 0)
        XCTAssertEqual(closeRing(closed).count, 4)
        XCTAssertTrue(closeRing([]).isEmpty)
    }
}
