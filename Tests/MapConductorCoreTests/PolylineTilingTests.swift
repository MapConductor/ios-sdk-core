import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// ポリラインのタイル描画を支える部品。js-sdk-core の `PolylineTiling.test.mjs`、
/// android-sdk の `PolylineTilingTest` と 1 対 1 で対応する（`PolygonTilingTests` の線版）。
///
/// - しきい値: 本数か頂点数のどちらかが届けばタイル。判定はここ 1 か所。
/// - タイルにできるのは geodesic でなく、2 点以上で、経度の幅が 180° 未満の線。
/// - 地図ごとの指定（`MapViewContent.polylineTilingOptions` / `PolylineTiling`）がビルダーを通って残る。
/// - `Polylines` を 2 つ置いても、どちらの線も content に残る（片方を外せば他方だけ残る）。
/// - 重なり順: ポリラインのタイルはサークルの上、ネイティブのポリラインの下、マーカーの下。
final class PolylineTilingTests: XCTestCase {
    private func p(_ lat: Double, _ lng: Double) -> GeoPointProtocol { GeoPoint(latitude: lat, longitude: lng) }

    private func lines(_ count: Int, prefix: String = "l") -> [PolylineState] {
        (0..<count).map { i in
            let lat = 42.30 + Double(i / 100) * 0.001, lng = -71.10 + Double(i % 100) * 0.001
            return PolylineState(points: [p(lat, lng), p(lat, lng + 0.0005)], id: "\(prefix)\(i)", strokeColor: .red, strokeWidth: 2)
        }
    }

    // MARK: thresholds and what can be tiled

    func testTilesOnceEitherThePolylineOrTheVertexCountIsReached() {
        let o = PolylineTilingOptions.Default
        XCTAssertFalse(o.shouldUseTiles(polylineCount: 1999, vertexCount: 49_999))
        XCTAssertTrue(o.shouldUseTiles(polylineCount: 2000, vertexCount: 0))
        XCTAssertTrue(o.shouldUseTiles(polylineCount: 10, vertexCount: 50_000))
        XCTAssertFalse(PolylineTilingOptions.Disabled.shouldUseTiles(polylineCount: 100_000, vertexCount: 10_000_000))
        XCTAssertEqual(PolylineTilingOptions(minPolylineCount: 5).minVertexCount, 50_000)
    }

    func testOnlyNonGeodesicLinesOfTwoPointsNarrowerThanHalfTheWorldAreTiled() {
        XCTAssertTrue(PolylineTileSet.canTile(PolylineState(points: [p(42, -71), p(42.001, -71)])))
        XCTAssertFalse(PolylineTileSet.canTile(PolylineState(points: [p(42, -71), p(42.001, -71)], geodesic: true)))
        XCTAssertFalse(PolylineTileSet.canTile(PolylineState(points: [p(42, -71)])), "1 点")
        XCTAssertFalse(PolylineTileSet.canTile(PolylineState(points: [p(0, -100), p(0, 80)])), "経度の幅 180°")
        XCTAssertTrue(PolylineTileSet.canTile(PolylineState(points: [p(0, -90), p(0, 89)])))
        XCTAssertEqual(PolylineTileSet.vertexCount([
            PolylineState(points: [p(0, 0), p(1, 1), p(2, 2)]),
            PolylineState(points: [p(0, 0), p(1, 1)]),
        ]), 5)
    }

    func testRouteReturnsTheTiledIdsAndAVersionedTemplate() async throws {
        let tiler = PolylineTiler(options: PolylineTilingOptions(minPolylineCount: 3))
        var templates: [String?] = []
        tiler.onTemplate = { template, _ in templates.append(template) }
        let geodesic = PolylineState(points: [p(42.3, -71.1), p(42.31, -71.1)], id: "g", geodesic: true)
        let ids = await tiler.route(lines(5) + [geodesic])
        XCTAssertEqual(ids, Set((0..<5).map { "l\($0)" }))
        XCTAssertFalse(tiler.isTiled("g"))
        let template = try XCTUnwrap(templates.last ?? nil)
        XCTAssertTrue(template.contains("/v1/"), template)
        XCTAssertEqual(tiler.currentTemplate(), template)
        // Below the threshold: nothing in tiles, the layer goes.
        let none = await tiler.route(Array(lines(5).prefix(2)))
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(templates.last ?? "not removed")
        XCTAssertNil(tiler.currentTemplate())
    }

