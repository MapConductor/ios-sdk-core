import ImageIO
import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// タイルにできないポリゴン（geodesic・経度の幅 180° 以上・頂点 3 未満）は地図 SDK が描く。
///
/// タイルにするかは add（新しいリスト）でだけ決めていた。タイルで描いているポリゴンを
/// その場で geodesic=true にしたり、点を書き換えてタイルにできない形にしたりすると、
/// update はタイルの経路に入ったまま canTile を見直さず、直線のままタイルに描き続けた。
/// update で canTile を満たさなくなったら、タイルから外して地図 SDK に描かせる。
///
/// js-sdk-core の `PolygonTilingInPlace.test.mjs`、android-sdk-core の `PolygonTilerDeviceTest` と同じ内容。
final class PolygonTilingInPlaceTests: XCTestCase {
    private final class Renderer: AbstractPolygonOverlayRenderer<String> {
        var added: [String] = []
        var changed: [String] = []
        var removed: [String] = []
        override func createPolygon(state: PolygonState) async -> String? {
            added.append(state.id)
            return state.id
        }
        override func updatePolygonProperties(
            polygon: String, current: PolygonEntity<String>, prev: PolygonEntity<String>
        ) async -> String? {
            changed.append(current.state.id)
            return polygon
        }
        override func removePolygon(entity: PolygonEntity<String>) async {
            removed.append(entity.state.id)
        }
    }

    private let lat = 35.68, lng = 139.76

    private func square(_ id: String, _ lat: Double, _ lng: Double, _ color: UIColor, geodesic: Bool = false) -> PolygonState {
        let s = 0.002
        return PolygonState(
            points: [
                GeoPoint(latitude: lat, longitude: lng),
                GeoPoint(latitude: lat, longitude: lng + s),
                GeoPoint(latitude: lat + s, longitude: lng + s),
                GeoPoint(latitude: lat + s, longitude: lng),
            ],
            id: id,
            strokeColor: .clear,
            fillColor: color,
            geodesic: geodesic
        )
    }

    /// Three squares in central Tokyo (one z14 tile) and one in Osaka.
    private func tokyo() -> [PolygonState] {
        [
            square("a", lat, lng, .red),
            square("b", lat, lng + 0.003, .green),
            square("c", lat + 0.003, lng, .blue),
            square("osaka", 34.69, 135.5, .yellow),
        ]
    }

