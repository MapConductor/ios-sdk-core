import CoreGraphics
import ImageIO
import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// ポリラインのタイル描画（`ShapeTileRenderer` の線）を、出てきたタイルの画素で固定する。
///
/// js-sdk-core の tile-sw.js「Shape tiles」節、android-sdk の `PolylineTileRendererTest` と同じ描き方:
/// 線幅は画面上の幅（pt × 画面の倍率）でズームに依らない、タイルの外にはみ出す分も描く
/// （隣のタイルも同じ線を同じ座標で描くので境目で切れない）、画素格子に丸める → 重複を捨てる →
/// Douglas-Peucker 0.5 px（両端は残す）、1 点に潰れた線は線幅の丸、端と曲がりは丸、
/// zIndex → 渡された順。`PolygonTileRendererTests` と 1 対 1。
final class PolylineTileRendererTests: XCTestCase {
    private let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor
    private let blue = UIColor(red: 0, green: 0, blue: 1, alpha: 1).cgColor
    private let clear = UIColor.clear.cgColor

    // MARK: helpers

    private func worldPx(_ lat: Double, _ lng: Double, z: Int) -> (x: Double, y: Double) {
        let scale = 256.0 * Double(1 << z)
        let s = sin(lat * .pi / 180)
        return ((lng + 180) / 360 * scale, (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * scale)
    }

    private func latLng(_ x: Double, _ y: Double, z: Int) -> (lat: Double, lng: Double) {
        let scale = 256.0 * Double(1 << z)
        let lng = x / scale * 360 - 180
        let n = .pi - 2 * .pi * y / scale
        return (atan(sinh(n)) * 180 / .pi, lng)
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
        /// The rows of column `x` that are solidly red.
        func redRows(x: Int) -> [Int] { (0..<width).filter { isRed(x, $0) } }
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

    private func render(_ renderer: ShapeTileRenderer, z: Int, x: Int, y: Int) throws -> Pixels? {
        guard let png = renderer.renderTile(request: TileRequest(x: x, y: y, z: z)) else { return nil }
        return try decode(png)
    }

    // The z16 tile that holds downtown Boston; every line below is placed in its pixels.
    private let z = 16
    private var tile: (x: Int, y: Int) {
        let p = worldPx(42.3555, -71.0605, z: z)
        return (Int(p.x / 256), Int(p.y / 256))
    }
    private var origin: (x: Double, y: Double) { (Double(tile.x) * 256, Double(tile.y) * 256) }

    /// A path given in this tile's own pixels (at `z`), as flat lat/lng.
    private func local(_ points: [(Double, Double)], z: Int? = nil) -> [Double] {
        let zz = z ?? self.z
        let k = Double(1 << (zz - self.z))
        return points.flatMap { p -> [Double] in
            let ll = latLng((origin.x + p.0) * k, (origin.y + p.1) * k, z: zz)
            return [ll.lat, ll.lng]
        }
    }

    private func line(_ points: [Double], _ color: CGColor?, width: Double) -> ShapeTileRenderer.Shape? {
        ShapeTileRenderer.Shape(PolylineTileShape(points: points, stroke: color, strokeWidth: width))
    }

    private func renderer(_ shapes: [ShapeTileRenderer.Shape?], ratio: Int = 1) -> ShapeTileRenderer {
        let r = ShapeTileRenderer(pixelRatio: ratio)
        r.setShapes(shapes)
        return r
    }

    // MARK: width and position

    func testAHorizontalLineIsDrawnOnItsRowAsWideAsItsStroke() throws {
        // y = 100、幅 4 pt → 98〜101 行の 4 行。
        let r = renderer([line(local([(20, 100), (200, 100)]), red, width: 4)])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertEqual(pixels.redRows(x: 100), [98, 99, 100, 101])
        XCTAssertTrue(pixels.isEmpty(100, 96))
        XCTAssertTrue(pixels.isEmpty(100, 103))
        XCTAssertTrue(pixels.isEmpty(230, 100), "線の先には描かない（丸い端の 2 px の先）")
    }

    func testTheWidthIsInPointsTimesTheScreenScale() throws {
        let r = renderer([line(local([(20, 100), (200, 100)]), red, width: 4)], ratio: 2)
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertEqual(pixels.width, 512)
        XCTAssertEqual(pixels.redRows(x: 200), Array(196...203), "4 pt × 2 = 8 px")
    }

    func testTheWidthOnScreenIsTheSameAtEveryZoom() throws {
        // 同じ線を z16 と z17 で描く。線幅（画素）は変わらない。
        let points = local([(20, 100.0), (200, 100.0)])
        let r = renderer([line(points, red, width: 4)])
        let at16 = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        // z17 では同じ線が左上の子タイルの y = 200 に来る。
        let at17 = try XCTUnwrap(try render(r, z: z + 1, x: tile.x * 2, y: tile.y * 2))
        XCTAssertEqual(at16.redRows(x: 50), [98, 99, 100, 101])
        XCTAssertEqual(at17.redRows(x: 100), [198, 199, 200, 201])
    }

    // MARK: tile edges

    func testALineCrossingATileEdgeIsContinuousOnBothSides() throws {
        // x = 200 から右隣のタイルの x = 56 まで、y = 100、幅 6。
        let r = renderer([line(local([(200, 100), (312, 100)]), red, width: 6)])
        let left = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        let right = try XCTUnwrap(try render(r, z: z, x: tile.x + 1, y: tile.y))
        XCTAssertEqual(left.redRows(x: 255), Array(97...102))
        XCTAssertEqual(right.redRows(x: 0), Array(97...102), "境目で同じ行・同じ太さ")
    }

    func testALineJustOverTheEdgeOverhangsIntoThisTile() throws {
        // 右隣のタイルの x = 1 を通る縦線（幅 6）は、こちらの右端 2 px にかかる。
        let r = renderer([line(local([(257, 40), (257, 200)]), red, width: 6)])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isRed(255, 120))
        XCTAssertTrue(pixels.isRed(254, 120))
        XCTAssertTrue(pixels.isEmpty(253, 120))
    }

    // MARK: ends, dots and simplification

    func testEndsAreRound() throws {
        // 右端 x = 100、幅 10 の線。端は半径 5 の半円: 103 列の中心行は塗られ、
        // 角（104 列, 中心から 4 行上）は塗られない（四角い端なら塗られる）。
        let r = renderer([line(local([(20, 100), (100, 100)]), red, width: 10)])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isRed(103, 100))
        XCTAssertLessThan(pixels.rgba(104, 96).3, 128)
        XCTAssertTrue(pixels.isEmpty(106, 100))
    }

