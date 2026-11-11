import CoreGraphics
import ImageIO
import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// サークルのタイル描画（`ShapeTileRenderer` の円、`CircleTilePainter`）を、出てきたタイルの画素で固定する。
///
/// js-sdk-core の tile-sw.js「Shape tiles」節の円、android-sdk の `CircleTileRendererTest` と同じ描き方:
/// 半径は地上の長さ（z+1 で画素は 2 倍）、縁幅は画面上の幅（ズームに依らない）、縁は輪郭の上に中心を合わせる、
/// 直径 1 px 未満は 1 点、直径 4 px 未満は縁なし、メルカトルで歪む所（高緯度・大きな円）はネイティブと同じ
/// 128 角形、タイルの外にはみ出す分も描く（隣のタイルも同じ円を同じ座標で描く）、実効 zIndex → 渡された順。
final class CircleTileRendererTests: XCTestCase {
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
        /// The columns of row `y` that are solidly red / drawn at all.
        func redColumns(y: Int) -> [Int] { (0..<width).filter { isRed($0, y) } }
        func drawnColumns(y: Int) -> [Int] { (0..<width).filter { rgba($0, y).3 > 200 } }
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

    // The z16 tile that holds downtown Boston; every circle below is placed in its pixels.
    private let z = 16
    private var tile: (x: Int, y: Int) {
        let p = worldPx(42.3555, -71.0605, z: z)
        return (Int(p.x / 256), Int(p.y / 256))
    }
    private var origin: (x: Double, y: Double) { (Double(tile.x) * 256, Double(tile.y) * 256) }

    /// The lat/lng at this tile's own pixel (at `z`).
    private func local(_ x: Double, _ y: Double) -> (lat: Double, lng: Double) {
        latLng(origin.x + x, origin.y + y, z: z)
    }

    /// Metres per pixel at `lat` and zoom `z` (Web Mercator, 256 px tiles).
    private func metersPerPx(_ lat: Double, z: Int) -> Double {
        Earth.circumferenceMeters * cos(lat * .pi / 180) / (256 * Double(1 << z))
    }

    /// A circle centred on this tile's pixel (x, y) whose radius is `radiusPx` pixels at `z`.
    private func circleShape(
        _ x: Double, _ y: Double, radiusPx: Double, fill: CGColor?, stroke: CGColor?, width: Double,
        geodesic: Bool = true
    ) -> CircleTileShape {
        let c = local(x, y)
        return CircleTileShape(
            latitude: c.lat, longitude: c.lng, radiusMeters: radiusPx * metersPerPx(c.lat, z: z),
            geodesic: geodesic, fill: fill, stroke: stroke, strokeWidth: width
        )
    }

    private func renderer(_ shapes: [CircleTileShape], ratio: Int = 1) -> ShapeTileRenderer {
        let r = ShapeTileRenderer(pixelRatio: ratio)
        r.setShapes(shapes.map { ShapeTileRenderer.Shape($0) })
        return r
    }

    // MARK: fill, outline and position

    func testSubpixelOverlapKeepsTopCircleAndZoomRestoresBoth() throws {
        let r = renderer([
            circleShape(100.25, 100.25, radiusPx: 0.2, fill: UIColor.blue.withAlphaComponent(0.5).cgColor, stroke: nil, width: 0),
            circleShape(100.25, 100.25, radiusPx: 0.2, fill: UIColor.red.withAlphaComponent(0.5).cgColor, stroke: nil, width: 0),
        ])
        let small = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertEqual(small.rgba(100, 100).2, 0)
        XCTAssertLessThanOrEqual(abs(Int(small.rgba(100, 100).3) - 128), 1)
        let large = try XCTUnwrap(try render(r, z: z + 4, x: tile.x * 16 + 6, y: tile.y * 16 + 6))
        XCTAssertGreaterThan(large.rgba(68, 68).2, 0)
        XCTAssertGreaterThan(large.rgba(68, 68).3, 128)
    }