    private func tileAt(_ lat: Double, _ lng: Double, z: Int) -> TileRequest {
        let n = Double(1 << z)
        let s = sin(lat * .pi / 180)
        let x = Int((lng + 180) / 360 * n)
        let y = Int((0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * n)
        return TileRequest(x: x, y: y, z: z, pixelRatio: 1)
    }

    /// The pixel at a coordinate inside the tile at `z`, as RGBA.
    private func pixel(_ tiler: PolygonTiler, _ lat: Double, _ lng: Double, z: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let request = tileAt(lat, lng, z: z)
        guard let png = tiler.tileSet.renderer.renderTile(request: request) else { return (0, 0, 0, 0) }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let scale = 256.0 * Double(1 << z)
        let s = sin(lat * .pi / 180)
        let wx = (lng + 180) / 360 * scale - Double(request.x * 256)
        let wy = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * scale - Double(request.y * 256)
        let k = image.width / 256
        let i = (Int(wy) * k * image.width + Int(wx) * k) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    private func isRed(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Bool { p.0 > 200 && p.1 < 50 && p.2 < 50 && p.3 > 200 }
    private func isGreen(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Bool { p.1 > 200 && p.0 < 50 && p.3 > 200 }

    private func setup() -> (PolygonController<String, Renderer>, Renderer, PolygonTiler) {
        let renderer = Renderer()
        let controller = PolygonController<String, Renderer>(polygonManager: PolygonManager<String>(), renderer: renderer)
        let tiler = PolygonTiler(options: PolygonTilingOptions(minPolygonCount: 3))
        tiler.onTemplate = { _, _ in }
        controller.tiler = tiler
        return (controller, renderer, tiler)
    }

    /// Lets the tile set's coalesced update (16 ms on the main queue) run.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
        await MainActor.run {}
    }

    func testCanTileRefusesGeodesicWideAndDegenerate() {
        XCTAssertTrue(PolygonTileSet.canTile(square("x", 0, 0, .red)))
        XCTAssertFalse(PolygonTileSet.canTile(square("x", 0, 0, .red, geodesic: true)))
        let p = { (lat: Double, lng: Double) in GeoPoint(latitude: lat, longitude: lng) }
        XCTAssertFalse(PolygonTileSet.canTile(PolygonState(points: [p(0, -100), p(0, 80), p(10, 0)])))
        XCTAssertTrue(PolygonTileSet.canTile(PolygonState(points: [p(0, -90), p(0, 89), p(10, 0)])))
        XCTAssertFalse(PolygonTileSet.canTile(PolygonState(points: [p(0, 0), p(1, 1)])))
    }

    func testInAMixedListOnlyTheGeodesicOneIsDrawnNatively() async throws {
        let (controller, renderer, tiler) = setup()
        let g = square("g", lat + 0.003, lng + 0.003, .magenta, geodesic: true)
        await controller.add(data: tokyo() + [g])
        XCTAssertEqual(renderer.added, ["g"])
        XCTAssertFalse(tiler.isTiled("g"))
        XCTAssertTrue(tiler.isTiled("a"))
        XCTAssertEqual(try pixel(tiler, lat + 0.004, lng + 0.004, z: 16).3, 0, "not in the tiles")
        XCTAssertTrue(isRed(try pixel(tiler, lat + 0.001, lng + 0.001, z: 16)))
        await controller.clear()
    }

    /// Tiles everything, applies `change` to "a" in place, and checks it moved to native drawing.
    private func checkMovesToNative(
        _ change: (PolygonState) -> Void
    ) async throws -> (PolygonController<String, Renderer>, Renderer, PolygonTiler, [PolygonState]) {
        let (controller, renderer, tiler) = setup()
        let list = tokyo()
        await controller.add(data: list)
        XCTAssertEqual(renderer.added, [], "all tiled at first")
        XCTAssertTrue(isRed(try pixel(tiler, lat + 0.001, lng + 0.001, z: 16)))
        _ = try pixel(tiler, 34.691, 135.501, z: 16) // Osaka, now cached
        let cachedBefore = tiler.tileSet.renderer.cachedTileCount

        change(list[0])
        await controller.update(state: list[0])
        await settle()

        XCTAssertEqual(renderer.added, ["a"], "the map SDK draws it now")
        XCTAssertFalse(tiler.isTiled("a"))
        XCTAssertFalse(tiler.tiledStates().contains { $0.id == "a" })
        XCTAssertEqual(controller.polygonManager.getEntity("a")?.polygon, "a")
        // Only the Tokyo tile it was in was dropped; Osaka's stays cached.
        XCTAssertEqual(tiler.tileSet.renderer.cachedTileCount, cachedBefore - 1)
        // Gone from the tile; the polygon next to it is still there.
        XCTAssertEqual(try pixel(tiler, lat + 0.001, lng + 0.001, z: 16).3, 0)
        XCTAssertTrue(isGreen(try pixel(tiler, lat + 0.001, lng + 0.004, z: 16)))
        return (controller, renderer, tiler, list)
    }

    func testSettingGeodesicInPlaceMovesItToNativeDrawing() async throws {
        let (controller, renderer, tiler, list) = try await checkMovesToNative { $0.geodesic = true }

        // Taps still find it, now drawn natively; the tiled ones too.
        let hit = controller.find(position: GeoPoint(latitude: lat + 0.001, longitude: lng + 0.001))
        XCTAssertEqual(hit?.state.id, "a")
        XCTAssertEqual(hit?.polygon, "a")
        XCTAssertEqual(controller.find(position: GeoPoint(latitude: lat + 0.001, longitude: lng + 0.004))?.state.id, "b")

        // Further in-place changes go to the native polygon.
        list[0].fillColor = .purple
        await controller.update(state: list[0])
        XCTAssertEqual(renderer.changed, ["a"])

        // The same list again: it stays native, nothing is added or removed.
        await controller.add(data: list)
        XCTAssertEqual(renderer.added, ["a"])
        XCTAssertEqual(renderer.removed, [])
        XCTAssertFalse(tiler.isTiled("a"))
        await controller.clear()
    }

    func testPointsSpanningHalfTheWorldInPlaceMoveItToNativeDrawing() async throws {
        let (controller, _, _, _) = try await checkMovesToNative { [lat, lng] state in
            state.points = [
                GeoPoint(latitude: lat, longitude: lng),
                GeoPoint(latitude: lat, longitude: lng + 0.002),
                GeoPoint(latitude: lat + 0.002, longitude: lng + 0.002),
                GeoPoint(latitude: lat + 0.002, longitude: -60),
            ]
        }
        await controller.clear()
    }

    func testFewerThanThreePointsInPlaceMoveItToNativeDrawing() async throws {
        let (controller, _, _, _) = try await checkMovesToNative { [lat, lng] state in
            state.points = [GeoPoint(latitude: lat, longitude: lng), GeoPoint(latitude: lat, longitude: lng + 0.002)]
        }
        await controller.clear()
    }

    func testATileableChangeStaysInTheTiles() async throws {
        let (controller, renderer, tiler) = setup()
        let list = tokyo()
        await controller.add(data: list)
        list[0].fillColor = .green
        await controller.update(state: list[0])
        await settle()
        XCTAssertEqual(renderer.added, [])
        XCTAssertTrue(tiler.isTiled("a"))
        XCTAssertTrue(isGreen(try pixel(tiler, lat + 0.001, lng + 0.001, z: 16)))
        await controller.clear()
    }
}
