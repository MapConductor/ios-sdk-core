import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// 1 枚の地図に載るラスターレイヤーは 3 系統ある。アプリの RasterLayer（コレクタ経由の
/// `add(data:)`）、マーカータイル、ポリゴンタイル（mc-polygon-tiles）。
/// js-sdk-core の `RasterLayerCoexistence.test.mjs`、android-sdk の
/// `RasterLayerCoexistenceTest` と 1 対 1 で対応する。
///
/// ## なぜここを固定するか
///
/// web では SDK が自分で載せるタイルをアプリのレイヤー一覧と同じ経路で載せ外ししていた
/// プロバイダがあり、片方を載せるともう片方が消えた。SDK が載せるレイヤーは
/// `upsert` / `removeById` で扱い、`add(data:)` はアプリのレイヤーだけを入れ替える。
final class RasterLayerCoexistenceTests: XCTestCase {
    private final class Renderer: AbstractRasterLayerOverlayRenderer<String> {
        var onMap = Set<String>()
        override func createLayer(state: RasterLayerState) async -> String? {
            onMap.insert(state.id)
            return state.id
        }
        override func updateLayerProperties(
            layer: String, current: RasterLayerEntity<String>, prev: RasterLayerEntity<String>
        ) async -> String? { layer }
        override func removeLayer(entity: RasterLayerEntity<String>) async {
            onMap.remove(entity.state.id)
        }
    }

    private func layer(_ id: String) -> RasterLayerState {
        RasterLayerState(source: .urlTemplate(template: "https://example.com/\(id)/{z}/{x}/{y}.png"), id: id)
    }

    private func markerTiles(_ version: Int) -> RasterLayerState {
        RasterLayerState(source: .urlTemplate(template: "http://127.0.0.1:1/tiles/m/256/v\(version)/{z}/{x}/{y}.png"), id: "mc-marker-tiles")
    }

    func testAppLayersMarkerTilesAndPolygonTilesDoNotRemoveEachOther() async {
        let renderer = Renderer()
        let controller = RasterLayerController<String, Renderer>(
            rasterLayerManager: RasterLayerManager<String>(), renderer: renderer
        )
        await controller.add(data: [layer("relief")])
        await controller.upsert(state: PolygonTiler.rasterLayerState(template: "http://127.0.0.1:1/tiles/p/256/v1/{z}/{x}/{y}.png"))
        await controller.upsert(state: markerTiles(1))
        XCTAssertEqual(renderer.onMap.sorted(), ["mc-marker-tiles", "mc-polygon-tiles", "relief"])

        // アプリの RasterLayer が変わっても、SDK のタイルは残る
        await controller.add(data: [layer("photo")])
        XCTAssertEqual(renderer.onMap.sorted(), ["mc-marker-tiles", "mc-polygon-tiles", "photo"])

        // マーカータイルの版が変わっても、ほかは残る
        await controller.upsert(state: markerTiles(2))
        XCTAssertEqual(renderer.onMap.sorted(), ["mc-marker-tiles", "mc-polygon-tiles", "photo"])

        // マーカータイルを外しても、ほかは残る
        await controller.removeById("mc-marker-tiles")
        XCTAssertEqual(renderer.onMap.sorted(), ["mc-polygon-tiles", "photo"])

        // アプリのレイヤーが全部無くなっても、ポリゴンタイルは残る
        await controller.add(data: [])
        XCTAssertEqual(renderer.onMap.sorted(), ["mc-polygon-tiles"])
    }
}