    func testOptionsCanChangeAndTheNextRouteUsesThem() async {
        let tiler = PolylineTiler(options: PolylineTilingOptions(minPolylineCount: 3))
        tiler.onTemplate = { _, _ in }
        let data = lines(5)
        let tiledBefore = await tiler.route(data)
        XCTAssertEqual(tiledBefore.count, 5)
        XCTAssertFalse(tiler.setOptions(PolylineTilingOptions(minPolylineCount: 3)), "same options: nothing to redo")
        XCTAssertTrue(tiler.setOptions(.Disabled))
        let tiledAfter = await tiler.route(data)
        XCTAssertTrue(tiledAfter.isEmpty)
        tiler.options = PolylineTilingOptions(minPolylineCount: 3)
        let tiledAgain = await tiler.route(data)
        XCTAssertEqual(tiledAgain.count, 5)
        await tiler.clear()
    }

    func testTheLayerIdAndStateAreThePolylineTiles() {
        XCTAssertEqual(PolylineTiler.layerId, "mc-polyline-tiles")
        XCTAssertEqual(PolylineTiler.layerId, OverlayStacking.polylineTileStateId)
        let state = PolylineTiler.rasterLayerState(template: "http://127.0.0.1:1/x/{z}/{x}/{y}.png", tileSize: 256)
        XCTAssertEqual(state.id, "mc-polyline-tiles")
        XCTAssertNotEqual(PolylineTiler.layerId, PolygonTiler.layerId)
    }

    // MARK: stacking

    func testPolylineTilesStackOverCirclesUnderNativePolylinesAndUnderMarkers() {
        let key = OverlayStacking.rasterKey(stateId: PolylineTiler.layerId, zIndex: 0)
        XCTAssertEqual(key.band, .polyline)
        XCTAssertGreaterThan(key, OverlayStackKey(.circle, zIndex: .max))
        XCTAssertGreaterThan(key, OverlayStacking.rasterKey(stateId: PolygonTiler.layerId, zIndex: 0))
        XCTAssertLessThan(key, OverlayStackKey(.polyline, zIndex: -OverlayStacking.zIndexSpan))
        XCTAssertLessThan(key, OverlayStackKey(.marker, zIndex: .min))
        // The same through a GL style's layer ids.
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-raster-layer-mc-polyline-tiles"), .polyline)
        XCTAssertEqual(OverlayStacking.rasterKey(styleLayerId: "mapconductor-raster-layer-mc-polyline-tiles", zIndex: 0), key)
        XCTAssertEqual(OverlayStacking.rasterKey(styleLayerId: "mapconductor-raster-layer-RL", zIndex: 4), OverlayStackKey(.rasterLayer, zIndex: 4))
        // A single number (Google Maps zIndex, HERE drawOrder): between circles and the lowest native polyline.
        let global = OverlayStacking.globalZIndex(key)
        XCTAssertGreaterThan(global, OverlayStacking.globalZIndex(OverlayStackKey(.circle, zIndex: .max)))
        XCTAssertLessThanOrEqual(global, OverlayStacking.globalZIndex(OverlayStackKey(.polyline, zIndex: .min)))
        XCTAssertLessThan(global, OverlayStacking.globalZIndex(OverlayStackKey(.polyline, zIndex: 0)))
    }

