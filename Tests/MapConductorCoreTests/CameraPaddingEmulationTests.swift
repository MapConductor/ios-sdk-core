import CoreGraphics
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// パディングの再現で、ターゲットが空けた残りの中央に見えることを、ピンホールカメラで投影し直して確かめる。
final class CameraPaddingEmulationTests: XCTestCase {
    private let tokyo = GeoPoint(latitude: 35.6812, longitude: 139.7671)
    private let viewport = CGSize(width: 1194, height: 834)

    private func camera(
        tilt: Double,
        bearing: Double = 0,
        paddings: MapPaddings
    ) -> MapCameraPosition {
        MapCameraPosition(position: tokyo, zoom: 15, bearing: bearing, tilt: tilt, paddings: paddings)
    }

    private func mpp(_ camera: MapCameraPosition) -> Double {
        WebMercatorZoomAltitudeConverter.webMercatorInitialMpp256
            * cos(camera.position.latitude * .pi / 180) / pow(2, camera.zoom)
    }

    /// カメラの中心 `center` から見た `point` の画面上のずれ（中心からの pt、右と下が正）。
    private func project(
        _ point: GeoPoint,
        center: GeoPoint,
        camera: MapCameraPosition,
        fov: Double
    ) -> CGPoint {
        let heading = CameraBearing.toNativeHeading(camera.bearing)
        let distance = Spherical.computeDistanceBetween(from: center, to: point)
        let angle = (Spherical.computeHeading(from: center, to: point) - heading) * .pi / 180
        let forward = distance * cos(angle)
        let right = distance * sin(angle)
        let tilt = camera.tilt * .pi / 180
        let focal = (viewport.height / 2) / tan(fov * .pi / 360)
        let range = focal * mpp(camera)
        let depth = (forward + range * sin(tilt)) * sin(tilt) + range * cos(tilt) * cos(tilt)
        return CGPoint(x: focal * right / depth, y: -focal * forward * cos(tilt) / depth)
    }

    func testNoPaddingsKeepsTarget() {
        let cam = camera(tilt: 60, paddings: MapPaddings.Zeros)
        let center = CameraPaddingEmulation.cameraCenter(for: cam, fov: 36.87, viewportSize: viewport)
        XCTAssertEqual(center.latitude, tokyo.latitude, accuracy: 1e-12)
        XCTAssertEqual(center.longitude, tokyo.longitude, accuracy: 1e-12)
    }

    func testTiltZeroMovesCenterByHalfThePadding() {
        let cam = camera(tilt: 0, paddings: MapPaddings(top: 300))
        let center = CameraPaddingEmulation.cameraCenter(for: cam, fov: 36.87, viewportSize: viewport)
        XCTAssertEqual(Spherical.computeDistanceBetween(from: tokyo, to: center), 150 * mpp(cam), accuracy: 0.05)
        XCTAssertGreaterThan(center.latitude, tokyo.latitude)
    }

    func testPerspectiveTargetLandsAtPaddedCenter() {
        for (tilt, bearing) in [(30.0, 0.0), (60.0, 0.0), (60.0, 135.0), (45.0, -70.0)] {
            let paddings = MapPaddings(top: 300, left: 40, bottom: 0, right: 0)
            let cam = camera(tilt: tilt, bearing: bearing, paddings: paddings)
            let center = CameraPaddingEmulation.cameraCenter(for: cam, fov: 36.87, viewportSize: viewport)
            let offset = project(tokyo, center: center, camera: cam, fov: 36.87)
            XCTAssertEqual(offset.x, 20, accuracy: 0.5, "tilt \(tilt) bearing \(bearing)")
            XCTAssertEqual(offset.y, 150, accuracy: 0.5, "tilt \(tilt) bearing \(bearing)")
        }
    }

    func testOrthographicStretchesByCosTilt() {
        let cam = camera(tilt: 60, paddings: MapPaddings(top: 300))
        let center = CameraPaddingEmulation.cameraCenter(for: cam, fov: 0, viewportSize: viewport)
        XCTAssertEqual(Spherical.computeDistanceBetween(from: tokyo, to: center), 150 * mpp(cam) / cos(.pi / 3), accuracy: 0.05)
    }

