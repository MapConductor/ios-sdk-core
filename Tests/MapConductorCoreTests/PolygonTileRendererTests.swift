import CoreGraphics
import ImageIO
import UIKit
import XCTest

@testable import MapConductorCore

/// ポリゴンのタイル描画（`PolygonTileRenderer`）を、出てきたタイルの画素で固定する。
///
/// js-sdk-core の tile-sw.js「Polygon tiles」節、android-sdk の `PolygonTileRenderer` と同じ描き方:
/// 巻きの正規化（外周と穴を逆向きにして nonzero）、ズームごとの簡略化（画素格子に丸める →
/// 重複を捨てる → Douglas-Peucker 0.5 px → 1 px 未満は点）、4 px 未満は枠線なし、
/// グリッド索引、変更は重なるタイルだけ作り直す。
final class PolygonTileRendererTests: XCTestCase {
    private let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor
    private let blue = UIColor(red: 0, green: 0, blue: 1, alpha: 1).cgColor
    private let clear = UIColor.clear.cgColor

    // MARK: helpers

    /// World pixel (256-px tiles) of a coordinate at `z`.
    private func worldPx(_ lat: Double, _ lng: Double, z: Int) -> (x: Double, y: Double) {
        let scale = 256.0 * Double(1 << z)
        let s = sin(lat * .pi / 180)
        return ((lng + 180) / 360 * scale, (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * scale)
    }

    /// The coordinate at a world pixel.
    private func latLng(_ x: Double, _ y: Double, z: Int) -> (lat: Double, lng: Double) {
        let scale = 256.0 * Double(1 << z)
        let lng = x / scale * 360 - 180
        let n = .pi - 2 * .pi * y / scale
        return (atan(sinh(n)) * 180 / .pi, lng)
    }

    /// A rectangle given in world pixels at `z`, as flat lat/lng, counter-clockwise on the map.
    private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, z: Int, clockwise: Bool = false) -> [Double] {
        var corners = [(x0, y1), (x1, y1), (x1, y0), (x0, y0)]
        if clockwise { corners.reverse() }
        return corners.flatMap { c -> [Double] in
            let p = latLng(c.0, c.1, z: z)
            return [p.lat, p.lng]
        }
    }

    private func shape(_ rings: [[Double]], fill: CGColor?, stroke: CGColor? = nil, width: Double = 0) -> PolygonTileShape {
        PolygonTileShape(rings: rings, fill: fill, stroke: stroke, strokeWidth: width)
    }

