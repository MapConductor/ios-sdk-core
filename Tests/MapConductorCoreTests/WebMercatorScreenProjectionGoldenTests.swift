import CoreGraphics
import XCTest

@testable import MapConductorCore

/// ``WebMercatorScreenProjection`` を android と iOS で同じ値に留める。
///
/// ## なぜテストで留めるのか
///
/// この式のズレは**目視ではまず見つからない**。吹き出しが数 pt ずれるだけで、
/// 地図は正しく動いているように見える。しかも
///
///   **pt と px を取り違えてもコンパイルは通る。**
///
/// `worldSizeAtZoom0` の 256 は密度非依存の単位（pt / dp / CSS ピクセル）なので、
/// 端末ピクセルの大きさをそのまま渡すと結果が scale 倍ずれる。実際に
/// android-for-longdo でこれを踏んで吹き出しが右下へずれた
/// （`LongdoMapViewHolder` が density で割ってから渡している）。
/// ``worldIsTwoFiftySixUnitsWideAtZoomZero()`` がその門番。
///
/// ## 対応表
///
/// android-sdk-core の `WebMercatorScreenProjectionGoldenTest.kt` と同じ題・同じ値。
/// **片方だけ直す、ということをしないこと。**
///
/// 元は js-sdk-react にも同じ 6 件があったが、JS 側で投影するのをやめた
/// （投影はコア層の仕事で、JS 層で判断しない）ため実装ごと消した。
/// 最初の 6 件はそのときの題をそのまま引き継いでいる。
final class WebMercatorScreenProjectionGoldenTests: XCTestCase {
    private let size = CGSize(width: 400, height: 800)

    private func camera(
        latitude: Double = 35.681236,
        longitude: Double = 139.767125,
        zoom: Double = 12,
        bearing: Double = 0
    ) -> MapCameraPosition {
        MapCameraPosition(
            position: GeoPoint(latitude: latitude, longitude: longitude),
            zoom: zoom,
            bearing: bearing
        )
    }

    private func project(
        _ point: any GeoPointProtocol,
        _ camera: MapCameraPosition,
        size: CGSize? = nil
    ) -> CGPoint? {
        WebMercatorScreenProjection.toScreenOffset(point, camera: camera, size: size ?? self.size)
    }

    func testCenterLandsInTheMiddleOfTheView() throws {
        let c = camera()
        let p = try XCTUnwrap(project(c.position, c))
        XCTAssertEqual(p.x, 200, accuracy: 1e-6)
        XCTAssertEqual(p.y, 400, accuracy: 1e-6)
    }

    func testEastIsRightAndNorthIsUp() throws {
        let c = camera()
        let east = try XCTUnwrap(
            project(GeoPoint(latitude: c.position.latitude, longitude: c.position.longitude + 0.05), c)
        )
        let north = try XCTUnwrap(
            project(GeoPoint(latitude: c.position.latitude + 0.05, longitude: c.position.longitude), c)
        )
        XCTAssertGreaterThan(east.x, 200)
        XCTAssertEqual(east.y, 400, accuracy: 1e-6)
        XCTAssertLessThan(north.y, 400)
        XCTAssertEqual(north.x, 200, accuracy: 1e-6)
    }

    func testOneZoomStepDoublesTheDistanceFromTheCenter() throws {
        let target = GeoPoint(latitude: 35.681236, longitude: 139.8)
        let a = try XCTUnwrap(project(target, camera(zoom: 12)))
        let b = try XCTUnwrap(project(target, camera(zoom: 13)))
        let ratio = (b.x - 200) / (a.x - 200)
        XCTAssertEqual(ratio, 2, accuracy: 1e-9)
    }

    /// bearing は「地図を時計回りに回す量」。90 なら地図が右へ 90 度回り、
    /// 画面の上には**西**が来る（東は画面の下）。
    func testBearing90PutsWestAtTheTop() throws {
        let c = camera(bearing: 90)
        let west = try XCTUnwrap(
            project(GeoPoint(latitude: c.position.latitude, longitude: c.position.longitude - 0.05), c)
        )
        XCTAssertLessThan(west.y, 400)
        XCTAssertEqual(west.x, 200, accuracy: 1e-6)

        let east = try XCTUnwrap(
            project(GeoPoint(latitude: c.position.latitude, longitude: c.position.longitude + 0.05), c)
        )
        XCTAssertGreaterThan(east.y, 400)
    }

    func testDatelineWrapsTheShortWay() throws {
        let c = camera(latitude: 0, longitude: 179.9, zoom: 8)
        let across = try XCTUnwrap(project(GeoPoint(latitude: 0, longitude: -179.9), c))
        // 0.2 度ぶんだけ右にあるべき。地図の反対側（数万 pt）へ飛ばない。
        XCTAssertGreaterThan(across.x, 200)
        XCTAssertLessThan(across.x, 400)
    }

    func testUnlaidOutViewReturnsNil() {
        XCTAssertNil(project(GeoPoint(latitude: 0, longitude: 0), camera(), size: .zero))
    }

    /// zoom 0 では世界一周がちょうど 256 単位。**渡した大きさと同じ単位で返る**ことの確認。
    ///
    /// 端末ピクセルを渡すと、この 256 が「256 px」の意味になってしまい scale 倍ずれる。
    /// ここが pt/px 取り違えの唯一の機械的な門番。
    func testWorldIsTwoFiftySixUnitsWideAtZoomZero() throws {
        let c = camera(latitude: 0, longitude: 0, zoom: 0)
        // 経度 +90° は世界の 1/4 ＝ 64 単位ぶん右。
        let quarter = try XCTUnwrap(project(GeoPoint(latitude: 0, longitude: 90), c))
        XCTAssertEqual(quarter.x, 200 + 64, accuracy: 1e-6)
        XCTAssertEqual(quarter.y, 400, accuracy: 1e-6)
    }

    func testRoundTripReturnsTheOriginalPoint() throws {
        let c = camera(bearing: 33)
        let target = GeoPoint(latitude: 35.7, longitude: 139.8)
        let screen = try XCTUnwrap(project(target, c))
        let back = try XCTUnwrap(
            WebMercatorScreenProjection.fromScreenOffset(screen, camera: c, size: size)
        )
        XCTAssertEqual(back.latitude, target.latitude, accuracy: 1e-6)
        XCTAssertEqual(back.longitude, target.longitude, accuracy: 1e-6)
    }
}
