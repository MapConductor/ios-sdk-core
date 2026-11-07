import XCTest

@testable import MapConductorCore

/// `MapViewContentBuilder` が組み立てた content で、明示した設定が残ることを確かめる。
///
/// 以前の `merge` は有効なタイル設定しか引き継がず、ビルダーの中で
/// `markerTilingOptions = .Disabled` を設定しても既定（タイル有効）に戻っていた。
/// 1 式だけのビルダーも `buildBlock` で新しい content にマージされるので必ず踏む。
final class MapViewContentMergeTests: XCTestCase {
    private func build(@MapViewContentBuilder _ body: () -> MapViewContent) -> MapViewContent {
        body()
    }

    private func content(tiling: MarkerTilingOptions?) -> MapViewContent {
        var content = MapViewContent()
        if let tiling { content.markerTilingOptions = tiling }
        return content
    }

    func testUnsetTilingReadsDefault() {
        let content = MapViewContent()
        XCTAssertTrue(content.markerTilingOptions.enabled)
        XCTAssertEqual(content.markerTilingOptions.minMarkerCount, MarkerTilingOptions.Default.minMarkerCount)
        XCTAssertNil(content.explicitMarkerTilingOptions)
    }

    /// 報告された形そのもの: ビルダーの中で即時実行クロージャが `.Disabled` を設定する。
    func testDisabledSetInsideBuilderSurvives() {
        let built = build {
            { () -> MapViewContent in
                var content = MapViewContent()
                content.markerTilingOptions = .Disabled
                return content
            }()
        }
        XCTAssertFalse(built.markerTilingOptions.enabled)
    }

    func testDisabledSurvivesNextToItemsThatDoNotSetTiling() {
        let built = build {
            content(tiling: .Disabled)
            content(tiling: nil)
            Marker(state: MarkerState(position: GeoPoint(latitude: 35, longitude: 139)))
        }
        XCTAssertFalse(built.markerTilingOptions.enabled)
        XCTAssertEqual(built.markers.count, 1)
    }

    func testEnabledCustomOptionsSurvive() {
        let built = build {
            content(tiling: MarkerTilingOptions(minMarkerCount: 10, declutterPx: 4))
            content(tiling: nil)
        }
        XCTAssertTrue(built.markerTilingOptions.enabled)
        XCTAssertEqual(built.markerTilingOptions.minMarkerCount, 10)
        XCTAssertEqual(built.markerTilingOptions.declutterPx, 4)
    }

    func testUnsetEverywhereFallsBackToDefault() {
        let built = build {
            content(tiling: nil)
            Marker(state: MarkerState(position: GeoPoint(latitude: 35, longitude: 139)))
        }
        XCTAssertTrue(built.markerTilingOptions.enabled)
        XCTAssertNil(built.explicitMarkerTilingOptions)
    }

    func testLaterExplicitSettingWins() {
        let disabledLast = build {
            content(tiling: MarkerTilingOptions(minMarkerCount: 10))
            content(tiling: .Disabled)
        }
        XCTAssertFalse(disabledLast.markerTilingOptions.enabled)

        let enabledLast = build {
            content(tiling: .Disabled)
            content(tiling: MarkerTilingOptions(minMarkerCount: 10))
        }
        XCTAssertTrue(enabledLast.markerTilingOptions.enabled)
        XCTAssertEqual(enabledLast.markerTilingOptions.minMarkerCount, 10)
    }

    func testDisabledSurvivesConditionalsAndLoops() {
        let flag = true
        let built = build {
            if flag {
                content(tiling: .Disabled)
            }
            for _ in 0..<2 {
                content(tiling: nil)
            }
        }
        XCTAssertFalse(built.markerTilingOptions.enabled)

        let nested = build {
            for i in 0..<3 {
                if i == 1 {
                    content(tiling: .Disabled)
                } else {
                    content(tiling: nil)
                }
            }
        }
        XCTAssertFalse(nested.markerTilingOptions.enabled)
    }
}
