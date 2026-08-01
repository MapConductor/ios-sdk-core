import XCTest

@testable import MapConductorCore

final class MapConductorCoreTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertTrue(true)
    }

    func testParsesStandardTileCoordinate() {
        XCTAssertEqual(parseTileCoordinate("100.png"), TileCoordinate(y: 100, pixelRatio: 1))
    }

    func testParsesTomTomRetinaTileCoordinate() {
        XCTAssertEqual(parseTileCoordinate("100@2x.png"), TileCoordinate(y: 100, pixelRatio: 2))
    }

    func testRejectsInvalidTileCoordinate() {
        XCTAssertNil(parseTileCoordinate("tile@2x.png"))
        XCTAssertNil(parseTileCoordinate("100@4x.png"))
    }

    /// The overlay bounce easing must match AOSP's BounceInterpolator, which
    /// the Android SDK uses for `MarkerAnimation.Bounce`.
    @MainActor
    func testBounceInterpolationMatchesAndroidBounceInterpolator() {
        func aosp(_ input: Double) -> Double {
            func bounce(_ t: Double) -> Double { 8.0 * t * t }
            let t = input * 1.1226
            if t < 0.3535 { return bounce(t) }
            if t < 0.7408 { return bounce(t - 0.54719) + 0.7 }
            if t < 0.9644 { return bounce(t - 0.8526) + 0.9 }
            return bounce(t - 1.0435) + 0.95
        }
        for i in 0...20 {
            let t = Double(i) / 20.0
            XCTAssertEqual(
                Double(MarkerAnimationOverlayCoordinator.bounceInterpolation(CGFloat(t))),
                aosp(t),
                accuracy: 1e-9,
                "bounce easing diverges from AOSP at t=\(t)"
            )
        }
        XCTAssertEqual(Double(MarkerAnimationOverlayCoordinator.bounceInterpolation(0)), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(MarkerAnimationOverlayCoordinator.bounceInterpolation(1)), 1, accuracy: 0.01)
    }
}
