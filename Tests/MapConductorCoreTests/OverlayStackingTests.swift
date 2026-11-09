import XCTest

@_spi(MapConductorDriver) @testable import MapConductorCore

/// ``OverlayStacking`` が、追加の順に関わらず
/// ラスター < グラウンドイメージ < ポリゴン < サークル < ポリライン < マーカー に並べること。
final class OverlayStackingTests: XCTestCase {
    private struct Layer: Equatable {
        let name: String
        let key: OverlayStackKey?
        let isLabel: Bool
    }

    /// GL スタイルの差し込みを真似る: ベースマップ（背景・道路・ラベル）の上に、
    /// `insertionIndex` の位置へ 1 枚ずつ差し込む。ラスターはラベルを天井にする。
    private func stack(_ adds: [(String, OverlayStackKey)]) -> [Layer] {
        var layers: [Layer] = [
            Layer(name: "background", key: nil, isLabel: false),
            Layer(name: "roads", key: nil, isLabel: false),
            Layer(name: "labels", key: nil, isLabel: true),
        ]
        for (name, key) in adds {
            let ceiling = key.band == .rasterLayer ? layers.firstIndex { $0.isLabel } : nil
            let index = OverlayStacking.insertionIndex(for: key, among: layers.map(\.key), ceiling: ceiling)
            layers.insert(Layer(name: name, key: key, isLabel: false), at: index)
        }
        return layers
    }

    private let kinds: [(String, OverlayStackKey)] = [
        ("raster", OverlayStackKey(.rasterLayer)),
        ("ground", OverlayStackKey(.groundImage)),
        ("polygon", OverlayStackKey(.polygon)),
        ("circle", OverlayStackKey(.circle)),
        ("polyline", OverlayStackKey(.polyline)),
        ("marker", OverlayStackKey(.marker)),
    ]

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i -> [[T]] in
            var rest = items
            let head = rest.remove(at: i)
            return permutations(rest).map { [head] + $0 }
        }
    }

    func testEveryAddOrderEndsInBandOrder() {
        for order in permutations(kinds) {
            let names = stack(order).filter { $0.key != nil }.map(\.name)
            XCTAssertEqual(names, ["raster", "ground", "polygon", "circle", "polyline", "marker"],
                           "added as \(order.map(\.0))")
        }
    }

    func testRasterStaysUnderTheBasemapLabelsAndTheRestAbove() {
        for order in permutations(kinds) {
            let names = stack(order).map(\.name)
            XCTAssertEqual(names, ["background", "roads", "raster", "labels", "ground", "polygon", "circle", "polyline", "marker"],
                           "added as \(order.map(\.0))")
        }
    }

    func testZIndexOrdersWithinABandButNeverAcrossBands() {
        let names = stack([
            ("marker-low", OverlayStackKey(.marker, zIndex: -1000)),
            ("polygon-high", OverlayStackKey(.polygon, zIndex: 1000)),
            ("polygon-low", OverlayStackKey(.polygon, zIndex: -5)),
            ("raster-2", OverlayStackKey(.rasterLayer, zIndex: 2)),
            ("raster-1", OverlayStackKey(.rasterLayer, zIndex: 1)),
        ]).filter { $0.key != nil }.map(\.name)
        XCTAssertEqual(names, ["raster-1", "raster-2", "polygon-low", "polygon-high", "marker-low"])
    }

    func testEqualKeysKeepThePassedOrder() {
        let names = stack([
            ("g1", OverlayStackKey(.groundImage)),
            ("polygon", OverlayStackKey(.polygon)),
            ("g2", OverlayStackKey(.groundImage)),
            ("g3", OverlayStackKey(.groundImage)),
        ]).filter { $0.key != nil }.map(\.name)
        XCTAssertEqual(names, ["g1", "g2", "g3", "polygon"])
    }

    func testCeilingNeverPushesBelowLowerOverlays() {
        // ラベルより上に既にラスター（zIndex 0）がある状態で、zIndex 1 のラスターを足す。
        let existing: [OverlayStackKey?] = [nil, OverlayStackKey(.rasterLayer, zIndex: 0), nil, OverlayStackKey(.polygon)]
        XCTAssertEqual(OverlayStacking.insertionIndex(for: OverlayStackKey(.rasterLayer, zIndex: 1), among: existing, ceiling: 0), 2)
    }

    func testStyleLayerIdsMapToTheirBands() {
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-raster-layer-RL"), .rasterLayer)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mc-gimg-lyr-GI"), .groundImage)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-polygons-fill-abc"), .polygon)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-polygons-line-abc"), .polygon)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-circles-layer-abc-stroke"), .circle)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-polylines-layer-abc"), .polyline)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-markers-layer-abc"), .marker)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-tile-markers-layer-abc"), .marker)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-cluster-layer-abc"), .marker)
        XCTAssertEqual(OverlayStacking.band(ofStyleLayerId: "mapconductor-raster-layer-mc-polygon-tiles"), .polygon)
        XCTAssertNil(OverlayStacking.band(ofStyleLayerId: "road-label"))
        XCTAssertNil(OverlayStacking.band(ofStyleLayerId: "mapconductor-raster-source-RL"))
    }

    func testRasterPathLayersTakeTheirOwnBand() {
        XCTAssertEqual(OverlayStacking.rasterKey(stateId: "RL", zIndex: 3), OverlayStackKey(.rasterLayer, zIndex: 3))
        XCTAssertEqual(OverlayStacking.rasterKey(stateId: "mc-polygon-tiles", zIndex: 0), OverlayStackKey(.polygon))
        XCTAssertEqual(OverlayStacking.rasterKey(stateId: "marker-tile-abc", zIndex: 0), OverlayStackKey(.marker))
    }

    func testGlobalZIndexNeverCrossesBands() {
        let extremes = [Int.min, -50_000_000, -1, 0, 1, 50_000_000, Int.max]
        for (lower, upper) in zip(OverlayBand.allCases, OverlayBand.allCases.dropFirst()) {
            let lowerMax = extremes.map { OverlayStacking.globalZIndex(OverlayStackKey(lower, zIndex: $0)) }.max()!
            let upperMin = extremes.map { OverlayStacking.globalZIndex(OverlayStackKey(upper, zIndex: $0)) }.min()!
            XCTAssertLessThan(lowerMax, upperMin, "\(lower) vs \(upper)")
        }
        for (lower, upper) in zip(OverlayBand.allCases, OverlayBand.allCases.dropFirst()) {
            XCTAssertLessThan(OverlayStacking.globalZIndex(OverlayStackKey(lower, zIndex: .max), bandStride: 100),
                              OverlayStacking.globalZIndex(OverlayStackKey(upper, zIndex: .min), bandStride: 100))
        }
        XCTAssertLessThan(OverlayStacking.globalZIndex(OverlayStackKey(.polygon, zIndex: 1)),
                          OverlayStacking.globalZIndex(OverlayStackKey(.polygon, zIndex: 2)))
    }
}
