import UIKit
import XCTest

@testable import MapConductorCore

/// 穴のユニオンを適用する「層」が android-sdk と揃っていることを確認する。
///
/// android-sdk は 2 段構えになっている:
/// 1. `PolygonComponent.kt` の `Polygon(state)` コンポーザブルが `LaunchedEffect(state)` の
///    中で `state.unionHolesInPlace()` を呼ぶ（1 state インスタンスにつき 1 回）。
/// 2. 各プロバイダの `PolygonOverlayRenderer` が、ジオメトリを組み立てる時点で
///    `resolveHoles(state)`（= `state.unionHoles()`）を通す。
///
/// 2 が要るのは、頂点ドラッグのように後から `state.holes` が差し替わる経路では 1 が
/// 再実行されないため。iOS も `Polygon`（MapViewContent.swift）＋各レンダラの
/// `resolveHoles(_:)` で同じ 2 段構えにしてある。
final class PolygonHoleUnionPlacementTests: XCTestCase {
    /// (minLon, minLat) - (maxLon, maxLat) の矩形リング。
    private func rect(_ minLon: Double, _ minLat: Double, _ maxLon: Double, _ maxLat: Double) -> [GeoPointProtocol] {
        [
            GeoPoint(latitude: minLat, longitude: minLon),
            GeoPoint(latitude: minLat, longitude: maxLon),
            GeoPoint(latitude: maxLat, longitude: maxLon),
            GeoPoint(latitude: maxLat, longitude: minLon),
        ]
    }

    private func outerRing() -> [GeoPointProtocol] { rect(0, 0, 10, 10) }

    /// 重なる 2 つの穴を持つ state。
    private func overlappingHolesState() -> PolygonState {
        PolygonState(
            points: outerRing(),
            holes: [rect(1, 1, 4, 4), rect(3, 3, 6, 6)],
            id: "poly-overlapping"
        )
    }

    /// `Polygon(state:)` を通しただけで穴がマージされること。
    func testComponentInitAppliesHoleUnion() {
        let state = overlappingHolesState()
        XCTAssertEqual(state.holes.count, 2, "前提: マージ前は穴が 2 つ")

        _ = Polygon(state: state)

        XCTAssertEqual(state.holes.count, 1, "重なった 2 つの穴が 1 つにマージされるべき")
        XCTAssertTrue(state.holesUnionApplied)
    }

    /// バルク API `Polygons` を通しても同じく適用されること。
    func testBulkPolygonsAppliesHoleUnion() {
        let state = overlappingHolesState()
        var content = MapViewContent()

        Polygons([state]).append(to: &content)

        XCTAssertEqual(content.polygons.count, 1)
        XCTAssertEqual(state.holes.count, 1)
    }

    /// 重ならない穴は数が変わらないが、フラグは立ち再計算されない
    /// （SwiftUI の body 評価ごとに O(n^2) を回さないため）。
    func testDisjointHolesAreNotRecomputedOnEveryInit() {
        let state = PolygonState(
            points: outerRing(),
            holes: [rect(1, 1, 2, 2), rect(7, 7, 8, 8)],
            id: "poly-disjoint"
        )

        _ = Polygon(state: state)
        XCTAssertEqual(state.holes.count, 2, "重ならない穴は 2 つのまま")
        XCTAssertTrue(state.holesUnionApplied)

        // 2 回目以降は再計算しない（android-sdk の LaunchedEffect(state) と同じ回数）。
        let holesAfterFirst = state.holes
        _ = Polygon(state: state)
        XCTAssertEqual(state.holes.count, holesAfterFirst.count)
    }

    /// 穴が 1 つ以下なら何もしない（android-sdk の `holes.size <= 1` ガードと同じ）。
    func testSingleHoleIsUntouched() {
        let hole = rect(2, 2, 5, 5)
        let state = PolygonState(points: outerRing(), holes: [hole], id: "poly-single")

        _ = Polygon(state: state)

        XCTAssertEqual(state.holes.count, 1)
        XCTAssertEqual(state.holes[0].count, hole.count)
    }

    /// 穴なしのポリゴンも壊れないこと。
    func testNoHolesIsUntouched() {
        let state = PolygonState(points: outerRing(), id: "poly-none")
        _ = Polygon(state: state)
        XCTAssertTrue(state.holes.isEmpty)
    }

