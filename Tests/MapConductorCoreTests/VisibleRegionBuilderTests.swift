import CoreGraphics
import XCTest

@testable import MapConductorCore

/// ``buildVisibleRegion(size:inset:requireAllCorners:)`` の意味論テスト。
///
/// android-sdk の `VisibleRegionBuilderTest` と 1 対 1 で対応する。
/// ios-for-maplibre / mapbox / maptiler が各自持っていた「4 隅を逆投影して
/// ``VisibleRegion`` を組む」15 行前後をコアへ集約したもの。
///
/// 押さえたい不変条件:
///  - 隅の対応（nearLeft は左下、farLeft は左上）を取り違えない。
///    **ios-for-mapbox は実際に取り違えていた**（nearLeft に右下を入れていた）。
///  - `requireAllCorners` の 2 つの挙動。傾いた地図では隅の逆投影が地表に
///    当たらないことがあり、そこで region ごと落とすと marker-clustering が
///    ビューポートを算出できずクラスタが消える。
final class VisibleRegionBuilderTests: XCTestCase {
    /// 画面座標をそのまま経度/緯度として返す代役（y を反転して「上が北」にする）。
    private final class FakeHolder: MapViewHolderProtocol {
        typealias ActualMapView = Any
        typealias ActualMap = Any

        let mapView: Any = NSObject()
        let map: Any = NSObject()

        let width: CGFloat
        let height: CGFloat
        private let unresolved: Set<CGPoint>

        private(set) var requested: [CGPoint] = []

        init(width: CGFloat, height: CGFloat, unresolved: Set<CGPoint> = []) {
            self.width = width
            self.height = height
            self.unresolved = unresolved
        }

        func toScreenOffset(position _: GeoPointProtocol) -> CGPoint? { nil }

        func fromScreenOffset(offset: CGPoint) async -> GeoPoint? { fromScreenOffsetSync(offset: offset) }

        func fromScreenOffsetSync(offset: CGPoint) -> GeoPoint? {
            requested.append(offset)
            if unresolved.contains(offset) { return nil }
            // x -> 経度 (0..10), y -> 緯度 (上が +50、下が -50)
            let lng = offset.x / width * 10.0
            let lat = 50.0 - (offset.y / height) * 100.0
            return GeoPoint(latitude: Double(lat), longitude: Double(lng), altitude: 0)
        }
    }

    /// サイズを明示するオーバーロードを直接叩く（`UIView` を用意できないため）。
    private func build(
        _ holder: FakeHolder,
        inset: CGFloat = 0,
        requireAllCorners: Bool = true
    ) -> VisibleRegion? {
        holder.buildVisibleRegion(
            size: CGSize(width: holder.width, height: holder.height),
            inset: inset,
            requireAllCorners: requireAllCorners
        )
    }

    func testCornersAreAssignedCorrectly() throws {
        let region = try XCTUnwrap(build(FakeHolder(width: 100, height: 200)))
        // nearLeft = 左下 = 経度 0 / 緯度 -50
        XCTAssertEqual(try XCTUnwrap(region.nearLeft).longitude, 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(region.nearLeft).latitude, -50.0, accuracy: 1e-9)
        // farRight = 右上 = 経度 10 / 緯度 +50
        XCTAssertEqual(try XCTUnwrap(region.farRight).longitude, 10.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(region.farRight).latitude, 50.0, accuracy: 1e-9)
        // nearRight = 右下 / farLeft = 左上
        XCTAssertEqual(try XCTUnwrap(region.nearRight).longitude, 10.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(region.nearRight).latitude, -50.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(region.farLeft).longitude, 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(region.farLeft).latitude, 50.0, accuracy: 1e-9)
    }

    func testBoundsContainEveryCorner() throws {
        let region = try XCTUnwrap(build(FakeHolder(width: 100, height: 200)))
        for corner in [region.nearLeft, region.nearRight, region.farLeft, region.farRight] {
            let point = try XCTUnwrap(corner)
            XCTAssertTrue(region.bounds.contains(point: point), "bounds が \(point) を含んでいない")
        }
    }

    func testInsetUsesInnerPoints() {
        let holder = FakeHolder(width: 100, height: 200)
        _ = build(holder, inset: 1)
        XCTAssertTrue(holder.requested.allSatisfy { $0.x == 1 || $0.x == 99 })
        XCTAssertTrue(holder.requested.allSatisfy { $0.y == 1 || $0.y == 199 })
    }

    func testRequireAllCornersRejectsAPartialRegion() {
        let holder = FakeHolder(width: 100, height: 200, unresolved: [CGPoint(x: 0, y: 0)])
        XCTAssertNil(build(holder, requireAllCorners: true))
    }

    func testWithoutRequireAllCornersItKeepsWhatResolved() throws {
        let holder = FakeHolder(width: 100, height: 200, unresolved: [CGPoint(x: 0, y: 0)])
        let region = try XCTUnwrap(
            build(holder, requireAllCorners: false),
            "隅が欠けても region ごと落としてはいけない"
        )
        XCTAssertNil(region.farLeft, "解けなかった隅は nil のまま")
        XCTAssertNotNil(region.nearLeft)
        XCTAssertTrue(region.bounds.contains(point: try XCTUnwrap(region.nearRight)))
    }

    func testNoResolvableCornerGivesNil() {
        let all: Set<CGPoint> = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 0, y: 200), CGPoint(x: 100, y: 200),
        ]
        let holder = FakeHolder(width: 100, height: 200, unresolved: all)
        XCTAssertNil(build(holder, requireAllCorners: false))
    }
}
