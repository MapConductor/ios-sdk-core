import XCTest

@testable import MapConductorCore

/// `splitPolygonWithHolesIntoSimpleRings`（分割方式）の性質テスト。
/// 出力リング群の偶奇塗り合成が「外周の内側かつ全穴の外側」と一致し、
/// 各リングが単純（自己交差なし・重複頂点なし・経度ステップ 180° 以下）であることを確認する。
final class PolygonHoleSplitTests: XCTestCase {
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

    private func filledByAny(_ lat: Double, _ lng: Double, _ rings: [[GeoPointProtocol]]) -> Bool {
        rings.contains { evenOddInside(lat, lng, $0) }
    }

    private func signedAreaLonLat(_ ring: [GeoPointProtocol]) -> Double {
        var area = 0.0
        for i in ring.indices {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            area += (a.longitude * b.latitude) - (b.longitude * a.latitude)
        }
        return area / 2
    }

    private func maxAbsLngStep(_ ring: [GeoPointProtocol]) -> Double {
        (0..<ring.count).map { i in
            abs(ring[(i + 1) % ring.count].longitude - ring[i].longitude)
        }.max() ?? 0
    }

    func testNoHolesReturnsSingleRing() {
        let rings = splitPolygonWithHolesIntoSimpleRings(outer: rect(0, 0, 10, 10), holes: [])
        XCTAssertEqual(rings.count, 1)
        XCTAssertTrue(filledByAny(5, 5, rings))
    }

    func testSingleHoleSplitsIntoTwoSimpleRings() {
        let rings = splitPolygonWithHolesIntoSimpleRings(
            outer: rect(0, 0, 10, 10),
            holes: [rect(4, 4, 6, 6)]
        )
        XCTAssertEqual(rings.count, 2)
        // 全リング CCW
        rings.forEach { XCTAssertGreaterThan(signedAreaLonLat($0), 0) }
        // 面積の合計 = 100 - 4
        let total = rings.map { signedAreaLonLat($0) }.reduce(0, +)
        XCTAssertEqual(total, 96.0, accuracy: 1e-9)
        // 穴は抜け、外周内は塗られる
        XCTAssertFalse(filledByAny(5, 5, rings))
        XCTAssertTrue(filledByAny(2, 2, rings))
        XCTAssertTrue(filledByAny(8, 8, rings))
        XCTAssertTrue(filledByAny(5, 8, rings))
        XCTAssertTrue(filledByAny(5, 2, rings))
        XCTAssertFalse(filledByAny(11, 5, rings))
    }

    func testTriangleHole() {
        let hole: [GeoPointProtocol] = [
            GeoPoint(latitude: 6, longitude: 5),
            GeoPoint(latitude: 4, longitude: 6),
            GeoPoint(latitude: 4, longitude: 4),
        ]
        let rings = splitPolygonWithHolesIntoSimpleRings(outer: rect(0, 0, 10, 10), holes: [hole])
        XCTAssertEqual(rings.count, 2)
        let total = rings.map { signedAreaLonLat($0) }.reduce(0, +)
        XCTAssertEqual(total, 100.0 - 2.0, accuracy: 1e-9)
        XCTAssertFalse(filledByAny(4.7, 5.0, rings))
        XCTAssertTrue(filledByAny(2, 2, rings))
        XCTAssertTrue(filledByAny(8, 8, rings))
    }

    func testTwoDisjointHoles() {
        let rings = splitPolygonWithHolesIntoSimpleRings(
            outer: rect(0, 0, 10, 10),
            holes: [rect(1, 1, 3, 3), rect(6, 6, 8, 8)]
        )
        XCTAssertEqual(rings.count, 3)
        let total = rings.map { signedAreaLonLat($0) }.reduce(0, +)
        XCTAssertEqual(total, 100.0 - 8.0, accuracy: 1e-9)
        XCTAssertFalse(filledByAny(2, 2, rings))
        XCTAssertFalse(filledByAny(7, 7, rings))
        XCTAssertTrue(filledByAny(5, 5, rings))
        XCTAssertTrue(filledByAny(9, 1, rings))
    }