    /// `Polygon(points:...)` 経由でも初期化子が集約されていること（穴なしなので no-op）。
    func testPointsInitFunnelsThroughStateInit() {
        let polygon = Polygon(points: outerRing(), id: "poly-points")
        XCTAssertTrue(polygon.state.holesUnionApplied)
        XCTAssertEqual(polygon.id, "poly-points")
    }

    /// コンポーネント層のユニオンは 1 回きりなので、後から `holes` を差し替えると
    /// state 上は未結合のまま残る。これがレンダラ側でも結合する理由。
    func testHolesReplacedAfterComponentUnionStayUnmerged() {
        let state = overlappingHolesState()
        _ = Polygon(state: state)
        XCTAssertEqual(state.holes.count, 1, "前提: 初回は結合される")

        // 頂点ドラッグ相当（ViewModel が state.holes を丸ごと差し替える）。
        state.holes = [rect(1, 1, 4, 4), rect(3, 3, 6, 6)]
        _ = Polygon(state: state)

        XCTAssertEqual(state.holes.count, 2, "コンポーネント層は再実行されない")
    }

    /// レンダラ側の `resolveHoles(_:)` に相当する `unionHoles()` は、差し替え後の
    /// 未結合な穴でも毎回結合すること（android-sdk の各レンダラと同じ）。
    func testRendererSideUnionMergesReplacedHoles() {
        let state = overlappingHolesState()
        _ = Polygon(state: state)
        state.holes = [rect(1, 1, 4, 4), rect(3, 3, 6, 6)]

        let resolved = state.unionHoles()

        XCTAssertEqual(resolved.holes.count, 1, "レンダラ側では毎回結合されるべき")
        XCTAssertEqual(resolved.id, state.id, "id は保持されること")
        XCTAssertEqual(state.holes.count, 2, "元の state は書き換えないこと（コピーを返す）")
    }

    /// バックグラウンド版（ArcGIS / HERE が使う）も同期版と同じ結果になること。
    func testBackgroundUnionMatchesSynchronousUnion() async {
        let state = overlappingHolesState()
        let sync = state.unionHoles()
        let background = await state.unionHolesInBackground()

        XCTAssertEqual(background.holes.count, sync.holes.count)
        XCTAssertEqual(background.holes[0].count, sync.holes[0].count)
        for (lhs, rhs) in zip(background.holes[0], sync.holes[0]) {
            XCTAssertEqual(lhs.latitude, rhs.latitude, accuracy: 1e-12)
            XCTAssertEqual(lhs.longitude, rhs.longitude, accuracy: 1e-12)
        }
    }

    /// 穴が 1 つ以下ならバックグラウンド版も同じインスタンスを返すこと（無駄な hop を作らない）。
    func testBackgroundUnionSkipsWhenNothingToMerge() async {
        let state = PolygonState(points: outerRing(), holes: [rect(1, 1, 2, 2)], id: "poly-one")
        let resolved = await state.unionHolesInBackground()
        XCTAssertTrue(resolved === state)
    }

    /// マージ後も id / スタイルなど他のプロパティは保持されること
    /// （in-place なので state インスタンス自体が同一であることを含む）。
    func testUnionPreservesIdentityAndStyle() {
        let state = PolygonState(
            points: outerRing(),
            holes: [rect(1, 1, 4, 4), rect(3, 3, 6, 6)],
            id: "poly-keep",
            strokeColor: .blue,
            strokeWidth: 3.0,
            fillColor: .green,
            geodesic: true,
            zIndex: 42
        )

        let polygon = Polygon(state: state)

        XCTAssertTrue(polygon.state === state, "in-place なので同じインスタンスであるべき")
        XCTAssertEqual(polygon.state.id, "poly-keep")
        XCTAssertEqual(polygon.state.strokeColor, .blue)
        XCTAssertEqual(polygon.state.strokeWidth, 3.0)
        XCTAssertEqual(polygon.state.fillColor, .green)
        XCTAssertTrue(polygon.state.geodesic)
        XCTAssertEqual(polygon.state.zIndex, 42)
    }
}
