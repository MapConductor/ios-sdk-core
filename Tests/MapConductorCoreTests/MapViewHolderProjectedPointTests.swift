import CoreGraphics
import XCTest

@testable import MapConductorCore

/// 投影座標の既定実装。上書きしないホルダは EPSG:3857 メートルを返す。
final class MapViewHolderProjectedPointTests: XCTestCase {
    private struct PlainHolder: MapViewHolderProtocol {
        let mapView: Void = ()
        let map: Void = ()

        func toScreenOffset(position _: GeoPointProtocol) -> CGPoint? { nil }
        func viewportSizePx() -> CGSize? { nil }
    }

    /// 上書きしたホルダ。型消去しても上書きが効くことを見る。
    private struct DegreesHolder: MapViewHolderProtocol {
        let mapView: Void = ()
        let map: Void = ()

        func toScreenOffset(position _: GeoPointProtocol) -> CGPoint? { nil }
        func viewportSizePx() -> CGSize? { nil }

        var coordinateSystem: MapCoordinateSystem { .wgs84 }

        func toProjectedPoint(_ position: GeoPointProtocol) -> CGPoint? {
            CGPoint(x: position.longitude, y: position.latitude)
        }

        func fromProjectedPoint(_ point: CGPoint) -> GeoPoint? {
            GeoPoint(latitude: point.y, longitude: point.x)
        }
    }

    func testDefaultCoordinateSystemIsWebMercator() {
        let system = PlainHolder().coordinateSystem
        XCTAssertEqual(system.code, "EPSG:3857")
        XCTAssertEqual(system.unit, .meters)
        XCTAssertEqual(system, .webMercator)
    }

    func testDefaultProjectionIsEpsg3857Meters() throws {
        // 東京駅。期待値は x = λ·a、y = a·ln(tan(π/4 + φ/2))（a = 6378137）。
        let point = try XCTUnwrap(PlainHolder().toProjectedPoint(GeoPoint(latitude: 35.681236, longitude: 139.767125)))
        XCTAssertEqual(point.x, 15558805.18, accuracy: 0.01)
        XCTAssertEqual(point.y, 4256848.12, accuracy: 0.01)
    }

    func testDefaultRoundTripReturnsTheSamePoint() throws {
        let holder = PlainHolder()
        let original = GeoPoint(latitude: -33.8688, longitude: 151.2093)
        let back = try XCTUnwrap(holder.fromProjectedPoint(try XCTUnwrap(holder.toProjectedPoint(original))))
        XCTAssertEqual(back.latitude, original.latitude, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, original.longitude, accuracy: 1e-9)
    }

    func testTypeErasureKeepsTheOverride() throws {
        let erased = AnyMapViewHolder(DegreesHolder())
        XCTAssertEqual(erased.coordinateSystem, .wgs84)
        let point = try XCTUnwrap(erased.toProjectedPoint(GeoPoint(latitude: 35.0, longitude: 139.0)))
        XCTAssertEqual(point.x, 139.0)
        XCTAssertEqual(point.y, 35.0)
        let back = try XCTUnwrap(erased.fromProjectedPoint(point))
        XCTAssertEqual(back.latitude, 35.0)
    }
}
