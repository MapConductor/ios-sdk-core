import UIKit
import XCTest

@testable import MapConductorCore

/// `MarkerEntity.tiling` の仕分けが android-sdk と一致することを確認する。
///
/// android-sdk では 1 つの `MarkerManager` にタイル担当とネイティブ担当が同居し、
/// `MarkerTileRenderer` が `filter { it.tiling }`、プロバイダのレンダラが
/// `filter { !it.tiling }` で描き分ける。iOS もこの仕分けに揃えた。
@MainActor
final class MarkerTilingFlagTests: XCTestCase {
    // MARK: - Test doubles

    final class FakeMarker {
        let id: String
        init(id: String) { self.id = id }
    }

    /// 受け取った内容を記録するだけのレンダラ。
    final class StubRenderer: MarkerOverlayRendererProtocol {
        typealias ActualMarker = FakeMarker

        var animateStartListener: OnMarkerEventHandler?
        var animateEndListener: OnMarkerEventHandler?

        private(set) var addedIds: [String] = []
        private(set) var changedIds: [String] = []
        private(set) var removedIds: [String] = []

        func onAdd(data: [MarkerOverlayAddParams]) async -> [FakeMarker?] {
            addedIds.append(contentsOf: data.map { $0.state.id })
            return data.map { FakeMarker(id: $0.state.id) }
        }

        func onChange(data: [MarkerOverlayChangeParams<FakeMarker>]) async -> [FakeMarker?] {
            changedIds.append(contentsOf: data.map { $0.current.state.id })
            return data.map { _ in FakeMarker(id: "changed") }
        }

        func onRemove(data: [MarkerEntity<FakeMarker>]) async {
            removedIds.append(contentsOf: data.map { $0.state.id })
        }

        func onAnimate(entity: MarkerEntity<FakeMarker>) async {}

        func onPostProcess() async {}
    }

    /// `find(position:)` が `fatalError` なので具象サブクラスを用意する。
    final class TestMarkerController: AbstractMarkerController<FakeMarker, StubRenderer> {
        override func find(position: GeoPointProtocol) -> MarkerEntity<FakeMarker>? { nil }
    }

    // MARK: - Helpers

    /// 検証に使うタイル。z=1 のような極端に大きなタイルだと `expandedByDegrees` の
    /// 経度 180 度超え対策に引っかかるので、実際に使われるズームのタイルを選ぶ。
    private static let tileRequest = TileRequest(x: 909, y: 403, z: 10)

    /// [tileRequest] の中心座標（標準の Web メルカトル逆変換）。
    private static let insideTile: GeoPoint = {
        let n = Double(1 << tileRequest.z)
        let x = Double(tileRequest.x) + 0.5
        let y = Double(tileRequest.y) + 0.5
        let longitude = x / n * 360.0 - 180.0
        let latitude = atan(sinh(.pi * (1.0 - 2.0 * y / n))) * 180.0 / .pi
        return GeoPoint(latitude: latitude, longitude: longitude)
    }()

    /// 位置だけ少しずらした状態を作る（fingerPrint を変えて更新経路に乗せるため）。
    private static func nudged(_ point: GeoPoint) -> GeoPoint {
        GeoPoint(latitude: point.latitude + 1e-4, longitude: point.longitude + 1e-4)
    }

    private func ingest(
        _ data: [MarkerState],
        manager: MarkerManager<FakeMarker>,
        renderer: StubRenderer,
        tiledIds: inout Set<String>,
        shouldTile: @escaping (MarkerState) -> Bool
    ) async -> MarkerIngestionEngine.Result {
        await MarkerIngestionEngine.ingest(
            data: data,
            markerManager: manager,
            renderer: renderer,
            defaultMarkerIcon: DefaultMarkerIcon().toBitmapIcon(),
            tilingEnabled: true,
            tiledMarkerIds: &tiledIds,
            shouldTile: shouldTile
        )
    }

    // MARK: - Ingestion