    func testTheCentreIsTheFillAndTheEdgeIsTheOutlineCentredOnIt() throws {
        let r = renderer([circleShape(128, 128, radiusPx: 40, fill: blue, stroke: red, width: 4)])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isBlue(128, 128))
        XCTAssertTrue(pixels.isBlue(128 + 36, 128))
        // 縁は半径 40 の輪郭の上に 4 px（内側 2・外側 2）: 166〜169 列。
        XCTAssertEqual(pixels.redColumns(y: 128).filter { $0 > 128 }, [166, 167, 168, 169])
        XCTAssertEqual(pixels.redColumns(y: 128).filter { $0 < 128 }, [86, 87, 88, 89])
        XCTAssertTrue(pixels.isEmpty(128 + 43, 128))
        // 上下も同じ（ボストンの 70 m の円はメルカトルでほとんど歪まない）。
        XCTAssertTrue(pixels.isRed(128, 128 - 40))
        XCTAssertTrue(pixels.isRed(128, 128 + 39))
        XCTAssertTrue(pixels.isEmpty(128, 128 - 43))
    }

    func testTheOutlineIsInPointsTimesTheScreenScale() throws {
        let r = renderer([circleShape(128, 128, radiusPx: 40, fill: blue, stroke: red, width: 4)], ratio: 2)
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertEqual(pixels.width, 512)
        XCTAssertTrue(pixels.isBlue(256, 256))
        XCTAssertEqual(pixels.redColumns(y: 256).filter { $0 > 256 }, Array(332...339), "4 pt × 2 = 8 px, on the 80 px radius")
    }

    func testTransparentColoursAreNotDrawnAndAnEmptyTileIsEmpty() throws {
        let invisible = renderer([circleShape(128, 128, radiusPx: 40, fill: clear, stroke: clear, width: 4)])
        XCTAssertNil(try render(invisible, z: z, x: tile.x, y: tile.y), "nothing visible: an empty tile")
        let noStroke = renderer([circleShape(128, 128, radiusPx: 40, fill: blue, stroke: red, width: 0)])
        let pixels = try XCTUnwrap(try render(noStroke, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.redColumns(y: 128).isEmpty)
        XCTAssertTrue(pixels.isBlue(128 + 38, 128))
        let outlineOnly = renderer([circleShape(128, 128, radiusPx: 40, fill: clear, stroke: red, width: 2)])
        let ring = try XCTUnwrap(try render(outlineOnly, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(ring.isEmpty(128, 128))
        XCTAssertTrue(ring.isRed(168, 128))
        // A tile nowhere near any circle.
        XCTAssertNil(try render(noStroke, z: z, x: tile.x + 3, y: tile.y))
    }

    // MARK: tile edges

    func testACircleAcrossATileEdgeIsDrawnWholeOnBothSides() throws {
        // 中心はタイルの右端から 6 px、半径 30 px。右のタイルには残り 24 px ぶんが同じ形で出る。
        let r = renderer([circleShape(250, 128, radiusPx: 30, fill: blue, stroke: red, width: 2)])
        let left = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        let right = try XCTUnwrap(try render(r, z: z, x: tile.x + 1, y: tile.y))
        XCTAssertTrue(left.isBlue(255, 128))
        XCTAssertTrue(right.isBlue(0, 128))
        XCTAssertTrue(right.isBlue(20, 128))
        XCTAssertEqual(right.redColumns(y: 128), [23, 24], "the far edge at 250 + 30 − 256")
        XCTAssertEqual(left.redColumns(y: 128), [219, 220], "the near edge at 250 − 30")
        XCTAssertTrue(right.isEmpty(27, 128))
        // The row just above the centre: continuous across the seam.
        for y in [100, 110, 128, 146, 156] {
            XCTAssertEqual(left.rgba(255, y).3 > 0, right.rgba(0, y).3 > 0, "row \(y)")
        }
        // The circle reaches the right tile only through its outline at the top and bottom.
        XCTAssertTrue(right.isEmpty(0, 128 - 32))
    }

    // MARK: zoom

    func testTheRadiusDoublesWithEachZoomAndTheOutlineDoesNot() throws {
        let shape = circleShape(128, 128, radiusPx: 20, fill: blue, stroke: red, width: 4)
        let r = renderer([shape])
        let at16 = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        // z17: the same centre is at (256, 256) of the 2×2 children, i.e. the top-left corner of child (1, 1).
        let child = (x: tile.x * 2 + 1, y: tile.y * 2)
        let at17 = try XCTUnwrap(try render(r, z: z + 1, x: child.x, y: child.y))
        // Row through the centre of the z17 child tile: the centre is at its left edge (x = 0), y = 256 → 255 of the upper child.
        let y17 = 255
        let drawn16 = at16.drawnColumns(y: 128).filter { $0 >= 128 }
        let drawn17 = at17.drawnColumns(y: y17)
        XCTAssertEqual(Double(drawn16.count), 20 + 2, accuracy: 1)
        XCTAssertEqual(Double(drawn17.count), 40 + 2, accuracy: 1)
        XCTAssertEqual(at16.redColumns(y: 128).filter { $0 > 128 }, [146, 147, 148, 149])
        XCTAssertEqual(at17.redColumns(y: y17), [38, 39, 40, 41], "the outline is as wide at every zoom")
    }

    func testUnderOnePixelAcrossItIsOnePixel() throws {
        let r = renderer([circleShape(100.5, 60.5, radiusPx: 0.3, fill: blue, stroke: red, width: 2)])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertEqual(pixels.opaqueCount, 1)
        XCTAssertTrue(pixels.isBlue(100, 60), "the fill colour")
        let outline = renderer([circleShape(100.5, 60.5, radiusPx: 0.3, fill: clear, stroke: red, width: 2)])
        let dot = try XCTUnwrap(try render(outline, z: z, x: tile.x, y: tile.y))
        XCTAssertEqual(dot.opaqueCount, 1)
        XCTAssertTrue(dot.isRed(100, 60), "the outline colour when the fill is invisible")
    }

    func testUnderFourPixelsAcrossItHasNoOutline() throws {
        let r = renderer([circleShape(128, 128, radiusPx: 1.5, fill: blue, stroke: red, width: 4)])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        XCTAssertTrue(pixels.isBlue(128, 128) || pixels.rgba(128, 128).2 > 100)
        XCTAssertEqual(pixels.redColumns(y: 128), [])
        XCTAssertEqual(pixels.redColumns(y: 127), [])
        let big = renderer([circleShape(128, 128, radiusPx: 2.5, fill: blue, stroke: red, width: 1)])
        let outlined = try XCTUnwrap(try render(big, z: z, x: tile.x, y: tile.y))
        XCTAssertFalse((120...136).allSatisfy { x in !(outlined.rgba(x, 128).0 > 100) }, "5 px across: outlined")
    }

    // MARK: shape

    func testACityCircleIsATrueCircleAtEveryZoom() throws {
        let shape = try XCTUnwrap(ShapeTileRenderer.Shape(
            CircleTileShape(latitude: 42.3555, longitude: -71.0605, radiusMeters: 15, geodesic: true, fill: blue, stroke: red, strokeWidth: 1)
        ))
        for zoom in [10, 14, 18, 22] {
            switch ShapeTileRenderer.simplify(shape, scale: 256 * pow(2, Double(zoom))) {
            case .arc, .dot: break
            default: XCTFail("z\(zoom): not an arc")
            }
        }
    }

    func testAtHighLatitudesItIsTheNative128Gon() throws {
        // 70°N, r = 200 km: the north side is much longer than the south on the map.
        let lat = 70.0, lng = 20.0, radius = 200_000.0
        let zoom = 5
        let shape = try XCTUnwrap(ShapeTileRenderer.Shape(
            CircleTileShape(latitude: lat, longitude: lng, radiusMeters: radius, geodesic: true, fill: nil, stroke: red, strokeWidth: 3)
        ))
        guard case .rings = ShapeTileRenderer.simplify(shape, scale: 256 * Double(1 << zoom)) else {
            return XCTFail("not a ring")
        }
        let r = ShapeTileRenderer(pixelRatio: 1)
        r.setShapes([shape])
        var cache: [String: Pixels] = [:]
        let ring = circleToRing(center: GeoPoint(latitude: lat, longitude: lng), radiusMeters: radius, geodesic: true)
        XCTAssertEqual(ring.count, 128)
        var hits = 0
        for point in ring {
            let w = worldPx(point.latitude, point.longitude, z: zoom)
            let tx = Int(w.x / 256), ty = Int(w.y / 256)
            let key = "\(tx)/\(ty)"
            if cache[key] == nil, let p = try render(r, z: zoom, x: tx, y: ty) { cache[key] = p }
            guard let pixels = cache[key] else { continue }
            let px = Int(w.x) - tx * 256, py = Int(w.y) - ty * 256
            // On the outline: a solid pixel within one of the vertex (snapping moves it by up to half a pixel).
            let near = (max(0, px - 1)...min(255, px + 1)).contains { x in
                (max(0, py - 1)...min(255, py + 1)).contains { y in pixels.isRed(x, y) }
            }
            if near { hits += 1 }
        }
        XCTAssertEqual(hits, 128, "every vertex of the native 128-gon is on the outline")
        // A true circle of the east radius would miss the north vertex by many pixels.
        let centre = worldPx(lat, lng, z: zoom)
        let northPx = worldPx(ring[0].latitude, ring[0].longitude, z: zoom)
        let eastPx = worldPx(ring[32].latitude, ring[32].longitude, z: zoom)
        XCTAssertGreaterThan(abs((centre.y - northPx.y) - (eastPx.x - centre.x)), 5)
    }

    // MARK: order

    func testTheHigherZIndexIsDrawnOverAndWithoutOneTheSouthernCircle() async throws {
        func pixel(_ states: [CircleState], _ lat: Double, _ lng: Double) async throws -> (UInt8, UInt8, UInt8, UInt8) {
            let set = CircleTileSet(pixelRatio: 1)
            _ = await set.setCircles(states)
            defer { set.dispose() }
            let w = worldPx(lat, lng, z: z)
            let tx = Int(w.x / 256), ty = Int(w.y / 256)
            let pixels = try XCTUnwrap(try render(set.renderer, z: z, x: tx, y: ty))
            return pixels.rgba(Int(w.x) - tx * 256, Int(w.y) - ty * 256)
        }
        let lat = 42.3555, lng = -71.0605
        let solidRed = UIColor(red: 1, green: 0, blue: 0, alpha: 1), solidBlue = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
        let a = CircleState(center: GeoPoint(latitude: lat, longitude: lng), radiusMeters: 40, strokeWidth: 0, fillColor: solidRed, id: "a", zIndex: 1)
        let b = CircleState(center: GeoPoint(latitude: lat, longitude: lng + 0.0002), radiusMeters: 40, strokeWidth: 0, fillColor: solidBlue, id: "b", zIndex: 0)
        let overlap = (lat, lng + 0.0001)
        // b comes later, but a's zIndex is higher.
        let p1 = try await pixel([a, b], overlap.0, overlap.1)
        XCTAssertTrue(p1.0 > 200 && p1.2 < 50, "\(p1)")
        // The same zIndex: the order given.
        let a0 = a.copy(zIndex: 0)
        let p2 = try await pixel([a0, b], overlap.0, overlap.1)
        XCTAssertTrue(p2.2 > 200 && p2.0 < 50, "\(p2)")
        // No zIndex: the automatic one from the centre, the southern circle on top, whatever the order.
        let north = CircleState(center: GeoPoint(latitude: lat + 0.0002, longitude: lng), radiusMeters: 40, strokeWidth: 0, fillColor: solidRed, id: "n")
        let south = CircleState(center: GeoPoint(latitude: lat, longitude: lng), radiusMeters: 40, strokeWidth: 0, fillColor: solidBlue, id: "s")
        for order in [[north, south], [south, north]] {
            let p = try await pixel(order, lat + 0.0001, lng)
            XCTAssertTrue(p.2 > 200 && p.0 < 50, "\(order.map(\.id)): \(p)")
        }
    }

    func testTranslucentCirclesBlendOverEachOther() throws {
        let half = UIColor(red: 0, green: 0, blue: 1, alpha: 0.5).cgColor
        let r = renderer([
            circleShape(120, 128, radiusPx: 20, fill: half, stroke: nil, width: 0),
            circleShape(136, 128, radiusPx: 20, fill: half, stroke: nil, width: 0),
        ])
        let pixels = try XCTUnwrap(try render(r, z: z, x: tile.x, y: tile.y))
        let single = pixels.rgba(105, 128).3, both = pixels.rgba(128, 128).3
        XCTAssertEqual(Double(single), 128, accuracy: 2)
        XCTAssertEqual(Double(both), 191, accuracy: 2, "0.5 over 0.5")
    }
    func testNationwideCirclesRenderAtWorldAndOverviewZooms() throws {
        let renderer = ShapeTileRenderer(pixelRatio: 1)
        let shapes = try (0..<10_000).map { i in
            try XCTUnwrap(ShapeTileRenderer.Shape(CircleTileShape(
                latitude: 30 + Double(i % 100) * 0.15,
                longitude: -120 + Double(i / 100) * 0.5,
                radiusMeters: 40_000, geodesic: true,
                fill: red, stroke: red, strokeWidth: 0.5
            )))
        }
        renderer.setShapes(shapes)
        let world = try XCTUnwrap(render(renderer, z: 0, x: 0, y: 0))
        XCTAssertGreaterThan(world.opaqueCount, 0)
        let overview = try XCTUnwrap(render(renderer, z: 4, x: 3, y: 6))
        XCTAssertGreaterThan(overview.opaqueCount, 0)
    }

    func testInteriorTileMatchesOrdinaryPolygonPixelsWithTransparency() throws {
        let latitude = 39.0, longitude = -98.0, radius = 40_000.0, zoom = 14
        let projected = worldPx(latitude, longitude, z: zoom)
        let x = Int(projected.x / 256), y = Int(projected.y / 256)
        let fill = UIColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 0.035).cgColor
        let circle = try XCTUnwrap(ShapeTileRenderer.Shape(CircleTileShape(
            latitude: latitude, longitude: longitude, radiusMeters: radius,
            geodesic: true, fill: fill, stroke: red, strokeWidth: 0.5
        )))
        let ring = circleToRing(center: GeoPoint(latitude: latitude, longitude: longitude), radiusMeters: radius, geodesic: true)
        let polygon = try XCTUnwrap(ShapeTileRenderer.Shape(PolygonTileShape(
            rings: [ring.flatMap { [$0.latitude, $0.longitude] }], fill: fill, stroke: red, strokeWidth: 0.5
        )))
        let fast = ShapeTileRenderer(pixelRatio: 2)
        let reference = ShapeTileRenderer(pixelRatio: 2)
        fast.setShapes([circle, circle, circle])
        reference.setShapes([polygon, polygon, polygon])
        let actual = try XCTUnwrap(render(fast, z: zoom, x: x, y: y))
        let expected = try XCTUnwrap(render(reference, z: zoom, x: x, y: y))
        XCTAssertEqual(actual.bytes, expected.bytes)
    }

}