    func testUnknownFovFallsBackToTiltZero() {
        let cam = camera(tilt: 60, paddings: MapPaddings(top: 300))
        let center = CameraPaddingEmulation.cameraCenter(for: cam, fov: nil, viewportSize: viewport)
        XCTAssertEqual(Spherical.computeDistanceBetween(from: tokyo, to: center), 150 * mpp(cam), accuracy: 0.05)
    }

    func testRoundTrip() {
        for fov in [nil, 0.0, 30.0, 36.87] as [Double?] {
            let paddings = MapPaddings(top: 250, left: 10, bottom: 30, right: 90)
            let cam = camera(tilt: 55, bearing: 200, paddings: paddings)
            let center = CameraPaddingEmulation.cameraCenter(for: cam, fov: fov, viewportSize: viewport)
            let back = CameraPaddingEmulation.target(
                forCameraCenter: center,
                camera: cam,
                paddings: paddings,
                fov: fov,
                viewportSize: viewport
            )
            XCTAssertEqual(back.latitude, tokyo.latitude, accuracy: 1e-7)
            XCTAssertEqual(back.longitude, tokyo.longitude, accuracy: 1e-7)
        }
    }

    func testFovIsCarriedByCopyButNotCompared() {
        let cam = MapCameraPosition(position: tokyo, zoom: 10, fov: 36.87)
        XCTAssertEqual(cam.copy(zoom: 11).fov, 36.87)
        XCTAssertTrue(cam.equals(other: MapCameraPosition(position: tokyo, zoom: 10)))
        XCTAssertNil(MapCameraPosition(position: tokyo).fov)
    }

    func testAppliedAndRestoredRoundTrip() {
        let paddings = MapPaddings(top: 300)
        let cam = camera(tilt: 60, bearing: 45, paddings: paddings)
        let sent = CameraPaddingEmulation.applied(to: cam, fov: 36.87, viewportSize: viewport)
        XCTAssertEqual(sent.paddings?.top, 0)
        let back = CameraPaddingEmulation.restored(sent, paddings: paddings, fov: 36.87, viewportSize: viewport)
        // 読み戻しは中心の緯度で縮尺を取るので、往復は 1 m 程度の誤差を許す。
        XCTAssertLessThan(Spherical.computeDistanceBetween(from: GeoPoint.from(position: back.position), to: tokyo), 1.0)
        XCTAssertEqual(back.paddings?.top, 300)
        XCTAssertEqual(back.fov, 36.87)
    }

    /// 地図の縮尺が計算より 7% 大きくても、投影で測って詰めればターゲットがパディングの残りの中央に来る。
    func testCorrectedCenterConvergesWithAMisScaledMap() {
        let paddings = MapPaddings(top: 300)
        let cam = camera(tilt: 0, paddings: paddings)
        let pointsPerMeter = 1.07 / mpp(cam)
        var center = CameraPaddingEmulation.cameraCenter(for: cam, fov: 0, viewportSize: viewport)
        func project(_ point: GeoPointProtocol) -> CGPoint? {
            let distance = Spherical.computeDistanceBetween(from: center, to: GeoPoint.from(position: point))
            let angle = Spherical.computeHeading(from: center, to: GeoPoint.from(position: point)) * .pi / 180
            return CGPoint(
                x: viewport.width / 2 + distance * sin(angle) * pointsPerMeter,
                y: viewport.height / 2 - distance * cos(angle) * pointsPerMeter
            )
        }
        func unproject(_ point: CGPoint) -> GeoPoint? {
            let dx = (Double(point.x) - viewport.width / 2) / pointsPerMeter
            let dy = (viewport.height / 2 - Double(point.y)) / pointsPerMeter
            let north = Spherical.computeOffset(origin: center, distance: dy, heading: 0)
            return Spherical.computeOffset(origin: north, distance: dx, heading: 90)
        }
        for _ in 0..<3 {
            guard let next = CameraPaddingEmulation.correctedCenter(
                target: tokyo, paddings: paddings, viewportSize: viewport,
                project: project, unproject: unproject
            ) else { break }
            center = next
        }
        let landed = project(tokyo)!
        XCTAssertEqual(landed.y, viewport.height / 2 + 150, accuracy: 0.5)
        XCTAssertEqual(landed.x, viewport.width / 2, accuracy: 0.5)
    }
}
