import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// サークルのタイル描画を支える部品。js-sdk-core の `CircleTiling.test.mjs`、
/// android-sdk の `CircleTilingTest` と 1 対 1 で対応する（`PolylineTilingTests` の円版）。
///
/// - しきい値: 本数だけ（頂点は無い）。判定はここ 1 か所。
/// - タイルにできるのは半径が正で有限、極（とメルカトルの外）にも日付変更線にもかからない円。geodesic はどちらでもよい。
/// - 地図ごとの指定（`MapViewContent.circleTilingOptions` / `CircleTiling`）がビルダーを通って残る。
/// - `Circles` を 2 つ置いても、どちらの円も content に残る（片方を外せば他方だけ残る）。
/// - 重なり順: サークルのタイルはポリゴン（タイルとも）の上、ネイティブのサークル・ポリラインのタイル・マーカーの下。
/// - タップ: 半径＋縁幅の半分（カメラなしは半径だけ）、zIndex が高いもの、同じなら中心が近いもの。
final class CircleTilingTests: XCTestCase {
    private func p(_ lat: Double, _ lng: Double) -> GeoPointProtocol { GeoPoint(latitude: lat, longitude: lng) }

    private func circles(_ count: Int, prefix: String = "c") -> [CircleState] {
        (0..<count).map { i in
            let lat = 42.30 + Double(i / 100) * 0.001, lng = -71.10 + Double(i % 100) * 0.001
            return CircleState(center: p(lat, lng), radiusMeters: 20, strokeColor: .red, strokeWidth: 1, fillColor: .blue, id: "\(prefix)\(i)")
        }
    }

    func testRevisionReadersAndReplacementStates() {
        let state = CircleState(center: GeoPoint(latitude: 42, longitude: -71), radiusMeters: 5)
        let first = CircleEntity<NSObject>(circle: nil, state: state)
        let original = first.fingerPrint
        state.radiusMeters = 6
        XCTAssertEqual(first.changeMask(state), 2)
        let second = CircleEntity<NSObject>(circle: nil, state: state)
        XCTAssertEqual(second.changeMask(state), 0)
        XCTAssertEqual(first.changeMask(state), 2)
        XCTAssertEqual(first.fingerPrint, original)
        XCTAssertEqual(second.changeMask(state.copy()), 0)
        state.fillColor = .red
        XCTAssertNotEqual(first.changeMask(state) & 64, 0)
        XCTAssertNotEqual(second.changeMask(state) & 64, 0)
    }

    func testTiledManagerSharesSourcesWithoutRetainingEntities() async {
        let states = (0..<2001).map { i in
            CircleState(center: GeoPoint(latitude: Double(i) * 0.001, longitude: 0), radiusMeters: 5, id: "shared-\(i)")
        }
        let tiler = CircleTiler()
        let manager = CircleManager<NSObject>()
        defer { tiler.dispose() }
        _ = await tiler.route(states)
        manager.setTiledSource(tiler)
        XCTAssertTrue(manager.nativeEntities().isEmpty)
        XCTAssertTrue(manager.hasEntity("shared-123"))
        XCTAssertTrue(manager.getEntity("shared-123")?.state === states[123])
        XCTAssertTrue(manager.find(position: states[123].center)?.state === states[123])
        XCTAssertTrue(manager.nativeEntities().isEmpty)
        let replacement = states[25].copy(radiusMeters: 8)
        tiler.update(replacement)
        XCTAssertTrue(manager.getEntity("shared-25")?.state === replacement)
        tiler.remove("shared-123")
        XCTAssertFalse(manager.hasEntity("shared-123"))
        XCTAssertNil(manager.getEntity("shared-123"))
        manager.clear()
        XCTAssertFalse(manager.hasEntity("shared-25"))
    }

    // MARK: thresholds and what can be tiled

    func testTilesOnceTheCircleCountIsReached() {
        let o = CircleTilingOptions.Default
        XCTAssertEqual(o.minCircleCount, 2001)
        XCTAssertTrue(o.enabled)
        XCTAssertFalse(o.shouldUseTiles(circleCount: 1999))
        XCTAssertFalse(o.shouldUseTiles(circleCount: 2000))
        XCTAssertTrue(o.shouldUseTiles(circleCount: 2001))
        XCTAssertFalse(CircleTilingOptions.Disabled.shouldUseTiles(circleCount: 100_000))
        XCTAssertTrue(CircleTilingOptions(minCircleCount: 5).shouldUseTiles(circleCount: 5))
    }

