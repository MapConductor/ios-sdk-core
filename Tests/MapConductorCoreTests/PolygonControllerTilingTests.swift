import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// `PolygonController.tiler` の配線。js-sdk-core の `PolygonController` と同じ規則:
///
/// - タイルにしたポリゴンは `PolygonManager` に残す（タップは元の形で判定する）が、
///   レンダラには渡さず、エンティティの `polygon` は nil。
/// - しきい値を下回ったら、タイルにしていたものをネイティブ描画へ戻す。
/// - タイルにしたポリゴンのその場の変更はタイルへ（レンダラは呼ばない）。
final class PolygonControllerTilingTests: XCTestCase {
    private final class Renderer: AbstractPolygonOverlayRenderer<String> {
        var onMap = Set<String>()
        var changed = 0
        override func createPolygon(state: PolygonState) async -> String? {
            onMap.insert(state.id)
            return state.id
        }
        override func updatePolygonProperties(
            polygon: String, current: PolygonEntity<String>, prev: PolygonEntity<String>
        ) async -> String? {
            changed += 1
            return polygon
        }
        override func removePolygon(entity: PolygonEntity<String>) async {
            onMap.remove(entity.state.id)
        }
    }

    private func states(_ count: Int) -> [PolygonState] {
        (0..<count).map { i in
            let lat = 42.30 + Double(i / 100) * 0.001, lng = -71.10 + Double(i % 100) * 0.001
            return PolygonState(
                points: [
                    GeoPoint(latitude: lat, longitude: lng),
                    GeoPoint(latitude: lat, longitude: lng + 0.0005),
                    GeoPoint(latitude: lat + 0.0005, longitude: lng + 0.0005),
                    GeoPoint(latitude: lat + 0.0005, longitude: lng),
                ],
                id: "p\(i)",
                fillColor: .red
            )
        }
    }

    func testTiledPolygonsStayForTapsButNeverReachTheRenderer() async throws {
        let renderer = Renderer()
        let controller = PolygonController<String, Renderer>(polygonManager: PolygonManager<String>(), renderer: renderer)
        let tiler = PolygonTiler(options: PolygonTilingOptions(minPolygonCount: 10))
        var templates: [String?] = []
        tiler.onTemplate = { template, _ in templates.append(template) }
        controller.tiler = tiler

        let all = states(20)
        await controller.add(data: all)
        XCTAssertTrue(renderer.onMap.isEmpty)
        XCTAssertEqual(controller.polygonManager.allEntities().count, 20)
        XCTAssertTrue(controller.polygonManager.allEntities().allSatisfy { $0.polygon == nil })
        XCTAssertNotNil(templates.last ?? nil)
        // 元の形でタップを判定する
        let hit = controller.find(position: GeoPoint(latitude: 42.30025, longitude: -71.09975))
        XCTAssertEqual(hit?.state.id, "p0")

        // 下回ったらネイティブへ戻る（残ったものは描かれ、消えたものは忘れる）
        await controller.add(data: Array(all.prefix(5)))
        XCTAssertEqual(renderer.onMap, Set((0..<5).map { "p\($0)" }))
        XCTAssertEqual(controller.polygonManager.allEntities().count, 5)
        XCTAssertTrue(controller.polygonManager.allEntities().allSatisfy { $0.polygon != nil })
        XCTAssertNil(templates.last ?? "not removed")

        // また届いたらタイルへ（ネイティブで描いていたものは地図から外す）
        await controller.add(data: all)
        XCTAssertTrue(renderer.onMap.isEmpty)
        XCTAssertEqual(controller.polygonManager.allEntities().count, 20)
    }

    func testAnInPlaceChangeOfATiledPolygonGoesToTheTiles() async throws {
        let renderer = Renderer()
        let controller = PolygonController<String, Renderer>(polygonManager: PolygonManager<String>(), renderer: renderer)
        let tiler = PolygonTiler(options: PolygonTilingOptions(minPolygonCount: 10))
        let changed = expectation(description: "a new template after the change")
        var initial: String?
        tiler.onTemplate = { template, _ in
            if initial == nil { initial = template } else if template != initial { changed.fulfill() }
        }
        controller.tiler = tiler
        let all = states(20)
        await controller.add(data: all)

        all[3].fillColor = .blue
        await controller.update(state: all[3])
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(renderer.changed, 0)
        XCTAssertTrue(controller.polygonManager.getEntity("p3")?.state === all[3])
    }

    func testClearRemovesTheTiles() async {
        let renderer = Renderer()
        let controller = PolygonController<String, Renderer>(polygonManager: PolygonManager<String>(), renderer: renderer)
        let tiler = PolygonTiler(options: PolygonTilingOptions(minPolygonCount: 10))
        var templates: [String?] = []
        tiler.onTemplate = { template, _ in templates.append(template) }
        controller.tiler = tiler
        await controller.add(data: states(20))
        await controller.clear()
        XCTAssertEqual(templates.count, 2)
        XCTAssertNil(templates[1])
        XCTAssertTrue(controller.polygonManager.allEntities().isEmpty)
        XCTAssertFalse(tiler.isTiled("p0"))
    }

    func testTapsPickTheTappedPolygonAmongManyQuickly() async {
        // 10 万件のうち 1 件を引くのに、全件の state を読まない。
        let manager = PolygonManager<String>()
        let all = states(10_000)
        for state in all { manager.registerEntity(PolygonEntity(polygon: nil, state: state)) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 {
            XCTAssertEqual(manager.find(position: GeoPoint(latitude: 42.30525, longitude: -71.09475))?.state.id, "p505")
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / 20
        XCTAssertLessThan(ms, 50, String(format: "%.1f ms per tap", ms))
    }
}
