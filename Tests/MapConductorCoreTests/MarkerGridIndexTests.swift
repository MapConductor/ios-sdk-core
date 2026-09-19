import XCTest

@testable import MapConductorCore

/// `MarkerGridIndex` must answer exactly what a scan would.
///
/// The index packs a cell key and an array position into one Int64 and reads
/// them back with shifts and masks, so an off-by-one in the bit layout or in a
/// range bound does not throw — it quietly drops markers. Every test here is
/// the same shape: ask the index, ask brute force, demand the same set.
final class MarkerGridIndexTests: XCTestCase {

    private func entity(_ id: Int, _ latitude: Double, _ longitude: Double) -> MarkerEntity<Int> {
        MarkerEntity(
            marker: id,
            state: MarkerState(
                position: GeoPoint(latitude: latitude, longitude: longitude),
                id: String(id)
            ),
            isRendered: true
        )
    }

    /// A deterministic spread, so a failure is reproducible.
    private func scatter(count: Int, latitude: Double, longitude: Double, spread: Double)
        -> [MarkerEntity<Int>] {
        var generator = SystemRandomNumberGenerator()
        _ = generator
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        return (0..<count).map { index in
            entity(
                index,
                latitude + (next() - 0.5) * spread,
                longitude + (next() - 0.5) * spread
            )
        }
    }

    private func ids(_ entities: [MarkerEntity<Int>]) -> Set<String> {
        Set(entities.map(\.state.id))
    }

    private func bounds(_ south: Double, _ west: Double, _ north: Double, _ east: Double)
        -> GeoRectBounds {
        GeoRectBounds(
            southWest: GeoPoint(latitude: south, longitude: west),
            northEast: GeoPoint(latitude: north, longitude: east)
        )
    }

    func testBoundsQueryMatchesBruteForce() {
        let markers = scatter(count: 5000, latitude: 35.68, longitude: 139.76, spread: 0.6)
        let index = MarkerGridIndex<Int> { markers }

        // A box inside one cell, one spanning several, one wider than the data,
        // and one over empty ground — the last because an index that returns
        // nothing is right here and wrong everywhere else.
        for box in [
            bounds(35.6812, 139.7612, 35.6814, 139.7614),
            bounds(35.68, 139.76, 35.69, 139.77),
            bounds(35.0, 139.0, 36.5, 140.5),
            bounds(10.0, 100.0, 11.0, 101.0),
        ] {
            let expected = ids(markers.filter { box.contains(point: $0.state.position) })
            XCTAssertEqual(ids(index.inBounds(box)), expected, "grid disagreed with a scan")
        }

        // The middle two have to be carrying markers, or the comparison above
        // is only proving that two empty sets match.
        XCTAssertFalse(index.inBounds(bounds(35.68, 139.76, 35.69, 139.77)).isEmpty)
        XCTAssertEqual(index.inBounds(bounds(35.0, 139.0, 36.5, 140.5)).count, markers.count)
    }

    /// A box crossing 180° has its east corner west of its west one.
    ///
    /// The first version walked `lonFrom...lonTo` straight, which is an empty
    /// range on Android and a trap on iOS. Fiji and the Chathams are real
    /// places, and a map centred there is a reversed box every frame.
    func testBoundsQueryCrossesTheAntimeridian() {
        let markers = [
            entity(0, -18.0, 179.9),
            entity(1, -18.0, -179.9),
            entity(2, -18.0, 178.0),
            entity(3, -18.0, 0.0),
        ] + scatter(count: 3000, latitude: -18.0, longitude: 179.95, spread: 0.4)

        let index = MarkerGridIndex<Int> { markers }
        let box = bounds(-18.5, 179.5, -17.5, -179.5)
        let expected = ids(markers.filter { box.contains(point: $0.state.position) })

        XCTAssertTrue(expected.contains("0"), "the box should hold the marker just west of 180")
        XCTAssertTrue(expected.contains("1"), "and the one just east of it")
        XCTAssertEqual(ids(index.inBounds(box)), expected)
    }

    func testNearestMatchesBruteForce() {
        let markers = scatter(count: 5000, latitude: 35.68, longitude: 139.76, spread: 0.6)
        let index = MarkerGridIndex<Int> { markers }

        for point in [
            GeoPoint(latitude: 35.68, longitude: 139.76),
            GeoPoint(latitude: 35.4, longitude: 139.5),
            GeoPoint(latitude: 36.0, longitude: 140.1),
        ] {
            let expected = markers.min {
                squared($0, point) < squared($1, point)
            }
            XCTAssertEqual(index.nearest(position: point)?.state.id, expected?.state.id)
        }
    }

    /// Beyond the rings the index searches it falls back to a scan rather than
    /// returning nothing — the answer still has to be right, just slower.
    func testNearestFallsBackWhenNothingIsClose() {
        let markers = [entity(0, 35.0, 139.0)]
        let index = MarkerGridIndex<Int> { markers }
        XCTAssertEqual(
            index.nearest(position: GeoPoint(latitude: -35.0, longitude: -70.0))?.state.id,
            "0"
        )
    }

