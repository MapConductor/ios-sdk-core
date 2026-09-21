import UIKit
import XCTest

@testable import MapConductorCore

/// `MetalMarkerRasterizer` を renderer から切り離して単体で責める。
///
/// 実機で「タイル右端のマーカーが消える」「別のアイコンの色が出る」が
/// 出た（`DeviceSeamReproBench`）。renderer 側の kept・順序・矩形は左右の
/// タイルで一致していたので、容疑はこの中 -- アトラスの詰め方、UV、
/// クアッドの位置、読み戻しのどれか。ここでは入力を手で組むので、
/// どの段が嘘をつくかが直接分かる。
final class MetalMarkerRasterizerTests: XCTestCase {

    private func solid(_ color: UIColor, size: Int = 16) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }.cgImage!
    }

    /// 上半分と下半分で色の違う 1 枚。アトラスの上下反転はこれで出る。
    private func split(top: UIColor, bottom: UIColor, size: Int = 16) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            top.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
            bottom.setFill()
            context.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        }.cgImage!
    }

    private func pixels(_ png: Data) throws -> (p: [UInt8], w: Int, h: Int) {
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &buffer, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (buffer, image.width, image.height)
    }

    private func color(_ data: (p: [UInt8], w: Int, h: Int), _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        let at = (y * data.w + x) * 4
        return (Int(data.p[at]), Int(data.p[at + 1]), Int(data.p[at + 2]), Int(data.p[at + 3]))
    }

    /// 2x2 アトラスの 4 色が、それぞれのインスタンスにそのまま出ること。
    /// アトラスの行が入れ替わっていれば（上下反転）、ここで色が入れ替わる。
    func testFourIconsKeepTheirColours() throws {
        let gpu = try XCTUnwrap(MetalMarkerRasterizer.createOrNull(tileSize: 128))
        let icons = [solid(.red), solid(.green), solid(.blue), solid(.yellow)]
        let atlas = try XCTUnwrap(gpu.makeAtlas(icons))
        var instances: [MetalMarkerRasterizer.Instance] = []
        for at in 0..<4 {
            let uv = atlas.uv[at]
            instances.append(MetalMarkerRasterizer.Instance(
                left: Float(8 + at * 30), top: 40, width: 16, height: 16,
                u0: Float(uv.minX), v0: Float(uv.minY),
                u1: Float(uv.maxX), v1: Float(uv.maxY)
            ))
        }
        let png = try XCTUnwrap(gpu.renderPng(instances: instances, atlas: atlas.texture, paddingPx: 0))
        let out = try pixels(png)
        let expected = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        for at in 0..<4 {
            let (r, g, b, a) = color(out, 8 + at * 30 + 8, 48)
            XCTAssertGreaterThan(a, 200, "インスタンス \(at) が描かれていない")
            let want = expected[at]
            XCTAssertTrue(
                abs(r - want.0) < 40 && abs(g - want.1) < 40 && abs(b - want.2) < 40,
                "インスタンス \(at): 期待 \(want) 実際 (\(r),\(g),\(b)) -- アトラスの取り違え"
            )
        }
    }

    /// アイコンの上下がそのまま出ること（上下反転の検出）。
    func testIconIsNotUpsideDown() throws {
        let gpu = try XCTUnwrap(MetalMarkerRasterizer.createOrNull(tileSize: 64))
        let icons = [split(top: .red, bottom: .blue)]
        let atlas = try XCTUnwrap(gpu.makeAtlas(icons))
        let uv = atlas.uv[0]
        let instance = MetalMarkerRasterizer.Instance(
            left: 8, top: 8, width: 16, height: 16,
            u0: Float(uv.minX), v0: Float(uv.minY), u1: Float(uv.maxX), v1: Float(uv.maxY)
        )
        let png = try XCTUnwrap(gpu.renderPng(instances: [instance], atlas: atlas.texture, paddingPx: 0))
        let out = try pixels(png)
        let top = color(out, 16, 11)
        let bottom = color(out, 16, 21)
        XCTAssertGreaterThan(top.0, 180, "上半分が赤でない: \(top)")
        XCTAssertGreaterThan(bottom.2, 180, "下半分が青でない: \(bottom)")
    }

    /// 多行アトラス（9 枚 → 3x3）でも取り違えないこと。
    func testNineIconsKeepTheirColoursAcrossRows() throws {
        let gpu = try XCTUnwrap(MetalMarkerRasterizer.createOrNull(tileSize: 256))
        let hues: [CGFloat] = [0.0, 0.1, 0.2, 0.35, 0.5, 0.6, 0.7, 0.8, 0.9]
        let icons = hues.map { solid(UIColor(hue: $0, saturation: 1, brightness: 1, alpha: 1)) }
        let atlas = try XCTUnwrap(gpu.makeAtlas(icons))
        var instances: [MetalMarkerRasterizer.Instance] = []
        for at in 0..<9 {
            let uv = atlas.uv[at]
            instances.append(MetalMarkerRasterizer.Instance(
                left: Float(4 + (at % 5) * 40), top: Float(20 + (at / 5) * 60),
                width: 16, height: 16,
                u0: Float(uv.minX), v0: Float(uv.minY),
                u1: Float(uv.maxX), v1: Float(uv.maxY)
            ))
        }
        let png = try XCTUnwrap(gpu.renderPng(instances: instances, atlas: atlas.texture, paddingPx: 0))
        let out = try pixels(png)
        for at in 0..<9 {
            var want = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
            UIColor(hue: hues[at], saturation: 1, brightness: 1, alpha: 1)
                .getRed(&want.r, green: &want.g, blue: &want.b, alpha: &want.a)
            let (r, g, b, a) = color(out, 4 + (at % 5) * 40 + 8, 20 + (at / 5) * 60 + 8)
            XCTAssertGreaterThan(a, 200, "インスタンス \(at) が描かれていない")
            XCTAssertTrue(
                abs(r - Int(want.r * 255)) < 50 && abs(g - Int(want.g * 255)) < 50 && abs(b - Int(want.b * 255)) < 50,
                "インスタンス \(at): 期待 (\(Int(want.r * 255)),\(Int(want.g * 255)),\(Int(want.b * 255))) 実際 (\(r),\(g),\(b))"
            )
        }
    }

    /// 右端で一部だけはみ出すインスタンスは、はみ出さない部分が描かれること。
    /// 実機では右端のマーカーが丸ごと消えた。
    func testInstanceOverhangingTheRightEdgeStillDraws() throws {
        let size = 128
        let gpu = try XCTUnwrap(MetalMarkerRasterizer.createOrNull(tileSize: size))
        let icons = [solid(.red)]
        let atlas = try XCTUnwrap(gpu.makeAtlas(icons))
        let uv = atlas.uv[0]
        // 中心がタイル右端ちょうど: 左半分だけ見えるはず。
        let instance = MetalMarkerRasterizer.Instance(
            left: Float(size - 8), top: 40, width: 16, height: 16,
            u0: Float(uv.minX), v0: Float(uv.minY), u1: Float(uv.maxX), v1: Float(uv.maxY)
        )
        let png = try XCTUnwrap(gpu.renderPng(instances: [instance], atlas: atlas.texture, paddingPx: 0))
        let out = try pixels(png)
        let inside = color(out, size - 4, 48)
        XCTAssertGreaterThan(inside.3, 200, "右端にかかるインスタンスが消えた: \(inside)")
        XCTAssertGreaterThan(inside.0, 180, "色が違う: \(inside)")
    }

    /// 同じ入力から 2 回描いて同じ画素が出ること。実機の再現は走行ごとに
    /// 割れる境界が揺れた -- 非決定性はそれ自体が欠陥。
    func testSameInputsSamePixels() throws {
        let gpu = try XCTUnwrap(MetalMarkerRasterizer.createOrNull(tileSize: 256))
        let icons = (0..<7).map { solid(UIColor(hue: CGFloat($0) / 7.0, saturation: 1, brightness: 1, alpha: 1)) }
        let atlas = try XCTUnwrap(gpu.makeAtlas(icons))
        var instances: [MetalMarkerRasterizer.Instance] = []
        var seed = UInt64(9)
        func next() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Float(seed >> 40) / Float(1 << 24)
        }
        for at in 0..<200 {
            let uv = atlas.uv[at % icons.count]
            instances.append(MetalMarkerRasterizer.Instance(
                left: next() * 260 - 10, top: next() * 260 - 10, width: 16, height: 16,
                u0: Float(uv.minX), v0: Float(uv.minY), u1: Float(uv.maxX), v1: Float(uv.maxY)
            ))
        }
        let first = try XCTUnwrap(gpu.renderPng(instances: instances, atlas: atlas.texture, paddingPx: 0))
        let second = try XCTUnwrap(gpu.renderPng(instances: instances, atlas: atlas.texture, paddingPx: 0))
        XCTAssertEqual(first, second, "同じ入力で違う絵が出た")
    }
}