    func testPartitionSingleHoleKeepsOnePiece() {
        let parts = partitionPolygonByHoles(outer: rect(0, 0, 10, 10), holes: [rect(4, 4, 6, 6)])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].holes.count, 1)
    }

    /// 緯度で分離できる 2 穴: 2 ピースに分かれ、各ピースが 1 穴を含む。
    func testPartitionTwoHolesSeparableByLatitude() {
        let parts = partitionPolygonByHoles(
            outer: rect(0, 0, 10, 10),
            holes: [rect(1, 1, 3, 3), rect(6, 6, 8, 8)]
        )
        XCTAssertEqual(parts.count, 2)
        var total = 0.0
        for part in parts {
            XCTAssertEqual(part.holes.count, 1)
            XCTAssertGreaterThan(signedAreaLonLat(part.outer), 0)
            if let probe = part.holes.first?.first {
                XCTAssertTrue(evenOddInside(probe.latitude, probe.longitude, part.outer))
            }
            total += signedAreaLonLat(part.outer)
        }
        // ピース面積の合計 = 外周面積
        XCTAssertEqual(total, 100.0, accuracy: 1e-9)
    }

    /// 緯度で分離できず経度でのみ分離できる 2 穴（横並び・同緯度帯）。
    func testPartitionTwoHolesSeparableByLongitudeOnly() {
        let parts = partitionPolygonByHoles(
            outer: rect(0, 0, 10, 10),
            holes: [rect(4, 1, 6, 3), rect(4, 6, 6, 8)]
        )
        XCTAssertEqual(parts.count, 2)
        parts.forEach { XCTAssertEqual($0.holes.count, 1) }
        let total = parts.map { signedAreaLonLat($0.outer) }.reduce(0, +)
        XCTAssertEqual(total, 100.0, accuracy: 1e-9)
    }

    /// 世界マスク + ドリフトで離れた 2 穴（サンプル実機構成）: 分離線で 2 ピースに分かれる。
    func testPartitionWorldMaskWithTwoSeparatedHoles() {
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
        let drift = 0.35
        let hole1: [GeoPointProtocol] = [
            GeoPoint(latitude: 43.10086924222251, longitude: 141.35290903949243 + drift),
            GeoPoint(latitude: 43.04444342582366, longitude: 141.4118953480885 + drift),
            GeoPoint(latitude: 43.05060149394299, longitude: 141.30656265416695 + drift),
        ]
        let hole2: [GeoPointProtocol] = [
            GeoPoint(latitude: 43.06035050410283, longitude: 141.31990479539704),
            GeoPoint(latitude: 43.038284739487004, longitude: 141.33324693662706),
            GeoPoint(latitude: 43.049062034871525, longitude: 141.28690055130158),
        ]
        let parts = partitionPolygonByHoles(outer: outer, holes: [hole1, hole2])
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            XCTAssertEqual(part.holes.count, 1)
            XCTAssertGreaterThan(signedAreaLonLat(part.outer), 0)
            assertSimple(part.outer)
            if let probe = part.holes.first?.first {
                XCTAssertTrue(evenOddInside(probe.latitude, probe.longitude, part.outer))
            }
        }
    }

    /// リングが自己交差していないこと（隣接しないエッジ同士が交差しない）。
    private func assertSimple(_ ring: [GeoPointProtocol], file: StaticString = #filePath, line: UInt = #line) {
        let n = ring.count
        func seg(_ i: Int) -> (a: (Double, Double), b: (Double, Double)) {
            let p = ring[i]
            let q = ring[(i + 1) % n]
            return ((p.longitude, p.latitude), (q.longitude, q.latitude))
        }
        func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }
        func intersects(_ s1: (a: (Double, Double), b: (Double, Double)), _ s2: (a: (Double, Double), b: (Double, Double))) -> Bool {
            let d1 = cross(s2.a, s2.b, s1.a)
            let d2 = cross(s2.a, s2.b, s1.b)
            let d3 = cross(s1.a, s1.b, s2.a)
            let d4 = cross(s1.a, s1.b, s2.b)
            return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
                && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
        }
        for i in 0..<n {
            guard i + 2 < n else { continue }
            for j in (i + 2)..<n {
                if i == 0 && j == n - 1 { continue } // 隣接（閉じ）
                if intersects(seg(i), seg(j)) {
                    XCTFail("ring self-intersects between edge \(i) and \(j)", file: file, line: line)
                    return
                }
            }
        }
    }

    /// 実機で発生した構成: 世界マスク + ドリフトで東へ移動した穴 1 + 札幌の穴 2。
    /// 全リングが単純で、合成塗りが正しいこと。
    func testWorldMaskWithTwoSeparatedHolesStaysSimple() {
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
        let drift = 0.35
        let hole1: [GeoPointProtocol] = [
            GeoPoint(latitude: 43.10086924222251, longitude: 141.35290903949243 + drift),
            GeoPoint(latitude: 43.04444342582366, longitude: 141.4118953480885 + drift),
            GeoPoint(latitude: 43.05060149394299, longitude: 141.30656265416695 + drift),
        ]
        let hole2: [GeoPointProtocol] = [
            GeoPoint(latitude: 43.06035050410283, longitude: 141.31990479539704),
            GeoPoint(latitude: 43.038284739487004, longitude: 141.33324693662706),
            GeoPoint(latitude: 43.049062034871525, longitude: 141.28690055130158),
        ]
        let rings = splitPolygonWithHolesIntoSimpleRings(outer: outer, holes: [hole1, hole2])
        XCTAssertEqual(rings.count, 3)
        rings.forEach { ring in
            XCTAssertGreaterThan(signedAreaLonLat(ring), 0)
            XCTAssertLessThanOrEqual(maxAbsLngStep(ring), 180.0)
            assertSimple(ring)
        }
        // 両方の穴の重心は抜ける
        XCTAssertFalse(filledByAny(43.0653, 141.3571 + drift, rings))
        XCTAssertFalse(filledByAny(43.0493, 141.3133, rings))
        // 実機で欠けて見えた領域（穴から離れた広域）は塗られる
        XCTAssertTrue(filledByAny(44.0, 140.0, rings))
        XCTAssertTrue(filledByAny(42.0, 140.0, rings))
        XCTAssertTrue(filledByAny(46.0, 143.0, rings))
        XCTAssertTrue(filledByAny(40.0, 143.0, rings))
        XCTAssertTrue(filledByAny(43.06, 141.5, rings))
        XCTAssertTrue(filledByAny(0.0, 0.0, rings))
        XCTAssertTrue(filledByAny(-45.0, -90.0, rings))
    }

    /// サンプルページ相当: 世界マスク外周 + 札幌近郊の三角形の穴。
    /// 東側の外周（経度 179.9）へ橋が張られ、全エッジの経度ステップが 180° 以下になる。
    func testWorldMaskWithSapporoHole() {
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
        let rings = splitPolygonWithHolesIntoSimpleRings(outer: outer, holes: [hole])
        XCTAssertEqual(rings.count, 2)
        rings.forEach { ring in
            XCTAssertGreaterThan(signedAreaLonLat(ring), 0)
            XCTAssertLessThanOrEqual(maxAbsLngStep(ring), 180.0)
        }
        // 穴の重心は抜ける
        XCTAssertFalse(filledByAny(43.0653, 141.3571, rings))
        // 穴の外は塗られる
        XCTAssertTrue(filledByAny(35.0, 139.0, rings))
        XCTAssertTrue(filledByAny(-30.0, 20.0, rings))
        XCTAssertTrue(filledByAny(43.07, 150.0, rings))
        XCTAssertTrue(filledByAny(43.07, 100.0, rings))
    }
}