    func testALineUnderAPixelIsADotAsWideAsTheLine() throws {
        // z16 で 0.3 px の線（幅 5）→ 直径 5 の丸。
        let r = renderer([line(local([(100.1, 100.1), (100.4, 100.2)]), red, width: 5)])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isRed(100, 100))
        XCTAssertTrue(pixels.isRed(98, 100))
        XCTAssertTrue(pixels.isEmpty(104, 100))
        let n = pixels.opaqueCount
        XCTAssertTrue((12...36).contains(n), "π × 2.5² ≈ 20: \(n)")
    }

    func testAHairlineDotIsStillOnePixel() throws {
        let r = renderer([line(local([(100.2, 100.2), (100.3, 100.3)]), red, width: 0.2)])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertGreaterThanOrEqual(pixels.opaqueCount, 1)
    }

    func testSimplificationKeepsBothEndsAndDropsNearlyStraightPoints() throws {
        // 1000 点のほぼ直線（0.2 px 以内の揺れ）は両端だけになる。
        let pts = (0...1000).map { k -> (Double, Double) in
            (20 + Double(k) * 0.2, 100 + 0.2 * sin(Double(k)))
        }
        let shape = try XCTUnwrap(line(local(pts), red, width: 1))
        guard case let .path(path) = ShapeTileRenderer.simplify(shape, scale: 256 * Double(1 << z)) else {
            return XCTFail("a path")
        }
        XCTAssertEqual(path.count, 4, "\(path.count / 2) points")
        XCTAssertEqual(path[0], origin.x + 20)
        XCTAssertEqual(path[2], origin.x + 220)
        // 折れ曲がりは残る。
        let bent = try XCTUnwrap(line(local([(20, 100), (60, 100.1), (100, 100), (100, 160)]), red, width: 1))
        guard case let .path(bentPath) = ShapeTileRenderer.simplify(bent, scale: 256 * Double(1 << z)) else {
            return XCTFail("a path")
        }
        XCTAssertEqual(bentPath.count / 2, 3)
    }

    // MARK: order and colour

    func testZIndexThenTheOrderGivenDecideWhatIsOnTop() async throws {
        // 青 (zIndex 1) を先、赤 (zIndex 0) を後に渡しても、交点は青。
        let set = PolylineTileSet(pixelRatio: 1)
        func state(_ id: String, _ pts: [(Double, Double)], _ color: UIColor, _ zIndex: Int) -> PolylineState {
            let flat = local(pts)
            let points = stride(from: 0, to: flat.count, by: 2).map { GeoPoint(latitude: flat[$0], longitude: flat[$0 + 1]) }
            return PolylineState(points: points, id: id, strokeColor: color, strokeWidth: 6, zIndex: zIndex)
        }
        _ = await set.setPolylines([
            state("blue", [(128, 20), (128, 230)], .blue, 1),
            state("red", [(20, 128), (230, 128)], .red, 0),
            state("red2", [(20, 60), (230, 60)], .red, 2),
        ])
        let pixels = try XCTUnwrap(try render(set.renderer, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isBlue(128, 128), "zIndex 1 over zIndex 0")
        XCTAssertTrue(pixels.isRed(128, 60), "zIndex 2 over zIndex 1")
        set.dispose()
    }

    func testTransparentOrZeroWidthLinesAreNotDrawnAndAnEmptyTileIsNil() throws {
        let r = renderer([line(local([(20, 100), (200, 100)]), red, width: 4)])
        XCTAssertNil(r.renderTile(request: TileRequest(x: tile.x + 3, y: tile.y, z: z)), "何も無いタイルは「空」")
        let invisible = renderer([
            line(local([(20, 100), (200, 100)]), clear, width: 4),
            line(local([(20, 120), (200, 120)]), red, width: 0),
        ])
        XCTAssertNil(invisible.renderTile(request: TileRequest(x: tile.x, y: tile.y, z: z)))
    }

    func testFewerThanTwoPointsIsNoShape() {
        XCTAssertNil(line(local([(20, 100)]), red, width: 4))
    }

    // MARK: in-place changes

    func testAChangeRedrawsOnlyTheTilesItTouches() throws {
        let r = renderer([
            line(local([(20, 100), (200, 100)]), red, width: 4),
            line(local([(256 + 20, 100), (256 + 200, 100)]), red, width: 4),
        ])
        _ = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        let neighbour = try XCTUnwrap(r.renderTile(request: TileRequest(x: tile.x + 1, y: tile.y, z: z)))
        XCTAssertEqual(r.cachedTileCount, 2)

        r.update([(index: 0, shape: line(local([(20, 100), (200, 100)]), blue, width: 4))])
        XCTAssertEqual(r.cachedTileCount, 1, "変えた線に重なるタイルだけ捨てる")
        let after = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(after.isBlue(100, 100))
        XCTAssertEqual(neighbour, try XCTUnwrap(r.renderTile(request: TileRequest(x: tile.x + 1, y: tile.y, z: z))))
    }

    func testAWiderLineDropsTheTilesItNowOverhangs() throws {
        // 境目から 3 px の線を太くすると、隣のタイルにもかかるので隣も捨てる。
        let r = renderer([line(local([(20, 100), (253, 100)]), red, width: 2)])
        _ = try render(r, z: z, x: tile.x, y: tile.y)
        XCTAssertNil(r.renderTile(request: TileRequest(x: tile.x + 1, y: tile.y, z: z)))
        r.update([(index: 0, shape: line(local([(20, 100), (253, 100)]), red, width: 12))])
        let right = try XCTUnwrap(try render(r, z: z, x: tile.x + 1, y: tile.y))
        XCTAssertTrue(right.isRed(1, 100), "端の丸が隣に 3 px かかる")
    }
}
