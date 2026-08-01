import XCTest

@testable import MapConductorCore

/// 自前の平面 union（react-sdk PolygonUnion.ts / android-sdk PolygonHoleUnion.kt と
/// 同一アルゴリズム）の性質テスト。Android 版 PolygonHoleUnionTest と同じケースを検証する。
final class PolygonHoleUnionTests: XCTestCase {
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

    private func signedAreaLonLat(_ ring: [GeoPointProtocol]) -> Double {
        var area = 0.0
        for i in ring.indices {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            area += (a.longitude * b.latitude) - (b.longitude * a.latitude)
        }
        return area / 2
    }

    private func pointInRing(_ lat: Double, _ lng: Double, _ ring: [GeoPointProtocol]) -> Bool {
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

    private func insideAny(_ lat: Double, _ lng: Double, _ rings: [[GeoPointProtocol]]) -> Bool {
        rings.contains { pointInRing(lat, lng, $0) }
    }

    func testTwoOverlappingSquaresMergeIntoOneClockwiseRing() throws {
        let merged = try XCTUnwrap(unionHoleRings([rect(0, 0, 2, 2), rect(1, 1, 3, 3)]))
        XCTAssertEqual(merged.count, 1)
        let out = merged[0]
        // 穴は時計回りへ正規化される
        XCTAssertLessThan(signedAreaLonLat(out), 0)
        // 両方の矩形の中心を含む
        XCTAssertTrue(pointInRing(0.5, 0.5, out))
        XCTAssertTrue(pointInRing(2.5, 2.5, out))
        // 面積 = 4 + 4 - 1(重なり) = 7
        XCTAssertEqual(abs(signedAreaLonLat(out)), 7.0, accuracy: 1e-6)
    }

    func testThreeSquareChainMergesIntoOneRing() throws {
        let merged = try XCTUnwrap(
            unionHoleRings([
                rect(0, 0, 2, 2),
                rect(0.5, 1.5, 1.5, 3.5),
                rect(0, 3, 2, 5),
            ])
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(pointInRing(1.0, 1.0, merged[0]))
        XCTAssertTrue(pointInRing(1.0, 2.5, merged[0]))
        XCTAssertTrue(pointInRing(1.0, 4.0, merged[0]))
    }

    func testDisjointSquaresRemainSeparateWithSameAreas() throws {
        let merged = try XCTUnwrap(unionHoleRings([rect(0, 0, 1, 1), rect(5, 5, 6, 6)]))
        XCTAssertEqual(merged.count, 2)
        let areas = merged.map { abs(signedAreaLonLat($0)) }.sorted()
        XCTAssertEqual(areas[0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(areas[1], 1.0, accuracy: 1e-6)
        for ring in merged {
            XCTAssertLessThan(signedAreaLonLat(ring), 0)
        }
    }

    func testContainedSquareIsAbsorbedByOuter() throws {
        let merged = try XCTUnwrap(unionHoleRings([rect(0, 0, 4, 4), rect(1, 1, 2, 2)]))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(abs(signedAreaLonLat(merged[0])), 16.0, accuracy: 1e-6)
    }

    func testIdenticalSquaresCollapseToOne() throws {
        let square = rect(0, 0, 2, 2)
        let merged = try XCTUnwrap(unionHoleRings([square, square]))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(abs(signedAreaLonLat(merged[0])), 4.0, accuracy: 1e-6)
    }

    func testEdgeSharingSquaresMergeWithoutSlit() throws {
        // 右辺と左辺を完全共有する 2 矩形 → 1 リング、面積は合算
        let merged = try XCTUnwrap(unionHoleRings([rect(0, 0, 2, 2), rect(0, 2, 2, 4)]))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(abs(signedAreaLonLat(merged[0])), 8.0, accuracy: 1e-6)
    }

    func testFarFromOriginTokyoCoordinatesKeepPrecision() throws {
        // 東京近辺（lon≈139.7）の小さな矩形同士
        let merged = try XCTUnwrap(
            unionHoleRings([
                rect(35.6800, 139.7600, 35.6820, 139.7620),
                rect(35.6810, 139.7610, 35.6830, 139.7630),
            ])
        )
        XCTAssertEqual(merged.count, 1)
        let out = merged[0]
        XCTAssertTrue(pointInRing(35.6810, 139.7610, out))
        XCTAssertTrue(pointInRing(35.6825, 139.7625, out))
        let expected = 2.0e-3 * 2.0e-3 * 2.0 - 1.0e-3 * 1.0e-3
        XCTAssertEqual(abs(signedAreaLonLat(out)), expected, accuracy: expected * 1e-4)
    }

    func testSelfIntersectingBowtieDoesNotCrash() throws {
        // 自己交差リング（蝶ネクタイ）+ 重なる矩形。クラッシュせず有限のリングを返すこと
        let bowtie: [GeoPointProtocol] = [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 2, longitude: 2),
            GeoPoint(latitude: 0, longitude: 2),
            GeoPoint(latitude: 2, longitude: 0),
        ]
        let merged = try XCTUnwrap(unionHoleRings([bowtie, rect(0.5, 0.5, 1.5, 1.5)]))
        XCTAssertFalse(merged.isEmpty)
        for ring in merged {
            XCTAssertGreaterThanOrEqual(ring.count, 3)
            for p in ring {
                XCTAssertTrue(p.latitude.isFinite && p.longitude.isFinite)
            }
        }
    }

    func testDegenerateInputsReturnNil() {
        XCTAssertNil(unionHoleRings([rect(0, 0, 1, 1)]))
        XCTAssertNil(unionHoleRings([]))
        // 全リング縮退（3 点未満）→ 変更なし
        let twoPoints: [GeoPointProtocol] = [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 1, longitude: 1),
        ]
        let onePoint: [GeoPointProtocol] = [GeoPoint(latitude: 2, longitude: 2)]
        XCTAssertNil(unionHoleRings([twoPoints, onePoint]))
    }

    func testUnionHolesKeepsStateWhenUnchanged() {
        let state = PolygonState(
            points: rect(-10, -10, 10, 10),
            holes: [rect(0, 0, 1, 1)]
        )
        XCTAssertTrue(state.unionHoles() === state)
    }

    func testSampledMembershipMatchesInputCoverage() throws {
        // 結合の前後で「いずれかの穴の内部か」の判定がサンプル格子上で一致すること
        let holes = [
            rect(0, 0, 2, 2),
            rect(1, 1, 3, 3),
            rect(10, 10, 11, 11),
        ]
        let merged = try XCTUnwrap(unionHoleRings(holes))
        var samples = 0
        var lat = -0.5
        while lat <= 11.5 {
            var lng = -0.5
            while lng <= 11.5 {
                let expected = holes.contains { pointInRing(lat, lng, $0) }
                let actual = insideAny(lat, lng, merged)
                XCTAssertEqual(expected, actual, "at (\(lat), \(lng))")
                samples += 1
                lng += 0.37
            }
            lat += 0.37
        }
        XCTAssertGreaterThan(samples, 500)
    }
}
