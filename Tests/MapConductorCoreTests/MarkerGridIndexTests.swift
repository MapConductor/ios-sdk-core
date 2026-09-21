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
    /// 箱の外のマーカーが混じるのは正しい。セルの代表は箱と無関係に決まるので、
    /// 縁のセルの代表が箱の外に落ちることがある。そこを縁で切り捨てないことが、
    /// 隣のタイルと判断を揃える条件そのもの（`MarkerTileSeamTests`）。
    ///
    /// android-sdk の `thinnedQueryKeepsOneMarkerFromEveryCellItCovers` と同じ。
    func testThinnedQueryKeepsOneMarkerFromEveryCellItCovers() {
        let markers = scatter(count: 60_000, latitude: 35.68, longitude: 139.76, spread: 0.4)
        let index = MarkerGridIndex<Int> { markers }
        let box = bounds(35.60, 139.68, 35.76, 139.84)

        // index が選ぶ段を、こちらでも同じ式で出す。0.005 度に対しては段 16 --
        // 偶数段なので geocell でちょうど 9 文字になり、文字列で名指しできる。
        XCTAssertEqual(MarkerGrid.level(forSeparation: 0.005), 16)
        func cellOf(_ entity: MarkerEntity<Int>) -> String {
            MarkerGrid.geocell(
                latitude: entity.state.position.latitude,
                longitude: entity.state.position.longitude,
                characters: 9
            )
        }

        guard let kept = index.inBoundsThinned(box, minSeparationDegrees: 0.005) else {
            return XCTFail("0.005 度はセルより粗いので、必ず答えられるはず")
        }

        let inside = markers.filter { box.contains(point: $0.state.position) }
        XCTAssertGreaterThan(inside.count, 1_000, "比較できるだけの中身が要る")

        // 箱の中にいるマーカーのセルは、1 つ残らず代表を持っていること。
        XCTAssertTrue(
            Set(inside.map(cellOf)).isSubset(of: Set(kept.map(cellOf))),
            "埋まっているセルのどれかが、代表を返していない"
        )
        XCTAssertEqual(Set(kept.map(cellOf)).count, kept.count, "同じセルから 2 本返っている")
        // はみ出しは縁のセル 1 つぶんまで。箱は 0.16 度四方で段 16 のセルを
        // 縦 58 x 横 30 ほど覆うから、縁は全体の 1 割に満たない。
        let outside = kept.filter { !box.contains(point: $0.state.position) }
        XCTAssertLessThan(
            Double(outside.count), Double(kept.count) * 0.15,
            "縁のセル 1 つぶんでは説明のつかない数が箱の外にいる"
        )
        // 箱は一辺 0.16 度で段 16 の正方セル（0.00275 度）を約 3,400 個覆い、
        // その中にこのマーカーが 9,600 本ほど入る -- 1 セルあたり 2.8 本。
        // これが無いと、間引く必要のないほど疎なデータでも上の assert が
        // 通ってしまい、何も証明しない。
        XCTAssertLessThan(kept.count * 2, inside.count, "間引きを働かせるには疎すぎる")
    }

    /// セルが呼び出し側の分離距離より粗いと、頼まれた以上に間引いてしまう。
    ///
    /// 平らなグリッドだったころ、この下限は 0.005 度だった。階層になった今は
    /// 一番細かい段（根から 18 段、一辺 0.000687 度）が下限で、そこまでは
    /// 段を選び直して応じる。ズームが深いところで間引きが効くようになった
    /// のはこの差による。
    func testThinnedQueryDeclinesWhenItsCellsAreTooCoarse() {
        let index = MarkerGridIndex<Int> {
            self.scatter(count: 2_000, latitude: 35.68, longitude: 139.76, spread: 0.4)
        }
        let box = bounds(35.6, 139.7, 35.7, 139.8)
        XCTAssertNil(index.inBoundsThinned(box, minSeparationDegrees: 0.0005))
        XCTAssertNotNil(
            index.inBoundsThinned(box, minSeparationDegrees: 0.001),
            "0.001 度は最下段より粗いので、段を選んで応じられるはず"
        )
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

    /// 段を自分で選ぶようになった以上、どの形の箱でも走査と一致する必要がある。
    ///
    /// 四角い箱しか試していないと、新しい段選びの**軸ごとの上限**が効く経路
    /// ---極端に平たい帯、極端に細い縦帯---を一度も通らない。そこを外しても
    /// 地図には何も起きず、その形の問い合わせだけが静かにマーカーを落とす。
    ///
    /// 全球に近い箱をここに入れてあるのは、実際にそれで落としたからで、
    /// `MarkerGrid.columnWalk` のコメントがその中身。
    ///
    /// android-sdk の `boundsQueryMatchesBruteForceForEveryShapeOfBox`、
    /// react-sdk の同名テストと対になる。
    func testBoundsQueryMatchesBruteForceForEveryShapeOfBox() {
        // 2 つ目の群の id をずらす。`scatter` は毎回 0 から振るので、そのまま
        // 足すと id が重なり、`ids()` が別のマーカーを 1 つに畳んでしまう --
        // 索引が重複を返していても集合としては一致し、テストが通ってしまう。
        let near = scatter(count: 30_000, latitude: 35.68, longitude: 139.76, spread: 0.8)
        let far = scatter(count: 10_000, latitude: -18.0, longitude: 179.95, spread: 0.6)
            .map {
                entity(
                    Int($0.state.id)! + 30_000,
                    $0.state.position.latitude,
                    $0.state.position.longitude
                )
            }
        let markers = near + far
        let index = MarkerGridIndex<Int> { markers }

        var nonEmpty = 0
        for (at, box) in [
            // タイル相当（z=14 から z=9 まで）。
            bounds(35.6800, 139.7600, 35.6946, 139.7820),
            bounds(35.6000, 139.6000, 35.7000, 139.8000),
            bounds(35.2000, 139.2000, 36.2000, 140.2000),
            // 極端に平たい帯と、極端に細い縦帯。面積では段が決まらない。
            bounds(35.6790, 139.0000, 35.6810, 140.5000),
            bounds(35.0000, 139.7590, 36.4000, 139.7610),
            // ほぼ全球。ここが 1 列しか歩かれていなかった。
            bounds(-85.0, -179.9, 85.0, 179.9),
            // 日付変更線をまたぐ箱。
            bounds(-18.5, 179.5, -17.5, -179.5),
            // 何も無い場所。空を返すのが正しい唯一の箱。
            bounds(10.0, 100.0, 11.0, 101.0),
        ].enumerated() {
            let expected = ids(markers.filter { box.contains(point: $0.state.position) })
            let found = index.inBounds(box)
            XCTAssertEqual(ids(found), expected, "箱 \(at): grid disagreed with a scan")
            XCTAssertEqual(found.count, expected.count, "箱 \(at): 同じマーカーを 2 度返した")
            if !expected.isEmpty { nonEmpty += 1 }
        }
        XCTAssertEqual(nonEmpty, 7, "空の集合どうしを比べているだけになっている")
    }
}
