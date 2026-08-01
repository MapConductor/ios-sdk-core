import XCTest

@testable import MapConductorCore

/// `bridgeHolesIntoSingleRing`（android-sdk-core HoleBridge.kt の移植）の性質テスト。
/// ブリッジ後の単一リングは「外周の内側かつ全穴の外側」の点を含み、穴の内側の点を含まない
/// （偶奇規則）ことを検証する。
final class HoleBridgeTests: XCTestCase {
    private func rect(
        _ south: Double, _ west: Double, _ north: Double, _ east: Double
    ) -> [GeoPointProtocol] {
        [
            GeoPoint(latitude: south, longitude: west),
            GeoPoint(latitude: south, longitude: east),
            GeoPoint(latitude: north, longitude: east),
            GeoPoint(latitude: north, longitude: west),
        ]
    }

    /// 偶奇規則（ray casting）。ブリッジ済みリングは弱単純ポリゴンなので偶奇規則で
    /// 塗り領域が決まる（TomTom 等の塗りと同じ判定）。
    private func evenOddInside(_ lat: Double, _ lng: Double, _ ring: [GeoPointProtocol]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i]
            let b = ring[j]
            if (a.latitude > lat) != (b.latitude > lat) {
                let x = a.longitude
                    + ((lat - a.latitude) / (b.latitude - a.latitude))
                    * (b.longitude - a.longitude)
                if lng < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    func testNoHolesReturnsOuterUnchanged() {
        let outer = rect(0, 0, 10, 10)
        let bridged = bridgeHolesIntoSingleRing(outer: outer, holes: [])
        XCTAssertEqual(bridged.count, outer.count)
        for (a, b) in zip(bridged, outer) {
            XCTAssertEqual(a.latitude, b.latitude)
            XCTAssertEqual(a.longitude, b.longitude)
        }
    }

    func testSingleHoleIsCutOut() {
        let outer = rect(0, 0, 10, 10)
        let hole = rect(4, 4, 6, 6)
        let bridged = bridgeHolesIntoSingleRing(outer: outer, holes: [hole])

        // 元の頂点 + 穴頂点 + 橋の複製 2 点
        XCTAssertEqual(bridged.count, outer.count + hole.count + 2)

        // 穴の中心は塗られない
        XCTAssertFalse(evenOddInside(5, 5, bridged))
        // 穴の外（外周の内側）は塗られる
        XCTAssertTrue(evenOddInside(2, 2, bridged))
        XCTAssertTrue(evenOddInside(8, 8, bridged))
        // 外周の外側は塗られない
        XCTAssertFalse(evenOddInside(11, 11, bridged))
        XCTAssertFalse(evenOddInside(-1, 5, bridged))
    }

    func testTwoDisjointHolesAreBothCutOut() {
        let outer = rect(0, 0, 10, 10)
        let hole1 = rect(1, 1, 3, 3)
        let hole2 = rect(6, 6, 8, 8)
        let bridged = bridgeHolesIntoSingleRing(outer: outer, holes: [hole1, hole2])

        XCTAssertFalse(evenOddInside(2, 2, bridged))
        XCTAssertFalse(evenOddInside(7, 7, bridged))
        XCTAssertTrue(evenOddInside(5, 5, bridged))
        XCTAssertTrue(evenOddInside(9, 9, bridged))
        XCTAssertFalse(evenOddInside(11, 5, bridged))
    }

    func testWindingIndependence() {
        let outer = rect(0, 0, 10, 10)
        let holeCw: [GeoPointProtocol] = rect(4, 4, 6, 6).reversed()
        let bridgedFromCwHole = bridgeHolesIntoSingleRing(outer: outer, holes: [holeCw])
        let bridgedFromCcwHole = bridgeHolesIntoSingleRing(outer: outer, holes: [rect(4, 4, 6, 6)])

        for probe in [(5.0, 5.0), (2.0, 2.0), (8.0, 8.0)] {
            XCTAssertEqual(
                evenOddInside(probe.0, probe.1, bridgedFromCwHole),
                evenOddInside(probe.0, probe.1, bridgedFromCcwHole)
            )
        }
        XCTAssertFalse(evenOddInside(5, 5, bridgedFromCwHole))
    }

    func testClosedRingInputIsHandled() {
        var outer = rect(0, 0, 10, 10)
        outer.append(outer[0]) // closed ring
        var hole = rect(4, 4, 6, 6)
        hole.append(hole[0])
        let bridged = bridgeHolesIntoSingleRing(outer: outer, holes: [hole])
        XCTAssertFalse(evenOddInside(5, 5, bridged))
        XCTAssertTrue(evenOddInside(2, 2, bridged))
    }

    func testDegenerateHoleIsIgnored() {
        let outer = rect(0, 0, 10, 10)
        let degenerate: [GeoPointProtocol] = [
            GeoPoint(latitude: 5, longitude: 5),
            GeoPoint(latitude: 6, longitude: 6),
        ]
        let bridged = bridgeHolesIntoSingleRing(outer: outer, holes: [degenerate])
        XCTAssertEqual(bridged.count, outer.count)
        XCTAssertTrue(evenOddInside(5, 5.5, bridged))
    }

    /// separation > 0 のとき、リングは厳密に単純（座標が一致する往復エッジなし）になり、
    /// 穴は引き続き抜ける。
    func testSeparationProducesStrictlySimpleRing() {
        let outer = rect(0, 0, 10, 10)
        let hole = rect(4, 4, 6, 6)
        let bridged = bridgeHolesIntoSingleRing(outer: outer, holes: [hole], separation: 1e-6)

        XCTAssertEqual(bridged.count, outer.count + hole.count + 2)
        // 穴は抜ける
        XCTAssertFalse(evenOddInside(5, 5, bridged))
        XCTAssertTrue(evenOddInside(2, 2, bridged))

        // 座標が完全に一致する頂点（ゼロ幅橋の複製）が存在しない
        var seen = Set<String>()
        var duplicates = 0
        for p in bridged {
            let key = "\(p.latitude),\(p.longitude)"
            if !seen.insert(key).inserted { duplicates += 1 }
        }
        XCTAssertEqual(duplicates, 0)
    }

    /// サンプルページ相当: 世界マスク外周 + 札幌近郊の三角形の穴。
    func testWorldMaskWithTriangleHole() {
        let outer: [GeoPointProtocol] = [
            GeoPoint(latitude: 85.0, longitude: 90.0),
            GeoPoint(latitude: 85.0, longitude: 0.1),
            GeoPoint(latitude: 85.0, longitude: -90.0),
            GeoPoint(latitude: 85.0, longitude: -179.9),
            GeoPoint(latitude: 0.0, longitude: -179.9),
            GeoPoint(latitude: -85.0, longitude: -179.9),
            GeoPoint(latitude: -85.0, longitude: -90.0),
            GeoPoint(latitude: -85.0, longitude: 0.1),
            GeoPoint(latitude: -85.0, longitude: 90.0),
            GeoPoint(latitude: -85.0, longitude: 179.9),
            GeoPoint(latitude: 0.0, longitude: 179.9),
            GeoPoint(latitude: 85.0, longitude: 179.9),
        ]
        let hole: [GeoPointProtocol] = [
            GeoPoint(latitude: 43.10086924222251, longitude: 141.35290903949243),
            GeoPoint(latitude: 43.04444342582366, longitude: 141.4118953480885),
            GeoPoint(latitude: 43.05060149394299, longitude: 141.30656265416695),
        ]
        let bridged = bridgeHolesIntoSingleRing(outer: outer, holes: [hole])

        // 穴の重心は抜ける
        XCTAssertFalse(evenOddInside(43.0653, 141.3571, bridged))
        // 穴の外（札幌から離れた点）は塗られる
        XCTAssertTrue(evenOddInside(35.0, 139.0, bridged))
        XCTAssertTrue(evenOddInside(-30.0, 20.0, bridged))
    }

    /// wrap-aware: 世界マスク外周 + 東経の穴では、西向きの橋が経度 180° 超を跨ぐため、
    /// 東向きに張り替えて全エッジの経度ステップを 180° 以下に抑える。穴は引き続き抜ける。
    func testWrapAwareBridgeKeepsLngStepsUnder180() {
        let outer: [GeoPointProtocol] = [
            GeoPoint(latitude: 85.0, longitude: 90.0),
            GeoPoint(latitude: 85.0, longitude: 0.1),
            GeoPoint(latitude: 85.0, longitude: -90.0),
            GeoPoint(latitude: 85.0, longitude: -179.9),
            GeoPoint(latitude: 0.0, longitude: -179.9),
            GeoPoint(latitude: -85.0, longitude: -179.9),
            GeoPoint(latitude: -85.0, longitude: -90.0),
            GeoPoint(latitude: -85.0, longitude: 0.1),
            GeoPoint(latitude: -85.0, longitude: 90.0),
            GeoPoint(latitude: -85.0, longitude: 179.9),
            GeoPoint(latitude: 0.0, longitude: 179.9),
            GeoPoint(latitude: 85.0, longitude: 179.9),
        ]
        let hole: [GeoPointProtocol] = [
            GeoPoint(latitude: 43.10086924222251, longitude: 141.35290903949243),
            GeoPoint(latitude: 43.04444342582366, longitude: 141.4118953480885),
            GeoPoint(latitude: 43.05060149394299, longitude: 141.30656265416695),
        ]

        // 標準（西向き）は 180° 超のエッジを含む
        let west = bridgeHolesIntoSingleRing(outer: outer, holes: [hole])
        let westMax = (0..<west.count).map { i in
            abs(west[(i + 1) % west.count].longitude - west[i].longitude)
        }.max() ?? 0
        XCTAssertGreaterThan(westMax, 180.0)

        // wrap-aware は全エッジ 180° 以下
        let bridged = bridgeHolesIntoSingleRingWrapAware(outer: outer, holes: [hole], separation: 1e-6)
        let maxStep = (0..<bridged.count).map { i in
            abs(bridged[(i + 1) % bridged.count].longitude - bridged[i].longitude)
        }.max() ?? 0
        XCTAssertLessThanOrEqual(maxStep, 180.0)

        // 穴は抜け、外は塗られる
        XCTAssertFalse(evenOddInside(43.0653, 141.3571, bridged))
        XCTAssertTrue(evenOddInside(35.0, 139.0, bridged))
        XCTAssertTrue(evenOddInside(-30.0, 20.0, bridged))
    }
}
