import ImageIO
import UIKit
import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// `CircleController.tiler` の配線とその場の変更。`PolylineTilingInPlaceTests` の円版で、
/// js-sdk-core の `CircleTilingInPlace.test.mjs`、android-sdk-core の `CircleTilerDeviceTest` と同じ内容。
///
/// - タイルにした円は `CircleManager` に残す（タップは元の円で判定する）が、レンダラには渡さず、
///   エンティティの `circle` は nil。しきい値を下回ったらネイティブ描画へ戻す。
/// - 色を変えたら触れたタイルだけ描き直し（他はキャッシュのまま）、テンプレートの版が上がる。
/// - 日付変更線へ動かしたらタイルから外れてネイティブへ（地図からは消えていないので onAdded は呼ばない）。
final class CircleTilingInPlaceTests: XCTestCase {
    private final class Renderer: AbstractCircleOverlayRenderer<String> {
        var added: [String] = []
        var changed: [String] = []
        var removed: [String] = []
        override func createCircle(state: CircleState) async -> String? {
            added.append(state.id)
            return state.id
        }
        override func updateCircleProperties(
            circle: String, current: CircleEntity<String>, prev: CircleEntity<String>
        ) async -> String? {
            changed.append(current.state.id)
            return circle
        }
        override func removeCircle(entity: CircleEntity<String>) async {
            removed.append(entity.state.id)
        }
    }

    private let lat = 35.68, lng = 139.76

    private func circle(_ id: String, _ lat: Double, _ lng: Double, _ color: UIColor) -> CircleState {
        CircleState(
            center: GeoPoint(latitude: lat, longitude: lng),
            radiusMeters: 30,
            strokeColor: color,
            strokeWidth: 2,
            fillColor: color,
            id: id
        )
    }

    /// Three circles in central Tokyo (one z16 tile) and one in Osaka.
    private func tokyo() -> [CircleState] {
        [
            circle("a", lat, lng, .red),
            circle("b", lat + 0.001, lng, .green),
            circle("c", lat + 0.002, lng, .blue),
            circle("osaka", 34.69, 135.5, .yellow),
        ]
    }

    private func tileAt(_ lat: Double, _ lng: Double, z: Int) -> TileRequest {
        let n = Double(1 << z)
        let s = sin(lat * .pi / 180)
        let x = Int((lng + 180) / 360 * n)
        let y = Int((0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * n)
        return TileRequest(x: x, y: y, z: z, pixelRatio: 1)
    }

    private func pixel(_ tiler: CircleTiler, _ lat: Double, _ lng: Double, z: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
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

    private final class Box { var values: [String?] = [] }

    private func setup(_ min: Int = 3) -> (CircleController<String, Renderer>, Renderer, CircleTiler, Box) {
        let renderer = Renderer()
        let controller = CircleController<String, Renderer>(circleManager: CircleManager<String>(), renderer: renderer)
        let tiler = CircleTiler(options: CircleTilingOptions(minCircleCount: min))
        let templates = Box()
        tiler.onTemplate = { template, _ in templates.values.append(template) }
        controller.tiler = tiler
        return (controller, renderer, tiler, templates)
    }

    /// Lets the tile set's coalesced update (16 ms on the main queue) run.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
        await MainActor.run {}
    }

    func testTiledCirclesStayForTapsButNeverReachTheRenderer() async throws {
        let (controller, renderer, tiler, templates) = setup()
        let list = tokyo()
        var onAdded: [String] = []
        for state in list { state.onAdded = { onAdded.append($0.id) } }
        await controller.add(data: list)
        XCTAssertEqual(renderer.added, [])
        XCTAssertEqual(onAdded.sorted(), ["a", "b", "c", "osaka"], "once each, in tiles")
        XCTAssertEqual(controller.circleManager.allEntities().count, 4)
        XCTAssertTrue(controller.circleManager.allEntities().allSatisfy { $0.circle == nil })
        XCTAssertTrue(isRed(try pixel(tiler, lat, lng, z: 16)))
        XCTAssertNotNil(templates.values.last ?? nil)
        // Taps: against the original circle.
        XCTAssertEqual(controller.find(position: GeoPoint(latitude: lat + 0.0001, longitude: lng))?.state.id, "a")

        // Below the threshold: back to native drawing (still on the map: no onAdded).
        onAdded.removeAll()
        await controller.add(data: Array(list.prefix(2)))
        XCTAssertEqual(Set(renderer.added), ["a", "b"])
        XCTAssertEqual(controller.circleManager.allEntities().count, 2)
        XCTAssertTrue(controller.circleManager.allEntities().allSatisfy { $0.circle != nil })
        XCTAssertNil(templates.values.last ?? "not removed")
        XCTAssertEqual(onAdded, [])

        // Over it again: into tiles, the native ones leave the map.
        await controller.add(data: list)
        XCTAssertEqual(Set(renderer.removed), ["a", "b"])
        XCTAssertTrue(controller.circleManager.allEntities().allSatisfy { $0.circle == nil })
        XCTAssertEqual(onAdded.sorted(), ["c", "osaka"], "only those that were off the map")
        await controller.clear()
    }

    func testAColourChangeRedrawsOnlyTheTilesItTouchesAndBumpsTheVersion() async throws {
        let (controller, renderer, tiler, templates) = setup()
        let list = tokyo()
        await controller.add(data: list)
        let first = try XCTUnwrap(templates.values.last ?? nil)
        _ = try pixel(tiler, lat, lng, z: 16)
        _ = try pixel(tiler, 34.69, 135.5, z: 16) // Osaka, now cached
        let cachedBefore = tiler.tileSet.renderer.cachedTileCount

        list[0].fillColor = .green
        list[0].strokeColor = .green
        await controller.update(state: list[0])
        await settle()
        XCTAssertEqual(renderer.changed, [], "tiles, not the renderer")
        XCTAssertEqual(tiler.tileSet.renderer.cachedTileCount, cachedBefore - 1, "Osaka stays cached")
        let second = try XCTUnwrap(templates.values.last ?? nil)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.contains("/v1/") && second.contains("/v2/"), "\(first) → \(second)")
        XCTAssertTrue(isGreen(try pixel(tiler, lat, lng, z: 16)))
        XCTAssertTrue(controller.circleManager.getEntity("a")?.state === list[0])
        await controller.clear()
    }