    /// タイル担当として取り込まれた entity は `tiling = true`、ネイティブ担当は `false`。
    func testIngestMarksTiledEntitiesOnly() async {
        let manager = MarkerManager<FakeMarker>()
        let renderer = StubRenderer()
        var tiledIds: Set<String> = []

        let tiled = MarkerState(position: Self.insideTile, id: "tiled")
        let native = MarkerState(position: Self.insideTile, id: "native", draggable: true)

        _ = await ingest([tiled, native], manager: manager, renderer: renderer, tiledIds: &tiledIds) {
            !$0.draggable
        }

        XCTAssertEqual(manager.getEntity("tiled")?.tiling, true)
        XCTAssertNil(manager.getEntity("tiled")?.marker)
        XCTAssertEqual(manager.getEntity("native")?.tiling, false)
        XCTAssertNotNil(manager.getEntity("native")?.marker)
    }

    /// タイル担当からネイティブへ降ろすと `tiling` が下りる。
    func testIngestClearsTilingOnDemotion() async {
        let manager = MarkerManager<FakeMarker>()
        let renderer = StubRenderer()
        var tiledIds: Set<String> = []

        let state = MarkerState(position: Self.insideTile, id: "marker")
        _ = await ingest([state], manager: manager, renderer: renderer, tiledIds: &tiledIds) { _ in true }
        XCTAssertEqual(manager.getEntity("marker")?.tiling, true)

        let moved = MarkerState(position: Self.nudged(Self.insideTile), id: "marker")
        _ = await ingest([moved], manager: manager, renderer: renderer, tiledIds: &tiledIds) { _ in false }

        XCTAssertEqual(manager.getEntity("marker")?.tiling, false)
        XCTAssertTrue(tiledIds.isEmpty)
    }

    // MARK: - Tile renderer

    /// `MarkerTileRenderer` はタイル担当だけを焼く。ネイティブ担当しか無ければタイルは出ない。
    func testTileRendererSkipsNativeEntities() {
        let manager = MarkerManager<FakeMarker>()
        manager.registerEntity(
            MarkerEntity(
                marker: FakeMarker(id: "native"),
                state: MarkerState(position: Self.insideTile, id: "native"),
                visible: true,
                isRendered: true,
                tiling: false
            )
        )
        let renderer = MarkerTileRenderer<FakeMarker>(markerManager: manager)

        XCTAssertNil(renderer.renderTile(request: Self.tileRequest))
    }

    /// タイル担当が居ればタイルは出る（上のテストが「常に nil」で通らないことの確認）。
    func testTileRendererRendersTiledEntities() {
        let manager = MarkerManager<FakeMarker>()
        manager.registerEntity(
            MarkerEntity(
                marker: nil,
                state: MarkerState(position: Self.insideTile, id: "tiled"),
                visible: true,
                isRendered: true,
                tiling: true
            )
        )
        let renderer = MarkerTileRenderer<FakeMarker>(markerManager: manager)

        XCTAssertNotNil(renderer.renderTile(request: Self.tileRequest))
    }

    // MARK: - Controller

    /// 既定の `update(state:)` は担当替えをしない。ここで `tiling` を落とすと、
    /// タイル担当のマーカーが 1 回更新されただけで地図から消える。
    func testControllerUpdateKeepsTilingFlag() async {
        let manager = MarkerManager<FakeMarker>()
        let renderer = StubRenderer()
        let controller = TestMarkerController(markerManager: manager, renderer: renderer)

        manager.registerEntity(
            MarkerEntity(
                marker: nil,
                state: MarkerState(position: Self.insideTile, id: "tiled"),
                visible: true,
                isRendered: true,
                tiling: true
            )
        )

        await controller.update(
            state: MarkerState(position: Self.nudged(Self.insideTile), id: "tiled")
        )

        XCTAssertEqual(manager.getEntity("tiled")?.tiling, true)
        XCTAssertTrue(renderer.changedIds.isEmpty, "ネイティブマーカーを持たないので onChange は呼ばれない")
    }
}