    func testEmptyIndexHasNoNearest() {
        let index = MarkerGridIndex<Int> { [] }
        XCTAssertNil(index.nearest(position: GeoPoint(latitude: 35.0, longitude: 139.0)))
    }

    /// The index borrows the manager's markers, so a change has to be seen.
    func testInvalidateShowsLaterMarkers() {
        var markers = [entity(0, 35.0, 139.0)]
        let index = MarkerGridIndex<Int> { markers }
        let box = bounds(34.9, 138.9, 35.1, 139.1)
        XCTAssertEqual(index.inBounds(box).count, 1)

        markers.append(entity(1, 35.001, 139.001))
        XCTAssertEqual(index.inBounds(box).count, 1, "a stale index should stay stale until told")

        index.invalidate()
        XCTAssertEqual(index.inBounds(box).count, 2)
    }

    private func squared(_ entity: MarkerEntity<Int>, _ point: GeoPoint) -> Double {
        let deltaLat = entity.state.position.latitude - point.latitude
        let deltaLon = entity.state.position.longitude - point.longitude
        return deltaLat * deltaLat + deltaLon * deltaLon
    }

    /// 間引きクエリは、覆ったセルすべてから 1 本ずつ返す。
    ///
    /// 呼び出し側は自分でも 1 セル 1 本に落とすつもりでこれを呼ぶ。返ってきては
    /// 困るのは**穴**で、箱の中にマーカーを持つセルが何も返さないと、地図上では
    /// 街路樹の無い一角になり、どこにもエラーは出ない。
    ///
    /// android-sdk の `thinnedQueryKeepsOneMarkerFromEveryCellItCovers` と同じ。
    func testThinnedQueryKeepsOneMarkerFromEveryCellItCovers() {
        let markers = scatter(count: 20_000, latitude: 35.68, longitude: 139.76, spread: 0.4)
        let index = MarkerGridIndex<Int> { markers }
        let box = bounds(35.60, 139.68, 35.76, 139.84)

        guard let kept = index.inBoundsThinned(box, minSeparationDegrees: 0.01) else {
            return XCTFail("0.01 度はセルより粗いので、必ず答えられるはず")
        }

        let inside = markers.filter { box.contains(point: $0.state.position) }
        XCTAssertGreaterThan(inside.count, 1_000, "比較できるだけの中身が要る")

        // index と同じ前提: セルは一辺 0.005 度。
        func cellOf(_ entity: MarkerEntity<Int>) -> String {
            let lat = (entity.state.position.latitude / 0.005).rounded(.down)
            let lon = (entity.state.position.longitude / 0.005).rounded(.down)
            return "\(lat),\(lon)"
        }

        for entity in kept {
            XCTAssertTrue(box.contains(point: entity.state.position), "箱の外のマーカーを返した")
        }
        XCTAssertEqual(
            Set(inside.map(cellOf)), Set(kept.map(cellOf)),
            "埋まっているセルにつき 1 本、多くも少なくもなく"
        )
        XCTAssertEqual(Set(kept.map(cellOf)).count, kept.count, "同じセルから 2 本返っている")
        // 箱は一辺 0.16 度で約 1,024 セル、その中にこのマーカーが 3,200 本ほど
        // 入る -- 1 セルあたり 3 本。これが無いと、間引く必要のないほど疎な
        // データでも上の assert が通ってしまい、何も証明しない。
        XCTAssertLessThan(kept.count * 2, inside.count, "間引きを働かせるには疎すぎる")
    }

    /// セルが呼び出し側の分離距離より粗いと、頼まれた以上に間引いてしまう。
    func testThinnedQueryDeclinesWhenItsCellsAreTooCoarse() {
        let index = MarkerGridIndex<Int> {
            self.scatter(count: 2_000, latitude: 35.68, longitude: 139.76, spread: 0.4)
        }
        XCTAssertNil(index.inBoundsThinned(bounds(35.6, 139.7, 35.7, 139.8), minSeparationDegrees: 0.004))
    }

    /// 通常クエリが覚えた日付変更線の折り返しは、ここでも成り立つ必要がある。
    func testThinnedQueryCrossesTheAntimeridian() {
        let markers = [
            entity(0, -18.0, 179.99),
            entity(1, -18.0, -179.99),
            entity(2, -18.0, 178.0),
        ]
        let index = MarkerGridIndex<Int> { markers }
        guard let kept = index.inBoundsThinned(bounds(-18.5, 179.5, -17.5, -179.5), minSeparationDegrees: 0.01) else {
            return XCTFail("答えられるはず")
        }
        XCTAssertEqual(ids(kept), ["0", "1"])
    }
}