    private struct Pixels {
        let width: Int
        let bytes: [UInt8]
        func rgba(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
        func isRed(_ x: Int, _ y: Int) -> Bool { let p = rgba(x, y); return p.0 > 200 && p.2 < 50 && p.3 > 200 }
        func isBlue(_ x: Int, _ y: Int) -> Bool { let p = rgba(x, y); return p.2 > 200 && p.0 < 50 && p.3 > 200 }
        func isEmpty(_ x: Int, _ y: Int) -> Bool { rgba(x, y).3 == 0 }
        var opaqueCount: Int { stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 0 }.count }
        var blueCount: Int {
            var n = 0
            for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 2] > 128 && bytes[i] < 80 { n += 1 }
            return n
        }
    }

    private func decode(_ png: Data) throws -> Pixels {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(width: image.width, bytes: bytes)
    }

    private func render(_ renderer: PolygonTileRenderer, z: Int, x: Int, y: Int) throws -> Pixels? {
        guard let png = renderer.renderTile(request: TileRequest(x: x, y: y, z: z)) else { return nil }
        return try decode(png)
    }

    // Tile (z=16) that holds downtown Boston; every shape below is placed in its pixels.
    private let z = 16
    private var tile: (x: Int, y: Int) {
        let p = worldPx(42.3555, -71.0605, z: z)
        return (Int(p.x / 256), Int(p.y / 256))
    }
    private var origin: (x: Double, y: Double) { (Double(tile.x) * 256, Double(tile.y) * 256) }

    /// A rectangle given in this tile's own pixels.
    private func local(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, clockwise: Bool = false) -> [Double] {
        rect(origin.x + x0, origin.y + y0, origin.x + x1, origin.y + y1, z: z, clockwise: clockwise)
    }

    // MARK: fill and winding

    func testFillsInsideAndLeavesOutsideTransparent() throws {
        let renderer = PolygonTileRenderer()
        renderer.setPolygons([shape([local(40, 40, 120, 120)], fill: red)])
        let pixels = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isRed(80, 80))
        XCTAssertTrue(pixels.isEmpty(10, 10))
        XCTAssertTrue(pixels.isEmpty(200, 200))
    }

    func testHoleIsEmptyWhicheverWayTheRingsAreWound() throws {
        // 外周と穴が同じ向きでも、逆向きでも、穴は空く（描く前に向きをそろえる）。
        for (outerCW, holeCW) in [(false, false), (false, true), (true, false), (true, true)] {
            let renderer = PolygonTileRenderer()
            renderer.setPolygons([shape(
                [local(20, 20, 200, 200, clockwise: outerCW), local(80, 80, 140, 140, clockwise: holeCW)],
                fill: red
            )])
            let pixels = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
            XCTAssertTrue(pixels.isRed(50, 50), "outer cw=\(outerCW) hole cw=\(holeCW)")
            XCTAssertTrue(pixels.isEmpty(110, 110), "outer cw=\(outerCW) hole cw=\(holeCW)")
        }
    }

    func testEmptyTileIsNilSoTheServerAnswersTransparent() throws {
        let renderer = PolygonTileRenderer()
        renderer.setPolygons([shape([local(40, 40, 120, 120)], fill: red)])
        XCTAssertNil(renderer.renderTile(request: TileRequest(x: tile.x + 3, y: tile.y, z: z)))
        // 色が透明で枠線も無いものは、重なっていても描くものが無い。
        let invisible = PolygonTileRenderer()
        invisible.setPolygons([shape([local(40, 40, 120, 120)], fill: clear)])
        XCTAssertNil(invisible.renderTile(request: TileRequest(x: tile.x, y: tile.y, z: z)))
    }

    func testDrawsAtTheRequestedPixelRatio() throws {
        let renderer = PolygonTileRenderer(pixelRatio: 2)
        renderer.setPolygons([shape([local(40, 40, 120, 120)], fill: red)])
        let pixels = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertEqual(pixels.width, 512)
        XCTAssertTrue(pixels.isRed(160, 160))
        XCTAssertTrue(pixels.isEmpty(60, 60))
    }

    // MARK: draw order

    func testLaterPolygonsAreDrawnOnTop() throws {
        let renderer = PolygonTileRenderer()
        renderer.setPolygons([
            shape([local(20, 20, 150, 150)], fill: red),
            shape([local(100, 100, 220, 220)], fill: blue),
        ])
        let pixels = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isBlue(120, 120))
        XCTAssertTrue(pixels.isRed(40, 40))
    }

    // MARK: outline

    func testOutlineIsDrawnOnTheOutlineOnly() throws {
        let renderer = PolygonTileRenderer()
        renderer.setPolygons([shape(
            [local(40, 40, 200, 200), local(100, 100, 140, 140)],
            fill: clear, stroke: blue, width: 2
        )])
        let pixels = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isBlue(40, 120), "外周の左辺")
        XCTAssertTrue(pixels.isEmpty(100, 120), "穴の辺には枠線を引かない")
        XCTAssertTrue(pixels.isEmpty(70, 70))
    }

    func testOutlineIsLeftOutUnderFourPixels() throws {
        // 3 px の区画は枠線を描かない（描くと区画全体が枠線の色になる）。10 px なら描く。
        let small = PolygonTileRenderer()
        small.setPolygons([shape([local(100, 100, 103, 103)], fill: clear, stroke: blue, width: 1)])
        XCTAssertNil(small.renderTile(request: TileRequest(x: tile.x, y: tile.y, z: z)))

        let large = PolygonTileRenderer()
        large.setPolygons([shape([local(100, 100, 110, 110)], fill: clear, stroke: blue, width: 1)])
        let pixels = try XCTUnwrap(try render(large, z: z, x: tile.x, y: tile.y))
        // 1 px の枠線は画素の境目に乗るので、隣り合う 2 列が半分ずつの濃さになる（どちらも 128 前後）。
        // 濃さではなく、描かれた画素の数で見る。
        XCTAssertGreaterThan(pixels.opaqueCount, 10)
    }

    func testOutlineCrossingTheTileEdgeIsDrawnInTheNeighbour() throws {
        // 右隣のタイルにある図形の枠線が、こちらの右端に 2 px かかる。
        let renderer = PolygonTileRenderer()
        renderer.setPolygons([shape([local(257, 40, 300, 200)], fill: clear, stroke: blue, width: 6)])
        let pixels = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isBlue(255, 120))
    }

    // MARK: simplification

    func testUnderAPixelIsDrawnAsOnePixel() throws {
        // z16 で 0.4 px の建物 → 1 px の点。
        let renderer = PolygonTileRenderer()
        renderer.setPolygons([shape([local(100.1, 100.1, 100.5, 100.5)], fill: red)])
        let pixels = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertEqual(pixels.opaqueCount, 1)
        XCTAssertTrue(pixels.isRed(100, 100))
    }

    func testSimplificationSnapsDropsRepeatsAndThinsToHalfAPixel() {
        // 1000 頂点の円（半径 0.0001 度 ≒ z10 で 0.07 px、z16 で 4.8 px）。
        let ring = (0..<1000).flatMap { k -> [Double] in
            let a = 2 * Double.pi * Double(k) / 1000
            return [42.3555 + 0.0001 * sin(a), -71.0605 + 0.0001 * cos(a)]
        }
        let polygon = try! XCTUnwrap(PolygonTileRenderer.Polygon(PolygonTileShape(rings: [ring], fill: red, stroke: nil, strokeWidth: 0)))
        if case .dot = PolygonTileRenderer.simplify(polygon, scale: 256 * Double(1 << 10)) {} else {
            XCTFail("1 px 未満は点になる")
        }
        guard case let .rings(rings, outlined) = PolygonTileRenderer.simplify(polygon, scale: 256 * Double(1 << 16)) else {
            return XCTFail("z16 では輪郭が残る")
        }
        XCTAssertTrue(outlined, "直径 9.6 px")
        let n = rings[0].count / 2
        XCTAssertLessThan(n, 40, "画素格子に丸めて間引くと 1000 頂点が数十に減る: \(n)")
        XCTAssertGreaterThanOrEqual(n, 3)
        // 丸めたあとの点は整数。
        XCTAssertTrue(rings[0].allSatisfy { $0 == $0.rounded() })
    }

    func testDouglasPeuckerKeepsCornersAndDropsNearlyStraightPoints() {
        let points: [Double] = [0, 0, 5, 0.3, 10, 0, 10, 10, 0, 10]
        XCTAssertEqual(PolygonTileRenderer.douglasPeucker(points, tolerance: 0.5), [0, 0, 10, 0, 10, 10, 0, 10])
        XCTAssertEqual(PolygonTileRenderer.douglasPeucker(points, tolerance: 0.2), points)
    }

    // MARK: index

    func testFindsPolygonsInManyCellsAndOnesSpanningTheGrid() throws {
        // 1000 個の小さな四角を z16 タイルの中に並べ、大きな 1 個（索引の「大」リスト行き）を下に敷く。
        var shapes: [PolygonTileShape] = []
        let big = rect(origin.x - 50_000, origin.y - 50_000, origin.x + 50_000, origin.y + 50_000, z: z)
        shapes.append(shape([big], fill: blue))
        for i in 0..<1000 {
            let x = Double(i % 40) * 6 + 4, y = Double(i / 40) * 6 + 4
            shapes.append(shape([local(x, y, x + 4, y + 4)], fill: red))
        }
        let renderer = PolygonTileRenderer()
        renderer.setPolygons(shapes)
        let pixels = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isRed(6, 6))
        XCTAssertTrue(pixels.isRed(6 + 6 * 39, 6 + 6 * 24))
        XCTAssertTrue(pixels.isBlue(3, 3), "大きなポリゴンは隙間に見える")
        XCTAssertTrue(pixels.isBlue(250, 250))
        // 遠く（別の z12 セル）のタイルにも大きなポリゴンは届く。
        let far = try XCTUnwrap(try render(renderer, z: z, x: tile.x + 100, y: tile.y + 100))
        XCTAssertTrue(far.isBlue(128, 128))
    }

    // MARK: in-place changes

    func testAChangeRedrawsOnlyTheTilesItTouches() throws {
        let renderer = PolygonTileRenderer()
        renderer.setPolygons([
            shape([local(40, 40, 120, 120)], fill: red),
            shape([local(256 + 40, 40, 256 + 120, 120)], fill: red),
        ])
        _ = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        let neighbour = try XCTUnwrap(renderer.renderTile(request: TileRequest(x: tile.x + 1, y: tile.y, z: z)))
        XCTAssertEqual(renderer.cachedTileCount, 2)

        renderer.update([(index: 0, shape: shape([local(40, 40, 120, 120)], fill: blue))])
        XCTAssertEqual(renderer.cachedTileCount, 1, "変えたポリゴンに重なるタイルだけ捨てる")
        let after = try XCTUnwrap(try render(renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(after.isBlue(80, 80))
        let neighbourAgain = try XCTUnwrap(renderer.renderTile(request: TileRequest(x: tile.x + 1, y: tile.y, z: z)))
        XCTAssertEqual(neighbour, neighbourAgain, "触れていないタイルはキャッシュから同じものが返る")
    }

    func testMovingAPolygonFindsItAtItsNewPlace() throws {
        let renderer = PolygonTileRenderer()
        renderer.setPolygons([shape([local(40, 40, 120, 120)], fill: red)])
        _ = try render(renderer, z: z, x: tile.x, y: tile.y)
        // 40 タイル先（索引のセルは z12 タイル = 16 タイル分なので、別のセル）へ動かす。
        let far = 256.0 * 40
        renderer.update([(index: 0, shape: shape([local(far + 40, 40, far + 120, 120)], fill: red))])
        XCTAssertNil(renderer.renderTile(request: TileRequest(x: tile.x, y: tile.y, z: z)))
        let moved = try XCTUnwrap(try render(renderer, z: z, x: tile.x + 40, y: tile.y))
        XCTAssertTrue(moved.isRed(80, 80))
    }

    func testCancelledRenderThrowsInsteadOfAnsweringEmpty() {
        var shapes: [PolygonTileShape] = []
        for i in 0..<600 {
            let x = Double(i % 30) * 8, y = Double(i / 30) * 8
            shapes.append(shape([local(x, y, x + 6, y + 6)], fill: red))
        }
        let renderer = PolygonTileRenderer()
        renderer.setPolygons(shapes)
        XCTAssertThrowsError(try renderer.renderTile(request: TileRequest(x: tile.x, y: tile.y, z: z), isCancelled: { true }))
    }
}