    func testInAGLStyleTheTilesGoUnderTheNativePolylinesWhicheverIsAddedFirst() {
        // OverlayStackingTests の GL 差し込みの真似: 既存のレイヤは帯だけ（zIndex 0）で見る。
        func insert(_ adds: [(String, OverlayStackKey)]) -> [String] {
            var layers: [(String, OverlayStackKey)] = []
            for (name, key) in adds {
                let index = OverlayStacking.insertionIndex(
                    for: key, among: layers.map { OverlayStackKey($0.1.band) }
                )
                layers.insert((name, key), at: index)
            }
            return layers.map(\.0)
        }
        let tiles = ("tiles", OverlayStacking.polylineTileKey)
        let native = ("native", OverlayStackKey(.polyline))
        let circle = ("circle", OverlayStackKey(.circle))
        let marker = ("marker", OverlayStackKey(.marker))
        XCTAssertEqual(insert([native, tiles, circle, marker]), ["circle", "tiles", "native", "marker"])
        XCTAssertEqual(insert([tiles, native, marker, circle]), ["circle", "tiles", "native", "marker"])
        XCTAssertEqual(insert([marker, native, circle, tiles]), ["circle", "tiles", "native", "marker"])
    }

    // MARK: content

    private func build(@MapViewContentBuilder _ body: () -> MapViewContent) -> MapViewContent {
        body()
    }

    func testPolylineTilingIsDefaultUntilSetAndAnExplicitChoiceSurvivesTheBuilder() {
        XCTAssertEqual(MapViewContent().polylineTilingOptions, .Default)
        let roads = lines(3)
        let built = build {
            PolylineTiling(.Disabled)
            Polylines(roads)
            Markers([])
        }
        XCTAssertEqual(built.polylineTilingOptions, .Disabled)
        XCTAssertEqual(built.polylines.count, 3)
        let single = build { PolylineTiling(PolylineTilingOptions(minPolylineCount: 7)) }
        XCTAssertEqual(single.polylineTilingOptions.minPolylineCount, 7)
        // Setting it leaves the marker tiling alone, and the other way round.
        XCTAssertNil(built.explicitMarkerTilingOptions)
    }

    func testTwoPolylinesCoexistAndRemovingOneLeavesTheOther() {
        let roads = lines(3, prefix: "road")
        let paths = lines(2, prefix: "path")
        let single = PolylineState(points: [p(42.3, -71.1), p(42.31, -71.1)], id: "single")
        let both = build {
            Polylines(roads)
            Polyline(state: single)
            Polylines(paths)
        }
        XCTAssertEqual(both.polylines.map(\.state.id), ["road0", "road1", "road2", "single", "path0", "path1"])
        let showPaths = false
        let onlyRoads = build {
            Polylines(roads)
            Polyline(state: single)
            if showPaths { Polylines(paths) }
        }
        XCTAssertEqual(onlyRoads.polylines.map(\.state.id), ["road0", "road1", "road2", "single"])
        let onlyPaths = build {
            if showPaths { Polylines(roads) }
            Polylines(paths)
        }
        XCTAssertEqual(onlyPaths.polylines.map(\.state.id), ["path0", "path1"])
    }

    func testTheControllerDropsOnlyTheRemovedPolylinesWhenOneGroupLeaves() async {
        // 2 つの Polylines の和を渡し、片方を外した和を渡し直す: 残る側は地図に残る。
        final class Renderer: AbstractPolylineOverlayRenderer<String> {
            var onMap = Set<String>()
            override func createPolyline(state: PolylineState) async -> String? { onMap.insert(state.id); return state.id }
            override func updatePolylineProperties(
                polyline: String, current: PolylineEntity<String>, prev: PolylineEntity<String>
            ) async -> String? { polyline }
            override func removePolyline(entity: PolylineEntity<String>) async { onMap.remove(entity.state.id) }
        }
        let renderer = Renderer()
        let controller = PolylineController<String, Renderer>(polylineManager: PolylineManager<String>(), renderer: renderer)
        let roads = lines(3, prefix: "road"), paths = lines(2, prefix: "path")
        await controller.add(data: roads + paths)
        XCTAssertEqual(renderer.onMap.count, 5)
        await controller.add(data: roads)
        XCTAssertEqual(renderer.onMap, ["road0", "road1", "road2"])
    }
}
