import ImageIO
import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// `PolylineController.tiler` の配線とその場の変更。`PolygonTilingInPlaceTests` と
/// `PolygonControllerTilingTests` の線版で、js-sdk-core の `PolylineTilingInPlace.test.mjs`、
/// android-sdk-core の `PolylineTilerDeviceTest` と同じ内容。
///
/// - タイルにした線は `PolylineManager` に残す（タップは元の形で判定する）が、レンダラには渡さず、
///   エンティティの `polyline` は nil。しきい値を下回ったらネイティブ描画へ戻す。
/// - 色を変えたら触れたタイルだけ描き直し（他はキャッシュのまま）、テンプレートの版が上がる。
/// - geodesic にしたらタイルから外れてネイティブへ（地図からは消えていないので onAdded は呼ばない）。
final class PolylineTilingInPlaceTests: XCTestCase {
    private final class Renderer: AbstractPolylineOverlayRenderer<String> {
        var added: [String] = []
        var changed: [String] = []
        var removed: [String] = []
        override func createPolyline(state: PolylineState) async -> String? {
            added.append(state.id)
            return state.id
        }
        override func updatePolylineProperties(
            polyline: String, current: PolylineEntity<String>, prev: PolylineEntity<String>
        ) async -> String? {
            changed.append(current.state.id)
            return polyline
        }
        override func removePolyline(entity: PolylineEntity<String>) async {
            removed.append(entity.state.id)
        }
    }

    private let lat = 35.68, lng = 139.76

    private func segment(_ id: String, _ lat: Double, _ lng: Double, _ color: UIColor, geodesic: Bool = false) -> PolylineState {
        PolylineState(
            points: [GeoPoint(latitude: lat, longitude: lng), GeoPoint(latitude: lat, longitude: lng + 0.002)],
            id: id,
            strokeColor: color,
            strokeWidth: 6,
            geodesic: geodesic
        )
    }

    /// Three lines in central Tokyo (one z16 tile) and one in Osaka.
    private func tokyo() -> [PolylineState] {
        [
            segment("a", lat, lng, .red),
            segment("b", lat + 0.001, lng, .green),
            segment("c", lat + 0.002, lng, .blue),
            segment("osaka", 34.69, 135.5, .yellow),
        ]
    }