    func testOnlyCirclesWithARadiusClearOfThePolesAndTheAntimeridianAreTiled() {
        func can(_ lat: Double, _ lng: Double, _ r: Double, geodesic: Bool = true) -> Bool {
            CircleTileSet.canTile(CircleState(center: p(lat, lng), radiusMeters: r, geodesic: geodesic))
        }
        XCTAssertTrue(can(42.35, -71.06, 10))
        XCTAssertTrue(can(42.35, -71.06, 10, geodesic: false))
        XCTAssertFalse(can(42.35, -71.06, 0), "半径 0")
        XCTAssertFalse(can(42.35, -71.06, -5), "負の半径")
        XCTAssertFalse(can(42.35, -71.06, .nan))
        XCTAssertFalse(can(42.35, -71.06, .infinity))
        XCTAssertFalse(can(85.0, 0, 10_000), "メルカトルの端にかかる")
        XCTAssertFalse(can(-85.0, 0, 10_000))
        XCTAssertTrue(can(84.9, 0, 1_000))
        XCTAssertFalse(can(89.0, 0, 200_000), "極を含む")
        XCTAssertFalse(can(0, 179.99, 5_000), "日付変更線をまたぐ")
        XCTAssertFalse(can(0, -179.99, 5_000))
        XCTAssertTrue(can(0, 179.9, 5_000))
        XCTAssertTrue(can(0, 539.9 - 360, 5_000), "中心経度は正規化してから見る")
        XCTAssertTrue(can(0, -180.1 + 360, 5_000) == can(0, -180.1, 5_000))
        // 高緯度・大きな円もタイルで描ける（Ring になる）。
        XCTAssertTrue(can(70, 20, 200_000))
        XCTAssertTrue(can(70, 20, 200_000, geodesic: false))
    }

    func testTheExtentIsTheNative128GonsExtent() throws {
        // geodesic: computeOffset の北・東の点と一致する。
        let b = try XCTUnwrap(CircleTileShape.bounds(latitude: 60, longitude: 10, radiusMeters: 100_000, geodesic: true))
        let north = Spherical.computeOffset(origin: p(60, 10), distance: 100_000, heading: 0)
        XCTAssertEqual(b.north, north.latitude, accuracy: 1e-9)
        let ring = circleToRing(center: p(60, 10), radiusMeters: 100_000, geodesic: true, segments: 4096)
        XCTAssertEqual(b.east, ring.map(\.longitude).max()!, accuracy: 1e-5)
        XCTAssertEqual(b.west, ring.map(\.longitude).min()!, accuracy: 1e-5)
        XCTAssertEqual(b.south, ring.map(\.latitude).min()!, accuracy: 1e-6)
        // 局所平面: circleToRing(geodesic: false) の極値と一致する。
        let flat = try XCTUnwrap(CircleTileShape.bounds(latitude: 60, longitude: 10, radiusMeters: 100_000, geodesic: false))
        let flatRing = circleToRing(center: p(60, 10), radiusMeters: 100_000, geodesic: false, segments: 128)
        XCTAssertEqual(flat.east, flatRing.map(\.longitude).max()!, accuracy: 1e-9)
        XCTAssertEqual(flat.north, flatRing.map(\.latitude).max()!, accuracy: 1e-9)
    }

    func testRouteReturnsTheTiledIdsAndAVersionedTemplate() async throws {
        let tiler = CircleTiler(options: CircleTilingOptions(minCircleCount: 3))
        var templates: [String?] = []
        tiler.onTemplate = { template, _ in templates.append(template) }
        let antimeridian = CircleState(center: p(0, 179.999), radiusMeters: 1_000, id: "am")
        let ids = await tiler.route(circles(5) + [antimeridian])
        XCTAssertEqual(ids, Set((0..<5).map { "c\($0)" }))
        XCTAssertFalse(tiler.isTiled("am"))
        XCTAssertTrue(tiler.isTiled("c0"))
        let template = try XCTUnwrap(templates.last ?? nil)
        XCTAssertTrue(template.contains("/v1/"), template)
        XCTAssertTrue(template.contains("circles-"), template)
        XCTAssertEqual(tiler.currentTemplate(), template)
        XCTAssertEqual(tiler.tiledStates().count, 5)
        // Below the threshold: nothing in tiles, the layer goes.
        let none = await tiler.route(Array(circles(5).prefix(2)))
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(templates.last ?? "not removed")
        XCTAssertNil(tiler.currentTemplate())
    }

