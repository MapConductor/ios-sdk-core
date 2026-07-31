import XCTest
@testable import MapConductorCore

/// Regression coverage for the centralized `spherical/` module (kept symmetric
/// with android-sdk's `core/spherical`).
final class SphericalRefactorSanityTests: XCTestCase {
    private let tokyo = GeoPoint(latitude: 35.6812, longitude: 139.7671)
    private let osaka = GeoPoint(latitude: 34.6937, longitude: 135.5023)

    func testGeographicLibDistanceMatchesKnownValue() {
        // Tokyo → Osaka is ~400 km on the WGS84 ellipsoid.
        let d = GeographicLibCalculator.computeDistanceBetween(from: tokyo, to: osaka)
        XCTAssertEqual(d, 400_000, accuracy: 15_000, "got \(d)")
    }

    func testWGS84GeodesicDelegatesToGeographicLib() {
        XCTAssertEqual(
            WGS84Geodesic.computeDistanceBetween(from: tokyo, to: osaka),
            GeographicLibCalculator.computeDistanceBetween(from: tokyo, to: osaka),
            accuracy: 1e-6
        )
    }

    func testGeographicLibInterpolateMidpointRoughlyHalf() {
        let mid = GeographicLibCalculator.interpolate(from: tokyo, to: osaka, fraction: 0.5)
        let dHalf = GeographicLibCalculator.computeDistanceBetween(from: tokyo, to: mid)
        let dFull = GeographicLibCalculator.computeDistanceBetween(from: tokyo, to: osaka)
        XCTAssertEqual(dHalf, dFull / 2.0, accuracy: dFull * 0.01, "got \(dHalf) vs \(dFull / 2)")
    }

    func testCreateInterpolatePointsDensifies() {
        let out = createInterpolatePoints([tokyo, osaka], maxSegmentLength: 50_000)
        XCTAssertGreaterThan(out.count, 5)
        XCTAssertEqual(out.first!.latitude, tokyo.latitude, accuracy: 1e-9)
        XCTAssertEqual(out.last!.latitude, osaka.latitude, accuracy: 1e-9)
    }

    func testSplitByMeridianAcrossAntimeridian() {
        let a = GeoPoint(latitude: 0, longitude: 170)
        let b = GeoPoint(latitude: 0, longitude: -170)
        let groups = splitByMeridian([a, b], geodesic: false)
        XCTAssertEqual(groups.count, 2, "expected split into two fragments")
        // Each fragment should end/start at ±180.
        XCTAssertEqual(abs(groups[0].last!.longitude), 180, accuracy: 1e-6)
        XCTAssertEqual(abs(groups[1].first!.longitude), 180, accuracy: 1e-6)
    }

    func testPointOnGeodesicSegmentHit() {
        // A point essentially on the Tokyo→Osaka geodesic midpoint should register.
        let mid = GeographicLibCalculator.interpolate(from: tokyo, to: osaka, fraction: 0.5)
        let hit = pointOnGeodesicSegmentOrNull(from: tokyo, to: osaka, position: mid, thresholdMeters: 50)
        XCTAssertNotNil(hit)
        XCTAssertLessThanOrEqual(hit!.1, 50)
    }

    func testIsPointOnLinearLineHitAndMiss() {
        let a = GeoPoint(latitude: 35.0, longitude: 139.0)
        let b = GeoPoint(latitude: 35.0, longitude: 140.0)
        let onLine = GeoPoint(latitude: 35.0, longitude: 139.5)
        XCTAssertNotNil(isPointOnLinearLine(from: a, to: b, position: onLine, thresholdMeters: 50))
        let farOff = GeoPoint(latitude: 36.0, longitude: 139.5)
        XCTAssertNil(isPointOnLinearLine(from: a, to: b, position: farOff, thresholdMeters: 50))
    }

    func testClosestPointOnSegmentClampsToEndpoints() {
        let p = closestPointOnSegment(
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 10, y: 0),
            testPoint: CGPoint(x: -5, y: 5)
        )
        XCTAssertEqual(p.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0, accuracy: 1e-9)
    }

    func testExpandBoundsGrows() {
        let bounds = GeoRectBounds()
        bounds.extend(point: GeoPoint(latitude: 10, longitude: 10))
        bounds.extend(point: GeoPoint(latitude: 20, longitude: 20))
        let expanded = expandBounds(bounds: bounds, margin: 1.0) // +100%
        XCTAssertLessThan(expanded.southWest!.latitude, 10)
        XCTAssertGreaterThan(expanded.northEast!.latitude, 20)
    }

    func testCalculateMetersPerPixelDecreasesWithZoom() {
        let z5 = calculateMetersPerPixel(latitude: 35, zoom: 5)
        let z10 = calculateMetersPerPixel(latitude: 35, zoom: 10)
        XCTAssertGreaterThan(z5, z10)
    }
}