    private func tileAt(_ lat: Double, _ lng: Double, z: Int) -> TileRequest {
        let n = Double(1 << z)
        let s = sin(lat * .pi / 180)
        let x = Int((lng + 180) / 360 * n)
        let y = Int((0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * n)
        return TileRequest(x: x, y: y, z: z, pixelRatio: 1)
    }

    private func pixel(_ tiler: PolylineTiler, _ lat: Double, _ lng: Double, z: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
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
    private func isGreen(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Bool { p.1 > 100 && p.0 < 50 && p.3 > 200 }

    private func setup(_ min: Int = 3) -> (PolylineController<String, Renderer>, Renderer, PolylineTiler, Box) {
        let renderer = Renderer()
        let controller = PolylineController<String, Renderer>(polylineManager: PolylineManager<String>(), renderer: renderer)
        let tiler = PolylineTiler(options: PolylineTilingOptions(minPolylineCount: min))
        let templates = Box()
        tiler.onTemplate = { template, _ in templates.values.append(template) }
        controller.tiler = tiler
        return (controller, renderer, tiler, templates)
    }

    private final class Box { var values: [String?] = [] }

    /// Lets the tile set's coalesced update (16 ms on the main queue) run.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
        await MainActor.run {}
    }

    func testTiledLinesStayForTapsButNeverReachTheRenderer() async throws {
        let (controller, renderer, tiler, templates) = setup()
        let list = tokyo()
        await controller.add(data: list)
        XCTAssertEqual(renderer.added, [])
        XCTAssertEqual(controller.polylineManager.allEntities().count, 4)
        XCTAssertTrue(controller.polylineManager.allEntities().allSatisfy { $0.polyline == nil })
        XCTAssertTrue(isRed(try pixel(tiler, lat, lng + 0.001, z: 16)))
        XCTAssertNotNil(templates.values.last ?? nil)
        // Taps: against the original line.
        let hit = controller.findWithClosestPoint(position: GeoPoint(latitude: lat + 0.00002, longitude: lng + 0.001))
        XCTAssertEqual(hit?.entity.state.id, "a")
        XCTAssertEqual(hit?.closestPoint.latitude ?? 0, lat, accuracy: 1e-9)

        // Below the threshold: back to native drawing.
        await controller.add(data: Array(list.prefix(2)))
        XCTAssertEqual(Set(renderer.added), ["a", "b"])
        XCTAssertEqual(controller.polylineManager.allEntities().count, 2)
        XCTAssertTrue(controller.polylineManager.allEntities().allSatisfy { $0.polyline != nil })
        XCTAssertNil(templates.values.last ?? "not removed")

        // Over it again: into tiles, the native ones leave the map.
        await controller.add(data: list)
        XCTAssertEqual(Set(renderer.removed), ["a", "b"])
        XCTAssertTrue(controller.polylineManager.allEntities().allSatisfy { $0.polyline == nil })
        await controller.clear()
    }

    func testAColourChangeRedrawsOnlyTheTilesItTouchesAndBumpsTheVersion() async throws {
        let (controller, renderer, tiler, templates) = setup()
        let list = tokyo()
        await controller.add(data: list)
        let first = try XCTUnwrap(templates.values.last ?? nil)
        _ = try pixel(tiler, lat, lng + 0.001, z: 16)
        _ = try pixel(tiler, 34.69, 135.501, z: 16) // Osaka, now cached
        let cachedBefore = tiler.tileSet.renderer.cachedTileCount

        list[0].strokeColor = .green
        await controller.update(state: list[0])
        await settle()
        XCTAssertEqual(renderer.changed, [], "tiles, not the renderer")
        XCTAssertEqual(tiler.tileSet.renderer.cachedTileCount, cachedBefore - 1, "Osaka stays cached")
        let second = try XCTUnwrap(templates.values.last ?? nil)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.contains("/v1/") && second.contains("/v2/"), "\(first) → \(second)")
        XCTAssertTrue(isGreen(try pixel(tiler, lat, lng + 0.001, z: 16)))
        XCTAssertTrue(controller.polylineManager.getEntity("a")?.state === list[0])
        await controller.clear()
    }

    func testSettingGeodesicInPlaceMovesItToNativeDrawingWithoutOnAdded() async throws {
        let (controller, renderer, tiler, _) = setup()
        let list = tokyo()
        var onAdded: [String] = []
        for state in list { state.onAdded = { onAdded.append($0.id) } }
        await controller.add(data: list)
        XCTAssertEqual(onAdded.sorted(), ["a", "b", "c", "osaka"], "once each, in tiles")
        onAdded.removeAll()
        XCTAssertTrue(isRed(try pixel(tiler, lat, lng + 0.001, z: 16)))

        list[0].geodesic = true
        await controller.update(state: list[0])
        await settle()
        XCTAssertEqual(renderer.added, ["a"], "the map SDK draws it now")
        XCTAssertFalse(tiler.isTiled("a"))
        XCTAssertEqual(controller.polylineManager.getEntity("a")?.polyline, "a")
        XCTAssertEqual(try pixel(tiler, lat, lng + 0.001, z: 16).3, 0, "gone from the tile")
        XCTAssertTrue(isGreen(try pixel(tiler, lat + 0.001, lng + 0.001, z: 16)), "the next line stays")

        // Further changes go to the native line; the same list again changes nothing.
        list[0].strokeColor = .purple
        await controller.update(state: list[0])
        XCTAssertEqual(renderer.changed, ["a"])
        await controller.add(data: list)
        XCTAssertEqual(renderer.added, ["a"])
        XCTAssertEqual(renderer.removed, [])
        XCTAssertEqual(onAdded, [], "it never left the map")
        await controller.clear()
    }

    func testFewerThanTwoPointsInPlaceMovesItToNativeDrawing() async throws {
        let (controller, renderer, tiler, _) = setup()
        let list = tokyo()
        await controller.add(data: list)
        list[1].points = [GeoPoint(latitude: lat + 0.001, longitude: lng)]
        await controller.update(state: list[1])
        await settle()
        XCTAssertEqual(renderer.added, ["b"])
        XCTAssertFalse(tiler.isTiled("b"))
        await controller.clear()
    }

    func testClearRemovesTheTilesAndTheEntities() async {
        let (controller, _, tiler, templates) = setup()
        await controller.add(data: tokyo())
        await controller.clear()
        XCTAssertEqual(templates.values.count, 2)
        XCTAssertNil(templates.values[1])
        XCTAssertTrue(controller.polylineManager.allEntities().isEmpty)
        XCTAssertFalse(tiler.isTiled("a"))
    }

    func testTurningTilingOffMovesEveryLineToNativeDrawing() async {
        let (controller, renderer, tiler, templates) = setup()
        let list = tokyo()
        await controller.add(data: list)
        XCTAssertTrue(tiler.setOptions(.Disabled))
        await controller.add(data: list)
        XCTAssertEqual(Set(renderer.added), ["a", "b", "c", "osaka"])
        XCTAssertNil(templates.values.last ?? "not removed")
        await controller.clear()
    }
}
