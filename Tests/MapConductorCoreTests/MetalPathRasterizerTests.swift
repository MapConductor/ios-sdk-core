import CoreGraphics
import ImageIO
import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// ポリゴンとポリラインのタイルを GPU（`MetalPathRasterizer`）と CPU（CGContext）で描き、
/// 同じ絵になることを確かめる。
///
/// GPU は 4x MSAA、CPU は CoreGraphics のアンチエイリアスなので、縁の画素は 1 段ずれる。
/// 見るのは、縁を除いた所が一致すること。とくに CPU と食い違いやすい所:
/// nonzero の塗り（重なった穴の和が抜ける）、半透明の線の継ぎ目と自己交差（2 度塗りしない）、
/// 丸い角と端、小さすぎて 1 点になる図形、渡した順の重なり。
final class MetalPathRasterizerTests: XCTestCase {
    override func tearDown() {
        unsetenv("MAPCONDUCTOR_SHAPE_TILE_CPU")
        super.tearDown()
    }

    private let z = 15
    private var tile: (x: Int, y: Int) {
        let p = worldPx(42.36, -71.06, z: z)
        return (Int(p.x / 256), Int(p.y / 256))
    }

    private func worldPx(_ lat: Double, _ lng: Double, z: Int) -> (x: Double, y: Double) {
        let scale = 256.0 * Double(1 << z)
        let s = sin(lat * .pi / 180)
        return ((lng + 180) / 360 * scale, (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * scale)
    }

    /// このタイルの画素 (x, y) の緯度経度（`z` で）。
    private func latLng(_ x: Double, _ y: Double, z: Int? = nil) -> [Double] {
        let z = z ?? self.z
        let scale = 256.0 * Double(1 << z)
        let wx = Double(tile.x) * 256 * Double(1 << (z - self.z)) + x
        let wy = Double(tile.y) * 256 * Double(1 << (z - self.z)) + y
        let n = .pi - 2 * .pi * wy / scale
        return [atan(sinh(n)) * 180 / .pi, wx / scale * 360 - 180]
    }

    /// タイルの画素の点列を緯度経度の平らな配列に。
    private func ring(_ points: [(Double, Double)]) -> [Double] {
        points.flatMap { latLng($0.0, $0.1) }
    }

    private func decode(_ png: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func renderBoth(_ shapes: [ShapeTileRenderer.Shape?], z: Int? = nil, x: Int? = nil, y: Int? = nil, ratio: Int = 1) throws -> (gpu: [UInt8], cpu: [UInt8]) {
        // 無ければ CPU で描いて通ってしまい、GPU を何も確かめない。
        _ = try XCTUnwrap(MetalPathRasterizer.shared, "Metal が無い")
        func render() throws -> [UInt8] {
            let renderer = ShapeTileRenderer(pixelRatio: ratio)
            renderer.setShapes(shapes)
            let png = try XCTUnwrap(renderer.renderTile(request: TileRequest(x: x ?? tile.x, y: y ?? tile.y, z: z ?? self.z)))
            return try decode(png)
        }
        unsetenv("MAPCONDUCTOR_SHAPE_TILE_CPU")
        let gpu = try render()
        setenv("MAPCONDUCTOR_SHAPE_TILE_CPU", "1", 1)
        let cpu = try render()
        unsetenv("MAPCONDUCTOR_SHAPE_TILE_CPU")
        return (gpu, cpu)
    }

    /// 画素の何割が、どれかのチャンネルで `tolerance` を超えて違うか。
    private func mismatch(_ a: [UInt8], _ b: [UInt8], tolerance: Int) -> Double {
        var bad = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<4 where abs(Int(a[i + c]) - Int(b[i + c])) > tolerance { bad += 1; break }
        }
        return Double(bad) / Double(a.count / 4)
    }

    private func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int = 256) -> [Int] {
        let i = (y * width + x) * 4
        return (0..<4).map { Int(bytes[i + $0]) }
    }

    private func polygon(_ rings: [[(Double, Double)]], fill: UIColor?, stroke: UIColor? = nil, width: Double = 0) -> ShapeTileRenderer.Shape? {
        ShapeTileRenderer.Shape(PolygonTileShape(rings: rings.map(ring), fill: fill?.cgColor, stroke: stroke?.cgColor, strokeWidth: width))
    }

    private func polyline(_ points: [(Double, Double)], color: UIColor, width: Double) -> ShapeTileRenderer.Shape? {
        ShapeTileRenderer.Shape(PolylineTileShape(points: ring(points), stroke: color.cgColor, strokeWidth: width))
    }

    // MARK: polygons