    func testARadiusChangeIsDrawnAndHitInPlace() async throws {
        let (controller, _, tiler, _) = setup()
        let list = tokyo()
        await controller.add(data: list)
        let outside = Spherical.computeOffset(origin: GeoPoint(latitude: lat, longitude: lng), distance: 60, heading: 270)
        XCTAssertNil(controller.find(position: outside))
        XCTAssertEqual(try pixel(tiler, outside.latitude, outside.longitude, z: 16).3, 0)
        list[0].radiusMeters = 80
        await controller.update(state: list[0])
        await settle()
        XCTAssertEqual(controller.find(position: outside)?.state.id, "a")
        XCTAssertTrue(isRed(try pixel(tiler, outside.latitude, outside.longitude, z: 16)))
        await controller.clear()
    }

    func testMovingOntoTheAntimeridianMovesItToNativeDrawingWithoutOnAdded() async throws {
        let (controller, renderer, tiler, _) = setup()
        let list = tokyo()
        var onAdded: [String] = []
        for state in list { state.onAdded = { onAdded.append($0.id) } }
        await controller.add(data: list)
        onAdded.removeAll()
        XCTAssertTrue(isRed(try pixel(tiler, lat, lng, z: 16)))

        list[0].center = GeoPoint(latitude: 0, longitude: 179.9999)
        await controller.update(state: list[0])
        await settle()
        XCTAssertEqual(renderer.added, ["a"], "the map SDK draws it now")
        XCTAssertFalse(tiler.isTiled("a"))
        XCTAssertEqual(controller.circleManager.getEntity("a")?.circle, "a")
        XCTAssertEqual(try pixel(tiler, lat, lng, z: 16).3, 0, "gone from the tile")
        XCTAssertTrue(isGreen(try pixel(tiler, lat + 0.001, lng, z: 16)), "the next circle stays")

        // Further changes go to the native circle; the same list again changes nothing.
        list[0].fillColor = .purple
        await controller.update(state: list[0])
        XCTAssertEqual(renderer.changed, ["a"])
        await controller.add(data: list)
        XCTAssertEqual(renderer.added, ["a"])
        XCTAssertEqual(renderer.removed, [])
        XCTAssertEqual(onAdded, [], "it never left the map")
        await controller.clear()
    }

    func testARadiusOfZeroInPlaceMovesItToNativeDrawing() async throws {
        let (controller, renderer, tiler, _) = setup()
        let list = tokyo()
        await controller.add(data: list)
        list[1].radiusMeters = 0
        await controller.update(state: list[1])
        await settle()
        XCTAssertEqual(renderer.added, ["b"])
        XCTAssertFalse(tiler.isTiled("b"))
        await controller.clear()
    }

    func testClearRemovesTheTilesAndTheEntities() async {
        let (controller, renderer, tiler, templates) = setup()
        await controller.add(data: tokyo())
        await controller.clear()
        XCTAssertEqual(templates.values.count, 2)
        XCTAssertNil(templates.values[1])
        XCTAssertTrue(controller.circleManager.allEntities().isEmpty)
        XCTAssertFalse(tiler.isTiled("a"))
        XCTAssertEqual(renderer.removed, [], "nothing native to remove")
    }

    func testTurningTilingOffMovesEveryCircleToNativeDrawing() async {
        let (controller, renderer, tiler, templates) = setup()
        let list = tokyo()
        await controller.add(data: list)
        XCTAssertTrue(tiler.setOptions(.Disabled))
        await controller.add(data: list)
        XCTAssertEqual(Set(renderer.added), ["a", "b", "c", "osaka"])
        XCTAssertNil(templates.values.last ?? "not removed")
        await controller.clear()
    }

    func testDestroyUnregistersTheTilesWithoutTellingTheProvider() async {
        let (controller, _, tiler, templates) = setup()
        await controller.add(data: tokyo())
        let before = templates.values.count
        controller.destroy()
        XCTAssertNil(tiler.currentTemplate())
        XCTAssertEqual(templates.values.count, before)
    }
}
