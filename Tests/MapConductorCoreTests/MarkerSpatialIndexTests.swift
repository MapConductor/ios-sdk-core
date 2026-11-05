import CoreGraphics
import XCTest

@testable import MapConductorCore

/// マーカーの空間インデックス（`HexCellRegistry` / `KDTree`）。
///
/// ## なぜここを固定するか
///
/// 数万件のマーカーを置いた地図で、マーカーを差し替えるたびに次の空間検索が K-D 木の
/// 全件再構築を待っていた。レジストリは位置の変わらない更新でも作り直しの印を付け、
/// 木の構築は階層ごとにソートして配列を作っていた。
///
/// 速くしたことで結果が変わってはいけない。インデックスの取り違えは何も落とさず、
/// マーカーが静かに見つからなくなるだけなので、総当たりの結果と比べる。
final class MarkerSpatialIndexTests: XCTestCase {

    // MARK: - KDTree

    private func cellAt(_ id: String, _ x: Double, _ y: Double) -> HexCell {
        HexCell(
            coord: HexCoord(q: 0, r: 0),
            centerLatLng: GeoPoint(latitude: 0, longitude: 0),
            centerXY: CGPoint(x: x, y: y),
            id: id
        )
    }

    /// A deterministic spread, so a failure is reproducible.
    private func random(_ seed: UInt64) -> () -> Double {
        var state = seed
        return {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    /// 六角格子のように、同じ x（列）と同じ y が大量に並ぶ点。分割の取り違えはここで出る
    private func gridCells() -> [HexCell] {
        (0..<40).flatMap { col in
            (0..<40).map { row in
                cellAt("c\(col)_\(row)", Double(col) * 3, Double(row) * 2 + Double(col % 2))
            }
        }
    }

    private func scatteredCells(_ count: Int) -> [HexCell] {
        let next = random(123_456_789)
        return (0..<count).map { cellAt("s\($0)", next() * 1000, next() * 1000) }
    }

    private func distSq(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
    }

    private func assertMatchesBruteForce(_ cells: [HexCell], file: StaticString = #filePath, line: UInt = #line) {
        let tree = KDTree(points: cells)
        // 全部を覆う半径で、木が全セルを持っていること
        XCTAssertEqual(
            tree.withinRadius(query: CGPoint(x: 500, y: 500), radius: 2_000).count,
            cells.count,
            file: file,
            line: line
        )

        let next = random(42)
        for _ in 0..<200 {
            let query = CGPoint(x: next() * 130 - 5, y: next() * 90 - 5)

            guard let nearest = tree.nearest(query: query) else {
                return XCTFail("nearest returned nil", file: file, line: line)
            }
            let best = cells.map { distSq($0.centerXY, query) }.min()!
            XCTAssertEqual(distSq(nearest.centerXY, query), best, file: file, line: line)

            let radius = next() * 10
            let within = tree.withinRadiusWithDistance(query: query, radius: radius).map(\.cell.id).sorted()
            let expected = cells
                .filter { distSq($0.centerXY, query) <= radius * radius }
                .map(\.id)
                .sorted()
            XCTAssertEqual(within, expected, file: file, line: line)

            let k = 1 + Int(next() * 8)
            let knn = tree.nearestKWithDistance(query: query, k: k).map { $0.distanceMeters * $0.distanceMeters }
            let expectedKnn = Array(cells.map { distSq($0.centerXY, query) }.sorted().prefix(k))
            XCTAssertEqual(knn.count, expectedKnn.count, file: file, line: line)
            for (actual, wanted) in zip(knn, expectedKnn) {
                XCTAssertEqual(actual, wanted, accuracy: 1e-6, file: file, line: line)
            }
        }
    }

    func testKDTreeMatchesBruteForceOnGrid() {
        assertMatchesBruteForce(gridCells())
    }

    func testKDTreeMatchesBruteForceOnScatteredPoints() {
        assertMatchesBruteForce(scatteredCells(3_000))
    }

    // MARK: - HexCellRegistry

    private func registry() -> HexCellRegistry<Int> {
        HexCellRegistry(geocell: HexGeocell.defaultGeocell(), zoom: 20)
    }

    private func entity(_ id: String, _ latitude: Double, _ longitude: Double) -> MarkerEntity<Int> {
        MarkerEntity(
            marker: nil,
            state: MarkerState(position: GeoPoint(latitude: latitude, longitude: longitude), id: id)
        )
    }

    /// 検索を一度通して木を建て、作り直しの印を落とした状態にする。
    private func settle(_ registry: HexCellRegistry<Int>, file: StaticString = #filePath, line: UInt = #line) {
        _ = registry.findWithinRadiusWithDistance(point: GeoPoint(latitude: 35.68, longitude: 139.76), radius: 1)
        XCTAssertFalse(registry.getStats().needsRebuild, "前提: この時点で印は落ちている", file: file, line: line)
    }

    /// 同じ位置での再登録は木を汚さない。ここが本命。
    func testReRegisteringAtSamePositionDoesNotRequestRebuild() {
        let registry = registry()
        registry.setPoint(entity: entity("a", 35.68, 139.76))
        settle(registry)

        for _ in 0..<5 { registry.setPoint(entity: entity("a", 35.68, 139.76)) }

        XCTAssertFalse(registry.getStats().needsRebuild)
        XCTAssertEqual(registry.getStats().totalCells, 1)
    }

    /// 既にあるセルへの追加も、セルの集合は変わらない。
    func testAddingToExistingCellDoesNotRequestRebuild() {
        let registry = registry()
        // zoom 20 のセルは 10cm 程度なので、同じセルに入れるには座標を完全に一致させる。
        let cell = registry.setPoint(entity: entity("a", 35.68, 139.76))
        settle(registry)

        let again = registry.setPoint(entity: entity("b", 35.68, 139.76))

        XCTAssertFalse(registry.getStats().needsRebuild)
        XCTAssertEqual(again, cell)
        XCTAssertEqual(registry.getEntryIDsByHexCell(cell), ["a", "b"])
    }

    /// 位置が変わればセルの集合が変わるので、作り直しを要求する。
    func testMovingToAnotherCellRequestsRebuild() {
        let registry = registry()
        let before = registry.setPoint(entity: entity("a", 35.68, 139.76))
        settle(registry)

        let after = registry.setPoint(entity: entity("a", 34.70, 135.50))

        XCTAssertNotEqual(before.id, after.id)
        XCTAssertTrue(registry.getStats().needsRebuild)
        XCTAssertEqual(registry.getStats().totalCells, 1)
        XCTAssertEqual(registry.getEntryIDsByHexCell(after), ["a"])
    }

    /// 同じセルに残りがあるなら、1 件消してもセルの集合は変わらない。
    func testRemovingOneOfSharedCellDoesNotRequestRebuild() {
        let registry = registry()
        let cell = registry.setPoint(entity: entity("a", 35.68, 139.76))
        registry.setPoint(entity: entity("b", 35.68, 139.76))
        settle(registry)

        registry.removePoint(entity: entity("a", 35.68, 139.76))

        XCTAssertFalse(registry.getStats().needsRebuild)
        XCTAssertEqual(registry.getEntryIDsByHexCell(cell), ["b"])
    }

    /// 最後の 1 件を消すとセルが消えるので、作り直しを要求する。
    func testRemovingLastOfCellRequestsRebuild() {
        let registry = registry()
        registry.setPoint(entity: entity("a", 35.68, 139.76))
        settle(registry)

        registry.removePoint(entity: entity("a", 35.68, 139.76))

        XCTAssertTrue(registry.getStats().needsRebuild)
        XCTAssertEqual(registry.getStats().totalCells, 0)
    }

    /// 更新・追加・移動・削除を重ねたあとも、最初から作り直したレジストリと同じ答えを返す。
    func testIncrementalUpdatesMatchFreshRegistry() {
        let next = random(7)
        let base = (0..<400).map { i in
            (id: "m\(i)", lat: 35.0 + next() * 0.01, lng: 139.0 + next() * 0.01)
        }
        let incremental = HexCellRegistry<Int>(geocell: HexGeocell.defaultGeocell(), zoom: 14)
        base.forEach { incremental.setPoint(entity: entity($0.id, $0.lat, $0.lng)) }
        let center = GeoPoint(latitude: 35.005, longitude: 139.005)
        _ = incremental.findWithinRadius(point: center, radius: 1)

        var final: [String: (lat: Double, lng: Double)] = [:]
        for (i, m) in base.enumerated() {
            switch i % 4 {
            case 0: // 位置の変わらない更新
                incremental.setPoint(entity: entity(m.id, m.lat, m.lng))
                final[m.id] = (m.lat, m.lng)
            case 1: // 移動
                let moved = (lat: 35.0 + next() * 0.01, lng: 139.0 + next() * 0.01)
                incremental.setPoint(entity: entity(m.id, moved.lat, moved.lng))
                final[m.id] = moved
            case 2: // 削除
                incremental.removePoint(entity: entity(m.id, m.lat, m.lng))
            default:
                final[m.id] = (m.lat, m.lng)
            }
            // 同じ座標への追加
            if i % 10 == 0 {
                incremental.setPoint(entity: entity("dup\(i)", m.lat, m.lng))
                final["dup\(i)"] = (m.lat, m.lng)
            }
        }

        let fresh = HexCellRegistry<Int>(geocell: HexGeocell.defaultGeocell(), zoom: 14)
        final.forEach { fresh.setPoint(entity: entity($0.key, $0.value.lat, $0.value.lng)) }

        for radius in [0.0, 50.0, 200.0, 2_000.0] {
            XCTAssertEqual(
                Set(incremental.findWithinRadius(point: center, radius: radius).map(\.id)),
                Set(fresh.findWithinRadius(point: center, radius: radius).map(\.id)),
                "radius \(radius)"
            )
        }
        XCTAssertEqual(incremental.findNearest(point: center)?.id, fresh.findNearest(point: center)?.id)
        XCTAssertEqual(incremental.getStats().totalCells, fresh.getStats().totalCells)
        XCTAssertEqual(incremental.getStats().totalEntries, fresh.getStats().totalEntries)
    }
}