    /// 外周と、重なった 2 つの穴。nonzero の巻き数で塗る: 穴 1 つの所は 0 で抜け、
    /// 2 つの穴が重なった所は -1 で塗られる（CPU も同じ。重なった穴は呼び出し側が
    /// 先に 1 つにまとめる）。縁は外周だけ。
    func testHolesFollowTheNonzeroWindingAsOnTheCpu() throws {
        let shape = polygon([
            [(40, 40), (216, 40), (216, 216), (40, 216)],
            [(70, 70), (70, 150), (150, 150), (150, 70)],
            [(110, 110), (110, 190), (190, 190), (190, 110)],
        ], fill: UIColor.blue.withAlphaComponent(0.6), stroke: .red, width: 3)
        let both = try renderBoth([shape])
        XCTAssertEqual(pixel(both.gpu, 130, 130), pixel(both.cpu, 130, 130), "2 つの穴が重なった所（巻き数 -1）")
        XCTAssertEqual(pixel(both.gpu, 90, 90)[3], 0, "穴 1 つの所は抜ける")
        XCTAssertGreaterThan(pixel(both.gpu, 200, 60)[2], 100, "穴の外は塗る")
        XCTAssertGreaterThan(pixel(both.gpu, 40, 128)[0], 200, "外周に縁")
        XCTAssertEqual(pixel(both.gpu, 70, 110)[0], 0, "穴には縁を描かない")
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.02)
    }

    /// 半透明の図形が重なる。渡した順に重なり、色の混ざり方も CPU と同じ。
    func testTranslucentPolygonsStackInTheGivenOrder() throws {
        var shapes: [ShapeTileRenderer.Shape?] = []
        let colors: [UIColor] = [.red, .green, .blue, .orange, .purple]
        for i in 0..<40 {
            let x = Double((i * 37) % 200) + 10, y = Double((i * 53) % 200) + 10
            let w = Double(20 + (i * 7) % 40)
            shapes.append(polygon(
                [[(x, y), (x + w, y + w / 3), (x + w / 2, y + w)]],
                fill: colors[i % 5].withAlphaComponent(0.5), stroke: colors[(i + 2) % 5].withAlphaComponent(0.7), width: Double(1 + i % 3)
            ))
        }
        let both = try renderBoth(shapes)
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.03)
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 8), 0.10)
    }

    /// 引いたズームでは 1 px 未満の区画が 1 点になる。CPU と同じ画素に同じ色。
    func testZoomedOutPolygonsBecomeTheSameDots() throws {
        var shapes: [ShapeTileRenderer.Shape?] = []
        for i in 0..<3000 {
            let x = Double((i * 97) % 2500) / 10, y = Double((i * 61) % 2500) / 10
            shapes.append(polygon([[(x, y), (x + 2, y), (x + 2, y + 2), (x, y + 2)]], fill: i % 2 == 0 ? .red : .blue))
        }
        let both = try renderBoth(shapes, z: 11, x: tile.x / 16, y: tile.y / 16)
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.01)
    }

    // MARK: polylines

    /// 半透明の太い線が自分と交差し、鋭く折れ返す。継ぎ目も交差も 2 度塗りしない。丸い端。
    func testATranslucentLineIsCoveredOnceWithRoundJoinsAndCaps() throws {
        let line = polyline([(30, 128), (200, 128), (60, 60), (120, 220), (120, 30)],
                            color: UIColor.red.withAlphaComponent(0.5), width: 12)
        let both = try renderBoth([line])
        let crossing = pixel(both.gpu, 120, 128)
        XCTAssertLessThanOrEqual(abs(crossing[3] - 128), 3, "交差した所も 1 度だけ塗る")
        XCTAssertGreaterThan(pixel(both.gpu, 26, 128)[3], 100, "丸い端は端点の外まで出る")
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.02)
    }

    /// 多くの線（道路網）。重なり・幅・色がまちまち。Retina のタイル。
    func testManyLinesMatchTheCpuDrawingOnRetinaTiles() throws {
        var shapes: [ShapeTileRenderer.Shape?] = []
        let colors: [UIColor] = [.red, .blue, .darkGray, .orange]
        for i in 0..<300 {
            let y = Double((i * 13) % 256), x = Double((i * 29) % 256)
            shapes.append(polyline(
                [(x - 40, y), (x, y + 10), (x + 30, y - 20), (x + 80, y + 5)],
                color: colors[i % 4].withAlphaComponent(i % 3 == 0 ? 0.6 : 1), width: Double(1 + i % 5)
            ))
        }
        let both = try renderBoth(shapes, ratio: 2)
        XCTAssertEqual(both.gpu.count, 512 * 512 * 4)
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.04)
    }

    /// 1 点に縮んだ線は、線の幅の丸になる。
    func testACollapsedLineIsADotAsWideAsTheLine() throws {
        let line = polyline([(100, 100), (100.2, 100.1)], color: .blue, width: 8)
        let both = try renderBoth([line])
        XCTAssertGreaterThan(pixel(both.gpu, 100, 100)[2], 200)
        XCTAssertGreaterThan(pixel(both.gpu, 103, 100)[2], 200)
        XCTAssertEqual(pixel(both.gpu, 106, 100)[3], 0)
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.005)
    }
}
