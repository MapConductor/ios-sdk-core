import UIKit
import XCTest

@testable import MapConductorCore

/// `CameraRestriction` / `CameraRestrictionClamp` が android-sdk と同じ意味論であることを確認する。
///
/// 参照: `android-sdk-core/.../map/CameraRestriction.kt` と
/// `android-sdk-core/.../controller/BaseMapViewController.kt` の
/// `cameraRestrictionCorrection` / `setCameraRestriction` / `hasCameraRestriction`。
final class CameraRestrictionTests: XCTestCase {
    private func bounds(
        south: Double, west: Double, north: Double, east: Double
    ) -> GeoRectBounds {
        GeoRectBounds(
            southWest: GeoPoint(latitude: south, longitude: west),
            northEast: GeoPoint(latitude: north, longitude: east)
        )
    }

    private func camera(lat: Double, lng: Double, zoom: Double) -> MapCameraPosition {
        MapCameraPosition(
            position: GeoPoint(latitude: lat, longitude: lng),
            zoom: zoom
        )
    }

    // MARK: - CameraRestriction

    func testNoneIsEmpty() {
        XCTAssertTrue(CameraRestriction.None.isEmpty)
        XCTAssertTrue(CameraRestriction().isEmpty)
    }

    func testIsEmptyFalseWhenAnyFieldSet() {
        XCTAssertFalse(CameraRestriction(minZoom: 5).isEmpty)
        XCTAssertFalse(CameraRestriction(maxZoom: 18).isEmpty)
        XCTAssertFalse(
            CameraRestriction(bounds: bounds(south: 35, west: 139, north: 36, east: 140)).isEmpty
        )
    }

    /// 空の `GeoRectBounds` しか持たない場合は Android と同じく isEmpty。
    func testIsEmptyWithEmptyBounds() {
        XCTAssertTrue(CameraRestriction(bounds: GeoRectBounds()).isEmpty)
    }

    // MARK: - set / hasRestriction

    /// Android の `restriction?.takeUnless { it.isEmpty }` と同じく、空の制限は保持しない。
    func testSetDropsEmptyRestriction() {
        let clamp = CameraRestrictionClamp()
        XCTAssertFalse(clamp.hasRestriction)

        clamp.set(CameraRestriction.None)
        XCTAssertFalse(clamp.hasRestriction, "空の制限は保持しないこと")

        clamp.set(CameraRestriction(minZoom: 4))
        XCTAssertTrue(clamp.hasRestriction)

        clamp.set(nil)
        XCTAssertFalse(clamp.hasRestriction, "nil で解除されること")
    }

    /// 制限が無ければ常に補正なし。
    func testNoRestrictionMeansNoCorrection() {
        let clamp = CameraRestrictionClamp()
        XCTAssertNil(clamp.correction(for: camera(lat: 0, lng: 0, zoom: 3)))
    }

    // MARK: - zoom clamping