    func testOnlyTileableCirclesCountTowardsTheThreshold() async {
        let tiler = CircleTiler(options: CircleTilingOptions(minCircleCount: 3))
        tiler.onTemplate = { _, _ in }
        let zero = (0..<5).map { CircleState(center: p(42, -71), radiusMeters: 0, id: "z\($0)") }
        let ids = await tiler.route(Array(circles(2)) + zero)
        XCTAssertTrue(ids.isEmpty)
    }

    func testOptionsCanChangeAndTheNextRouteUsesThem() async {
        let tiler = CircleTiler(options: CircleTilingOptions(minCircleCount: 3))
        tiler.onTemplate = { _, _ in }
        let data = circles(5)
        let tiledBefore = await tiler.route(data)
        XCTAssertEqual(tiledBefore.count, 5)
        XCTAssertFalse(tiler.setOptions(CircleTilingOptions(minCircleCount: 3)), "same options: nothing to redo")
        XCTAssertTrue(tiler.setOptions(.Disabled))
        let tiledAfter = await tiler.route(data)
        XCTAssertTrue(tiledAfter.isEmpty)
        tiler.options = CircleTilingOptions(minCircleCount: 3)
        let tiledAgain = await tiler.route(data)
        XCTAssertEqual(tiledAgain.count, 5)
        await tiler.clear()
    }

    func testTheLayerIdAndStateAreTheCircleTiles() {
        XCTAssertEqual(CircleTiler.layerId, "mc-circle-tiles")
        XCTAssertEqual(CircleTiler.layerId, OverlayStacking.circleTileStateId)
        let state = CircleTiler.rasterLayerState(template: "http://127.0.0.1:1/x/{z}/{x}/{y}.png", tileSize: 256)
        XCTAssertEqual(state.id, "mc-circle-tiles")
        XCTAssertNotEqual(CircleTiler.layerId, PolylineTiler.layerId)
        XCTAssertNotEqual(CircleTiler.layerId, PolygonTiler.layerId)
    }

    func testTheEffectiveZIndexIsTheCirclesOwnOrTheAutomaticOne() {
        XCTAssertEqual(CircleTileSet.effectiveZIndex(CircleState(center: p(42, -71), radiusMeters: 1, zIndex: 7)), 7)
        // -lat * 1e6 - lng: a circle further south is drawn over one further north.
        XCTAssertEqual(CircleTileSet.effectiveZIndex(CircleState(center: p(42, -71), radiusMeters: 1)), -41_999_929)
        XCTAssertGreaterThan(
            CircleTileSet.effectiveZIndex(CircleState(center: p(42.0, -71), radiusMeters: 1)),
            CircleTileSet.effectiveZIndex(CircleState(center: p(42.1, -71), radiusMeters: 1))
        )
    }

    // MARK: stacking

