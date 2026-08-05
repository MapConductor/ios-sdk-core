import UIKit
import XCTest

@testable import MapConductorCore

/// `PolylineState.hashCode()` の android-sdk 互換性テスト。
///
/// Kotlin 側（`android-sdk-core/.../polyline/Polyline.kt`）は
/// `extra → strokeColor → strokeWidth → geodesic → zIndex → points` の順に
/// `31 * result + hashCode` で畳み込む。zIndex を落とすと zIndex だけが異なる
/// Polyline が `==` で等価判定され、再描画が抑止されてしまう。
final class PolylineStateHashTests: XCTestCase {
    private func points() -> [GeoPointProtocol] {
        [
            GeoPoint(latitude: 35.681, longitude: 139.767),
            GeoPoint(latitude: 35.690, longitude: 139.700),
        ]
    }

    private func state(zIndex: Int) -> PolylineState {
        PolylineState(
            points: points(),
            id: "fixed-id",
            strokeColor: .black,
            strokeWidth: 1.0,
            geodesic: false,
            zIndex: zIndex,
            extra: nil
        )
    }

    /// zIndex だけが異なる 2 本は等価であってはならない。
    func testHashCodeDistinguishesZIndex() {
        XCTAssertNotEqual(state(zIndex: 0).hashCode(), state(zIndex: 5).hashCode())
        XCTAssertNotEqual(state(zIndex: 0), state(zIndex: 5))
    }

    /// zIndex を含む全プロパティが同じなら等価。
    func testHashCodeEqualForIdenticalStates() {
        XCTAssertEqual(state(zIndex: 3).hashCode(), state(zIndex: 3).hashCode())
        XCTAssertEqual(state(zIndex: 3), state(zIndex: 3))
    }

    /// android-sdk の畳み込みをそのまま再現した期待値と一致すること。
    /// `extra = nil → 0`、`strokeColor = .black`、`strokeWidth = 1.0`、`geodesic = false`。
    func testHashCodeMatchesAndroidFoldOrder() {
        let target = state(zIndex: 7)

        // Kotlin: Color.Black.hashCode() 相当（ARGB = 0xFF000000 を Int32 として解釈）
        let blackArgb = Int32(bitPattern: UInt32(0xFF00_0000))
        // Kotlin: java.lang.Double.hashCode(1.0)
        let strokeWidthHash: Int32 = {
            let bits = (1.0 as Double).bitPattern
            return Int32(truncatingIfNeeded: bits ^ (bits >> 32))
        }()
        // Kotlin: false.hashCode() == 1237
        let geodesicHash: Int32 = 1237

        var expected: Int32 = 0 // extra == nil
        expected = expected &* 31 &+ blackArgb
        expected = expected &* 31 &+ strokeWidthHash
        expected = expected &* 31 &+ geodesicHash
        expected = expected &* 31 &+ 7 // zIndex
        expected = expected &* 31 &+ Int32(truncatingIfNeeded: polylineListHashCode(points()))

        XCTAssertEqual(target.hashCode(), Int(expected))
    }

    /// `fingerPrint()` は以前から zIndex を含んでいる。回帰させないこと。
    func testFingerPrintStillDistinguishesZIndex() {
        XCTAssertNotEqual(state(zIndex: 0).fingerPrint(), state(zIndex: 5).fingerPrint())
    }
}

/// テスト内で android-sdk の `listHashCode` を再現するヘルパー。
/// 本体側の `listHashCode` は `private` なので、同じ式をここに置く。
private func polylineListHashCode(_ points: [GeoPointProtocol]) -> Int {
    var result: Int32 = 0
    for point in points {
        let latHash = Int64(point.latitude * 1e7)
        let lngHash = Int64(point.longitude * 1e7)
        let altHash = Int64((point.altitude ?? 0.0) * 1e7)

        func fold(_ value: Int64) -> Int32 {
            Int32(truncatingIfNeeded: value ^ (value >> 32))
        }

        var pointHash: Int32 = fold(latHash)
        pointHash = pointHash &* 31 &+ fold(lngHash)
        pointHash = pointHash &* 31 &+ fold(altHash)

        result = result &* 31 &+ pointHash
    }
    return Int(result)
}