    func testClampsBelowMinZoom() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(minZoom: 10))

        let corrected = clamp.correction(for: camera(lat: 35, lng: 139, zoom: 5))
        XCTAssertEqual(corrected?.zoom, 10)
    }

    func testClampsAboveMaxZoom() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(maxZoom: 16))

        let corrected = clamp.correction(for: camera(lat: 35, lng: 139, zoom: 20))
        XCTAssertEqual(corrected?.zoom, 16)
    }

    func testZoomWithinRangeIsNotCorrected() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(minZoom: 5, maxZoom: 16))
        XCTAssertNil(clamp.correction(for: camera(lat: 35, lng: 139, zoom: 10)))
    }

    /// ε 未満のズレでは補正しない（再適用 → イベント → 再補正の無限ループ防止）。
    func testZoomEpsilonPreventsCorrectionLoop() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(minZoom: 10))

        // 10 - 0.0005 は zoomEps(1e-3) 未満のズレなので補正しない
        XCTAssertNil(clamp.correction(for: camera(lat: 35, lng: 139, zoom: 10 - 0.0005)))
        // 10 - 0.002 は ε を超えるので補正する
        XCTAssertEqual(clamp.correction(for: camera(lat: 35, lng: 139, zoom: 10 - 0.002))?.zoom, 10)
    }

    // MARK: - bounds clamping

    func testClampsCenterIntoBounds() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(bounds: bounds(south: 35, west: 139, north: 36, east: 140)))

        let corrected = clamp.correction(for: camera(lat: 40, lng: 145, zoom: 10))
        XCTAssertEqual(corrected?.position.latitude ?? 0, 36, accuracy: 1e-12)
        XCTAssertEqual(corrected?.position.longitude ?? 0, 140, accuracy: 1e-12)
        XCTAssertEqual(corrected?.zoom, 10, "ズーム制限が無ければズームは変えない")
    }

    func testCenterInsideBoundsIsNotCorrected() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(bounds: bounds(south: 35, west: 139, north: 36, east: 140)))
        XCTAssertNil(clamp.correction(for: camera(lat: 35.5, lng: 139.5, zoom: 10)))
    }

    /// southWest / northEast が逆転していても min/max で正規化される（Android と同じ）。
    func testSwappedCornersAreNormalized() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(bounds: bounds(south: 36, west: 140, north: 35, east: 139)))

        let corrected = clamp.correction(for: camera(lat: 40, lng: 145, zoom: 10))
        XCTAssertEqual(corrected?.position.latitude ?? 0, 36, accuracy: 1e-12)
        XCTAssertEqual(corrected?.position.longitude ?? 0, 140, accuracy: 1e-12)
    }

    /// 座標の ε 未満のズレでは補正しない。
    func testCoordEpsilonPreventsCorrectionLoop() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(bounds: bounds(south: 35, west: 139, north: 36, east: 140)))

        // 36 + 1e-8 は coordEps(1e-7) 未満なので補正しない
        XCTAssertNil(clamp.correction(for: camera(lat: 36 + 1e-8, lng: 139.5, zoom: 10)))
        // 36 + 1e-6 は ε を超えるので補正する
        XCTAssertNotNil(clamp.correction(for: camera(lat: 36 + 1e-6, lng: 139.5, zoom: 10)))
    }

    // MARK: - combined

    func testBoundsAndZoomCorrectedTogether() {
        let clamp = CameraRestrictionClamp()
        clamp.set(
            CameraRestriction(
                bounds: bounds(south: 35, west: 139, north: 36, east: 140),
                minZoom: 8,
                maxZoom: 16
            )
        )

        let corrected = clamp.correction(for: camera(lat: 10, lng: 100, zoom: 20))
        XCTAssertEqual(corrected?.position.latitude ?? 0, 35, accuracy: 1e-12)
        XCTAssertEqual(corrected?.position.longitude ?? 0, 139, accuracy: 1e-12)
        XCTAssertEqual(corrected?.zoom, 16)
    }

    /// 補正結果を再度かけても二度目は補正なし（＝収束する）。
    func testCorrectionConverges() {
        let clamp = CameraRestrictionClamp()
        clamp.set(
            CameraRestriction(
                bounds: bounds(south: 35, west: 139, north: 36, east: 140),
                minZoom: 8,
                maxZoom: 16
            )
        )

        guard let first = clamp.correction(for: camera(lat: 10, lng: 100, zoom: 20)) else {
            return XCTFail("1 回目は補正されるはず")
        }
        XCTAssertNil(clamp.correction(for: first), "2 回目は補正不要になり収束すること")
    }

    /// bearing / tilt など他のカメラ属性は保持される。
    func testCorrectionPreservesOtherCameraFields() {
        let clamp = CameraRestrictionClamp()
        clamp.set(CameraRestriction(minZoom: 10))

        let source = MapCameraPosition(
            position: GeoPoint(latitude: 35, longitude: 139),
            zoom: 5,
            bearing: 45,
            tilt: 30
        )
        let corrected = clamp.correction(for: source)
        XCTAssertEqual(corrected?.bearing, 45)
        XCTAssertEqual(corrected?.tilt, 30)
    }
}