    func testCircleTilesStackOverPolygonsUnderNativeCirclesPolylineTilesAndMarkers() {
        let key = OverlayStacking.rasterKey(stateId: CircleTiler.layerId, zIndex: 0)
        XCTAssertEqual(key, OverlayStacking.circleTileKey)
        XCTAssertEqual(key.band, .circle)
        XCTAssertGreaterThan(key, OverlayStackKey(.polygon, zIndex: .max))
        XCTAssertGreaterThan(key, OverlayStacking.rasterKey(stateId: PolygonTiler.layerId, zIndex: 0))
        XCTAssertGreaterThan(key, OverlayStacking.rasterKey(stateId: "app-raster", zIndex: .max))
        XCTAssertLessThan(key, OverlayStackKey(.circle, zIndex: -OverlayStacking.zIndexSpan))
        XCTAssertLessThan(key, OverlayStacking.rasterKey(stateId: PolylineTiler.layerId, zIndex: 0))
        XCTAssertLessThan(key, OverlayStackKey(.marker, zIndex: .min))
        // The same through a GL style's layer ids.
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-raster-layer-mc-circle-tiles"), .circle)
        XCTAssertEqual(OverlayStacking.rasterKey(styleLayerId: "mapconductor-raster-layer-mc-circle-tiles", zIndex: 0), key)
        // A single number (Google Maps zIndex, HERE drawOrder): between polygons and the lowest native circle.
        let global = OverlayStacking.globalZIndex(key)
        XCTAssertGreaterThan(global, OverlayStacking.globalZIndex(OverlayStackKey(.polygon, zIndex: .max)))
        XCTAssertLessThanOrEqual(global, OverlayStacking.globalZIndex(OverlayStackKey(.circle, zIndex: .min)))
        XCTAssertLessThan(global, OverlayStacking.globalZIndex(OverlayStackKey(.circle, zIndex: 0)))
        XCTAssertLessThan(global, OverlayStacking.globalZIndex(OverlayStacking.polylineTileKey))
        let here = OverlayStacking.globalZIndex(key, bandStride: 100)
        XCTAssertGreaterThan(here, OverlayStacking.globalZIndex(OverlayStackKey(.polygon, zIndex: .max), bandStride: 100))
        XCTAssertLessThan(here, OverlayStacking.globalZIndex(OverlayStacking.polylineTileKey, bandStride: 100))
    }

    func testInAGLStyleTheTilesGoUnderTheNativeCirclesWhicheverIsAddedFirst() {
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
        let tiles = ("tiles", OverlayStacking.circleTileKey)
        let native = ("native", OverlayStackKey(.circle))
        let polygonTiles = ("polygonTiles", OverlayStacking.rasterKey(stateId: PolygonTiler.layerId, zIndex: 0))
        let lineTiles = ("lineTiles", OverlayStacking.polylineTileKey)
        let marker = ("marker", OverlayStackKey(.marker))
        let expected = ["polygonTiles", "tiles", "native", "lineTiles", "marker"]
        XCTAssertEqual(insert([native, tiles, polygonTiles, lineTiles, marker]), expected)
        XCTAssertEqual(insert([tiles, lineTiles, native, marker, polygonTiles]), expected)
        XCTAssertEqual(insert([marker, lineTiles, native, polygonTiles, tiles]), expected)
    }

    // MARK: content

    private func build(@MapViewContentBuilder _ body: () -> MapViewContent) -> MapViewContent {
        body()
    }

    func testCircleTilingIsDefaultUntilSetAndAnExplicitChoiceSurvivesTheBuilder() {
        XCTAssertEqual(MapViewContent().circleTilingOptions, .Default)
        let trees = circles(3)
        let built = build {
            CircleTiling(.Disabled)
            Circles(trees)
            Markers([])
        }
        XCTAssertEqual(built.circleTilingOptions, .Disabled)
        XCTAssertEqual(built.circles.count, 3)
        let single = build { CircleTiling(CircleTilingOptions(minCircleCount: 7)) }
        XCTAssertEqual(single.circleTilingOptions.minCircleCount, 7)
        // Setting it leaves the other tilings alone, and the other way round.
        XCTAssertNil(built.explicitPolylineTilingOptions)
        XCTAssertNil(built.explicitMarkerTilingOptions)
        let lines = build { PolylineTiling(.Disabled) }
        XCTAssertNil(lines.explicitCircleTilingOptions)
        // Between two explicit settings the later one wins.
        let twice = build {
            CircleTiling(.Disabled)
            Circles(trees)
            CircleTiling(CircleTilingOptions(minCircleCount: 9))
        }
        XCTAssertEqual(twice.circleTilingOptions.minCircleCount, 9)
    }

