import XCTest
@testable import MapConductorCore

/// Regression coverage for the centralized `spherical/` module (kept symmetric
/// with android-sdk's `core/spherical`).
final class SphericalRefactorSanityTests: XCTestCase {
    private let tokyo = GeoPoint(latitude: 35.6812, longitude: 139.7671)
    private let osaka = GeoPoint(latitude: 34.6937, longitude: 135.5023)

    func testGeographicLibDistanceMatchesKnownValue() {
        // Tokyo → Osaka is ~400 km on the WGS84 ellipsoid.
        let d = WGS84Geodesic.computeDistanceBetween(from: tokyo, to: osaka)
        XCTAssertEqual(d, 400_000, accuracy: 15_000, "got \(d)")
    }

    func testWGS84GeodesicDelegatesToGeographicLib() {
        XCTAssertEqual(
            WGS84Geodesic.computeDistanceBetween(from: tokyo, to: osaka),
            WGS84Geodesic.computeDistanceBetween(from: tokyo, to: osaka),
            accuracy: 1e-6
        )
    }

    func testGeographicLibInterpolateMidpointRoughlyHalf() {
        let mid = WGS84Geodesic.interpolate(from: tokyo, to: osaka, fraction: 0.5)
        let dHalf = WGS84Geodesic.computeDistanceBetween(from: tokyo, to: mid)
        let dFull = WGS84Geodesic.computeDistanceBetween(from: tokyo, to: osaka)
        XCTAssertEqual(dHalf, dFull / 2.0, accuracy: dFull * 0.01, "got \(dHalf) vs \(dFull / 2)")
    }

    func testCreateInterpolatePointsDensifies() {
        let out = WGS84Geodesic.createInterpolatePoints([tokyo, osaka], maxSegmentLength: 50_000)
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
        let mid = WGS84Geodesic.interpolate(from: tokyo, to: osaka, fraction: 0.5)
        let hit = WGS84Geodesic.pointOnLineOrNull(from: tokyo, to: osaka, position: mid, thresholdMeters: 50)
        XCTAssertNotNil(hit)
        XCTAssertLessThanOrEqual(hit!.1, 50)
    }

    func testPointOnLinearLineOrNullHitAndMiss() {
        let a = GeoPoint(latitude: 35.0, longitude: 139.0)
        let b = GeoPoint(latitude: 35.0, longitude: 140.0)
        let onLine = GeoPoint(latitude: 35.0, longitude: 139.5)
        XCTAssertNotNil(Planar.pointOnLineOrNull(from: a, to: b, position: onLine, thresholdMeters: 50))
        let farOff = GeoPoint(latitude: 36.0, longitude: 139.5)
        XCTAssertNil(Planar.pointOnLineOrNull(from: a, to: b, position: farOff, thresholdMeters: 50))
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

    // MARK: - Spherical-parity methods added to WGS84Geodesic

    private let newYork = GeoPoint(latitude: 40.7128, longitude: -74.0060)

    func testComputeHeadingGeodesicInitialBearing() {
        // Tokyo → New York initial bearing ~25°.
        XCTAssertEqual(WGS84Geodesic.computeHeading(from: tokyo, to: newYork), 25.0, accuracy: 3.0)
    }

    func testComputeOffsetMatchesDistanceAndHeading() {
        let dest = WGS84Geodesic.computeOffset(origin: tokyo, distance: 100_000, heading: 90)
        XCTAssertEqual(WGS84Geodesic.computeDistanceBetween(from: tokyo, to: dest), 100_000, accuracy: 1.0)
        XCTAssertEqual(WGS84Geodesic.computeHeading(from: tokyo, to: dest), 90.0, accuracy: 1e-3)
    }

    func testComputeOffsetOriginApproximatelyInverts() {
        // Same reverse-heading (H+180) approximation as Spherical; residual scales
        // with meridian convergence, so a short 10 km leg returns within ~10 m.
        let dest = WGS84Geodesic.computeOffset(origin: tokyo, distance: 10_000, heading: 90)
        let origin = WGS84Geodesic.computeOffsetOrigin(to: dest, distance: 10_000, heading: 90)
        XCTAssertNotNil(origin)
        XCTAssertLessThan(WGS84Geodesic.computeDistanceBetween(from: tokyo, to: origin!), 100)
    }

    func testComputeLengthSumsSegments() {
        let expected = WGS84Geodesic.computeDistanceBetween(from: tokyo, to: osaka)
            + WGS84Geodesic.computeDistanceBetween(from: osaka, to: newYork)
        XCTAssertEqual(WGS84Geodesic.computeLength([tokyo, osaka, newYork]), expected, accuracy: 1.0)
    }

    func testEllipsoidalAreaMatchesReference() {
        // 1°×1° equatorial cell; matches GeographicLib's geodesic area (~1.23085e10 m²).
        let cell: [GeoPointProtocol] = [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 1, longitude: 0),
            GeoPoint(latitude: 1, longitude: 1),
            GeoPoint(latitude: 0, longitude: 1),
        ]
        XCTAssertEqual(WGS84Geodesic.computeArea(cell), 1.230846e10, accuracy: 1e7)

        let signed = WGS84Geodesic.computeSignedArea(cell)
        XCTAssertEqual(WGS84Geodesic.computeSignedArea(Array(cell.reversed())), -signed, accuracy: 1.0)
        XCTAssertEqual(abs(signed), WGS84Geodesic.computeArea(cell), accuracy: 1e-3)

        // Ellipsoidal area is slightly smaller than the equatorial-sphere version.
        XCTAssertLessThan(WGS84Geodesic.computeArea(cell), Spherical.computeArea(cell))

        // Fewer than 3 points → 0.
        XCTAssertEqual(WGS84Geodesic.computeArea([tokyo, osaka]), 0.0, accuracy: 0.0)
    }
}
