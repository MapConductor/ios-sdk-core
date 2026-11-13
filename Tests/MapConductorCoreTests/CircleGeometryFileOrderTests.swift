import CoreGraphics
import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// 大きな円の集合はファイルに「場所順」で置く（`CircleGeometryFile` の order）。
///
/// 1 タイルの円がファイルの数ページに収まるようにするため。番号はリストのまま
/// （描く順・更新・有効/無効）で、読む側には違いが見えないこと:
/// - 番号ごとの読み出し・外接矩形は index 順のファイルと同じ
/// - 索引の答えは同じ
/// - 描いたタイルは index 順のファイルとバイト単位で同じ（GPU と CPU の両方）
/// js-sdk-core の CircleTiling.test.mjs、android-sdk-core の CircleTileFileStorageTest と同じ内容。
final class CircleGeometryFileOrderTests: XCTestCase {
    override func tearDown() {
        unsetenv("MAPCONDUCTOR_SHAPE_TILE_CPU")
        super.tearDown()
    }

    /// Every fourth one round one place (overlapping, the dots sharing pixels), the rest far away.
    private func scattered(_ count: Int) -> [ShapeTileRenderer.Shape?] {
        let colors: [UIColor] = [.blue, .red, .green, .orange]
        return (0..<count).map { i in
            let center = i % 4 == 0
                ? GeoPoint(latitude: 40.75 + Double(i % 400) * 0.0002, longitude: -73.98 + Double(i % 37) * 0.0003)
                : GeoPoint(latitude: 30 + Double(i % 50), longitude: -120 + Double(i % 97) * 0.5)
            let state = CircleState(center: center, radiusMeters: 50 + Double(i % 300), strokeColor: colors[(i + 1) % 4],
                                    strokeWidth: Double(i % 3), fillColor: colors[i % 4].withAlphaComponent(0.6))
            return ShapeTileRenderer.Shape(CircleTileShape(state: state))
        }
    }

    private func byPlace(_ shapes: [ShapeTileRenderer.Shape?]) -> [Int32] {
        CircleGeometryFile.sortedOrder(count: shapes.count) { i in
            guard let c = shapes[i]?.circle else { return 0 }
            return CircleGeometryFile.mortonCellKey(latitude: c.latitude, longitude: c.longitude)
        }
    }

    func testReadsAndTheIndexAreTheSameAsIndexOrder() throws {
        let shapes = scattered(4_000)
        let plain = ShapeTileStorage(try CircleGeometryFile(count: shapes.count, shapeAt: { shapes[$0] }))
        let order = byPlace(shapes)
        let placed = ShapeTileStorage(try CircleGeometryFile(count: shapes.count, order: order, shapeAt: { shapes[$0] }))
        XCTAssertEqual(placed.storageOrder, order)
        XCTAssertNotEqual(order, (0..<4_000).map { Int32($0) }, "the order must differ for this test to mean anything")
        for i in 0..<shapes.count {
            let a = plain.bounds(at: i), b = placed.bounds(at: i)
            XCTAssertEqual(a?.minX, b?.minX, "index \(i)")
            XCTAssertEqual(a?.maxY, b?.maxY, "index \(i)")
            XCTAssertEqual(plain[i]?.fill, placed[i]?.fill, "index \(i)")
        }
        let plainIndex = ShapeTileRenderer.Index(plain), placedIndex = ShapeTileRenderer.Index(placed)
        for (x, y, size) in [(0.294, 0.375, 0.001), (0.0, 0.0, 1.0), (0.16, 0.38, 0.05)] {
            XCTAssertEqual(
                plainIndex.query(plain, minX: x, minY: y, maxX: x + size, maxY: y + size),
                placedIndex.query(placed, minX: x, minY: y, maxX: x + size, maxY: y + size)
            )
        }
    }

    private func tiles(_ storage: ShapeTileStorage) throws -> [Data] {
        let renderer = ShapeTileRenderer(pixelRatio: 2)
        renderer.prepareStorage(storage)()
        // Round the place the fourth ones share: dots far out, overlapping discs close in.
        return try [(6, 18, 24), (10, 301, 384), (13, 2412, 3077), (15, 9650, 12310)].map { z, x, y in
            try XCTUnwrap(renderer.renderTile(request: TileRequest(x: x, y: y, z: z)), "z\(z)")
        }
    }

    func testTilesAreByteForByteTheSameOnTheGpuAndTheCpu() throws {
        let shapes = scattered(4_000)
        let order = byPlace(shapes)
        for cpu in [false, true] {
            if cpu { setenv("MAPCONDUCTOR_SHAPE_TILE_CPU", "1", 1) } else { unsetenv("MAPCONDUCTOR_SHAPE_TILE_CPU") }
            let plain = try tiles(ShapeTileStorage(try CircleGeometryFile(count: shapes.count, shapeAt: { shapes[$0] })))
            let placed = try tiles(ShapeTileStorage(try CircleGeometryFile(count: shapes.count, order: order, shapeAt: { shapes[$0] })))
            XCTAssertEqual(plain, placed, cpu ? "CPU" : "GPU")
        }
    }

    func testKeysAndTheOrderAreStable() {
        // Cell (2048, 2048): bit 11 of x and of y.
        XCTAssertEqual(CircleGeometryFile.mortonCellKey(latitude: 0, longitude: 0), (1 << 22) | (1 << 23))
        XCTAssertEqual(CircleGeometryFile.sortedOrder(count: 6) { [5, 1, 5, 0, 1, 5][$0] }, [3, 1, 4, 0, 2, 5])
    }
}