    func testTwoCirclesCoexistAndRemovingOneLeavesTheOther() {
        let trees = circles(3, prefix: "tree")
        let hydrants = circles(2, prefix: "hydrant")
        let single = CircleState(center: p(42.3, -71.1), radiusMeters: 5, id: "single")
        let both = build {
            Circles(trees)
            Circle(state: single)
            Circles(hydrants)
        }
        XCTAssertEqual(both.circles.map(\.state.id), ["tree0", "tree1", "tree2", "single", "hydrant0", "hydrant1"])
        let showHydrants = false
        let onlyTrees = build {
            Circles(trees)
            Circle(state: single)
            if showHydrants { Circles(hydrants) }
        }
        XCTAssertEqual(onlyTrees.circles.map(\.state.id), ["tree0", "tree1", "tree2", "single"])
        let onlyHydrants = build {
            if showHydrants { Circles(trees) }
            Circles(hydrants)
        }
        XCTAssertEqual(onlyHydrants.circles.map(\.state.id), ["hydrant0", "hydrant1"])
    }

    func testTheControllerDropsOnlyTheRemovedCirclesWhenOneGroupLeaves() async {
        final class Renderer: AbstractCircleOverlayRenderer<String> {
            var onMap = Set<String>()
            override func createCircle(state: CircleState) async -> String? { onMap.insert(state.id); return state.id }
            override func updateCircleProperties(
                circle: String, current: CircleEntity<String>, prev: CircleEntity<String>
            ) async -> String? { circle }
            override func removeCircle(entity: CircleEntity<String>) async { onMap.remove(entity.state.id) }
        }
        let renderer = Renderer()
        let controller = CircleController<String, Renderer>(circleManager: CircleManager<String>(), renderer: renderer)
        let trees = circles(3, prefix: "tree"), hydrants = circles(2, prefix: "hydrant")
        await controller.add(data: trees + hydrants)
        XCTAssertEqual(renderer.onMap.count, 5)
        await controller.add(data: trees)
        XCTAssertEqual(renderer.onMap, ["tree0", "tree1", "tree2"])
    }

    // MARK: taps

    private let lat = 42.3555, lng = -71.0605

    private func camera(zoom: Double) -> MapCameraPosition {
        MapCameraPosition(position: GeoPoint(latitude: lat, longitude: lng), zoom: zoom, bearing: 0, tilt: 0, paddings: nil)
    }

    private func manager(_ states: [CircleState]) -> CircleManager<String> {
        let manager = CircleManager<String>()
        for state in states { manager.registerEntity(CircleEntity(circle: nil, state: state)) }
        return manager
    }

    private func north(_ meters: Double, of point: GeoPointProtocol? = nil) -> GeoPointProtocol {
        Spherical.computeOffset(origin: point ?? p(lat, lng), distance: meters, heading: 0)
    }

    func testATapHitsWithinTheRadiusPlusHalfTheOutline() {
        // z16 at 42.36°: 1.765 m per point, so half of a 4 pt outline is 3.53 m.
        let circle = CircleState(center: p(lat, lng), radiusMeters: 10, strokeWidth: 4, id: "c")
        let m = manager([circle])
        let cam = camera(zoom: 16)
        let half = calculateMetersPerPixel(latitude: lat, zoom: 16) * 2
        XCTAssertEqual(half, 3.53, accuracy: 0.01)
        XCTAssertEqual(m.find(position: north(9.9), cameraPosition: cam)?.state.id, "c")
        XCTAssertEqual(m.find(position: north(10 + half - 0.05), cameraPosition: cam)?.state.id, "c")
        XCTAssertNil(m.find(position: north(10 + half + 0.05), cameraPosition: cam))
        // Zoomed out the outline covers more ground.
        XCTAssertEqual(m.find(position: north(15), cameraPosition: camera(zoom: 15))?.state.id, "c")
        // Without a camera, only the radius.
        XCTAssertEqual(m.find(position: north(9.9))?.state.id, "c")
        XCTAssertNil(m.find(position: north(10.1)))
        XCTAssertNil(m.find(position: north(12), cameraPosition: nil))
    }

    func testOfCirclesWithTheSameZIndexTheClosestCentreWins() {
        let a = CircleState(center: p(lat, lng), radiusMeters: 30, id: "a", zIndex: 0)
        let b = CircleState(center: north(10), radiusMeters: 30, id: "b", zIndex: 0)
        // Whichever order they are registered in.
        for states in [[a, b], [b, a]] {
            let m = manager(states)
            XCTAssertEqual(m.find(position: north(8))?.state.id, "b")
            XCTAssertEqual(m.find(position: north(2))?.state.id, "a")
        }
    }

