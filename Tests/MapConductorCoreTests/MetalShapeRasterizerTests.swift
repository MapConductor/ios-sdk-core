import CoreGraphics
import ImageIO
import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// 円のタイルを GPU（`MetalShapeRasterizer`）と CPU（`CircleTilePainter` + CGContext）で描き、
/// 同じ絵になることを確かめる。
///
/// 画素ごとの一致は求めない。アンチエイリアスの縁は描き方の違いで 1 段ずれる。
/// 見るのは、塗りと縁の色が同じ場所に出ていること（縁の画素を除けばほぼ一致すること）と、
/// 重ね順・小さな円の 1 点・縁なしの判定が CPU と同じであること。
final class MetalShapeRasterizerTests: XCTestCase {
    override func tearDown() {
        unsetenv("MAPCONDUCTOR_SHAPE_TILE_CPU")
        super.tearDown()
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

    /// 同じタイルを GPU と CPU で描いて、両方の画素を返す。
    private func renderBoth(_ shapes: [CircleTileShape], z: Int, x: Int, y: Int, ratio: Int = 1) throws -> (gpu: [UInt8], cpu: [UInt8]) {
        try XCTSkipIf(MetalShapeRasterizer.shared == nil, "Metal が無い")
        func render() throws -> [UInt8] {
            let renderer = ShapeTileRenderer(pixelRatio: ratio)
            renderer.setShapes(shapes.map { ShapeTileRenderer.Shape($0) })
            let png = try XCTUnwrap(renderer.renderTile(request: TileRequest(x: x, y: y, z: z)))
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

    private func worldPx(_ lat: Double, _ lng: Double, z: Int) -> (x: Double, y: Double) {
        let scale = 256.0 * Double(1 << z)
        let s = sin(lat * .pi / 180)
        return ((lng + 180) / 360 * scale, (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * scale)
    }

    /// ボストン周辺に、色・透明度・大きさ・縁がまちまちの円を `count` 個。乱数は固定。
    private func scatter(count: Int, spanDegrees: Double, radiusMeters: ClosedRange<Double>) -> [CircleTileShape] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let palette: [UIColor] = [.red, .blue, .green, .orange, .purple]
        return (0..<count).map { _ in
            let fill = palette[Int(next() * 5)].withAlphaComponent(0.3 + next() * 0.7).cgColor
            let stroke = palette[Int(next() * 5)].withAlphaComponent(0.4 + next() * 0.6).cgColor
            return CircleTileShape(
                latitude: 42.36 + (next() - 0.5) * spanDegrees,
                longitude: -71.06 + (next() - 0.5) * spanDegrees,
                radiusMeters: radiusMeters.lowerBound + next() * (radiusMeters.upperBound - radiusMeters.lowerBound),
                geodesic: true,
                fill: next() < 0.9 ? fill : nil,
                stroke: next() < 0.7 ? stroke : nil,
                strokeWidth: next() < 0.5 ? 1 : 3
            )
        }
    }

    private func tile(z: Int) -> (x: Int, y: Int) {
        let p = worldPx(42.36, -71.06, z: z)
        return (Int(p.x / 256), Int(p.y / 256))
    }

    /// 街の円（数十〜数百 px）。塗り・縁・重なりがどれも見える大きさ。
    func testCityCirclesMatchTheCpuDrawing() throws {
        let z = 15
        let t = tile(z: z)
        let both = try renderBoth(scatter(count: 400, spanDegrees: 0.02, radiusMeters: 20...300), z: z, x: t.x, y: t.y)
        // 縁のアンチエイリアス以外は一致する。
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.02)
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 8), 0.08)
    }

    /// Retina のタイル（ratio 2）も同じ。
    func testRetinaTilesMatchTheCpuDrawing() throws {
        let z = 15
        let t = tile(z: z)
        let both = try renderBoth(scatter(count: 200, spanDegrees: 0.02, radiusMeters: 20...300), z: z, x: t.x, y: t.y, ratio: 2)
        XCTAssertEqual(both.gpu.count, 512 * 512 * 4)
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.02)
    }

    /// 引いたズーム: 多くが 1 点か数 px。1 画素に重なった円は最後の 1 つだけ、が CPU と同じ。
    func testZoomedOutDotsMatchTheCpuDrawing() throws {
        let z = 9
        let t = tile(z: z)
        let both = try renderBoth(scatter(count: 20_000, spanDegrees: 1.5, radiusMeters: 50...800), z: z, x: t.x, y: t.y)
        XCTAssertLessThan(mismatch(both.gpu, both.cpu, tolerance: 48), 0.03)
    }
}