    func testTheHighestZIndexWinsOverACloserCentre() {
        let low = CircleState(center: p(lat, lng), radiusMeters: 30, id: "low", zIndex: 0)
        let high = CircleState(center: north(20), radiusMeters: 30, id: "high", zIndex: 5)
        XCTAssertEqual(manager([low, high]).find(position: north(1))?.state.id, "high")
        // Without a zIndex, the automatic one: the circle further south is on top.
        let southern = CircleState(center: p(lat, lng), radiusMeters: 30, id: "southern")
        let northern = CircleState(center: north(20), radiusMeters: 30, id: "northern")
        XCTAssertEqual(manager([northern, southern]).find(position: north(18))?.state.id, "southern")
    }

    func testAnUnclickableCircleLetsTheTapThroughToTheOneBelow() {
        let below = CircleState(center: p(lat, lng), radiusMeters: 30, id: "below", zIndex: 0)
        let above = CircleState(center: p(lat, lng), radiusMeters: 30, clickable: false, id: "above", zIndex: 9)
        XCTAssertEqual(manager([below, above]).find(position: north(5))?.state.id, "below")
        XCTAssertNil(manager([above]).find(position: north(5)))
    }

    func testTheLatitudeShortcutDoesNotChangeTheResult() {
        // 中心と半径をばらまき、総当たり（haversine）の答えと同じになること。
        var rng = SystemRandomNumberGenerator()
        var states: [CircleState] = []
        for i in 0..<400 {
            let c = p(lat + Double.random(in: -0.01...0.01, using: &rng), lng + Double.random(in: -0.01...0.01, using: &rng))
            states.append(CircleState(
                center: c, radiusMeters: Double.random(in: 1...300, using: &rng),
                strokeWidth: Double.random(in: 0...6, using: &rng),
                id: "s\(i)", zIndex: Int.random(in: 0...3, using: &rng)
            ))
        }
        let m = manager(states)
        let cam = camera(zoom: 15)
        for _ in 0..<300 {
            let tap = p(lat + Double.random(in: -0.012...0.012, using: &rng), lng + Double.random(in: -0.012...0.012, using: &rng))
            let mpp = calculateMetersPerPixel(latitude: tap.latitude, zoom: 15)
            var best: CircleState?
            var bestKey = (Int.min, -Double.infinity)
            for s in states {
                let d = Spherical.computeDistanceBetween(from: s.center, to: tap)
                let reach = s.radiusMeters + mpp * s.strokeWidth / 2
                guard d <= reach else { continue }
                let key = (s.zIndex ?? 0, -d)
                if key > bestKey { bestKey = key; best = s }
            }
            XCTAssertEqual(m.find(position: tap, cameraPosition: cam)?.state.id, best?.id)
        }
    }

    func testTheControllerFindsTiledCirclesWithTheLastCamera() async {
        final class Renderer: AbstractCircleOverlayRenderer<String> {
            override func createCircle(state: CircleState) async -> String? { state.id }
            override func updateCircleProperties(
                circle: String, current: CircleEntity<String>, prev: CircleEntity<String>
            ) async -> String? { circle }
            override func removeCircle(entity: CircleEntity<String>) async {}
        }
        let controller = CircleController<String, Renderer>(circleManager: CircleManager<String>(), renderer: Renderer())
        let tiler = CircleTiler(options: CircleTilingOptions(minCircleCount: 1))
        tiler.onTemplate = { _, _ in }
        controller.tiler = tiler
        let circle = CircleState(center: p(lat, lng), radiusMeters: 10, strokeWidth: 4, id: "c")
        await controller.add(data: [circle])
        XCTAssertTrue(tiler.isTiled("c"))
        XCTAssertNil(controller.find(position: north(12)), "no camera yet: the radius only")
        await controller.onCameraChanged(mapCameraPosition: camera(zoom: 16))
        XCTAssertEqual(controller.find(position: north(12))?.state.id, "c")
        XCTAssertEqual(controller.resolveTap(position: north(12))?.kind, .circle)
        await controller.clear()
    }
}
