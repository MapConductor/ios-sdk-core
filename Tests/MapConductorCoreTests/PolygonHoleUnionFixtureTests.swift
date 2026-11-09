import XCTest

@testable import MapConductorCore

/// unionHoleRings keeps the area of the union of the holes: holes that touch at a
/// point or share (part of) an edge add up, overlaps count once.
///
/// js-sdk-core (`PolygonHoleUnion.test.mjs`) and android-sdk-core
/// (`PolygonHoleUnionFixtureTest`) read the same `polygon-hole-union-fixture.txt`;
/// the expected areas are shapely's unary_union.
final class PolygonHoleUnionFixtureTests: XCTestCase {
    private struct Case {
        let name: String
        let unit: Double
        let originLon: Double
        let originLat: Double
        let unionArea: Double
        var outer: [Double]?
        var holes: [[Double]] = []

        func toGeo(_ flat: [Double]) -> [GeoPointProtocol] {
            stride(from: 0, to: flat.count, by: 2).map { i in
                GeoPoint(latitude: originLat + flat[i + 1] * unit, longitude: originLon + flat[i] * unit)
            }
        }

        /// Planar area in grid units².
        func areaInUnits(_ ring: [GeoPointProtocol]) -> Double {
            var a = 0.0
            for i in ring.indices {
                let p = ring[i]
                let q = ring[(i + 1) % ring.count]
                let px = (p.longitude - originLon) / unit, py = (p.latitude - originLat) / unit
                let qx = (q.longitude - originLon) / unit, qy = (q.latitude - originLat) / unit
                a += px * qy - qx * py
            }
            return a / 2
        }
    }

    private func readCases() throws -> [Case] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "polygon-hole-union-fixture", withExtension: "txt"),
            "polygon-hole-union-fixture.txt is not in the test bundle"
        )
        var cases: [Case] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let numbers = { parts[1].split(separator: ",").map { Double($0)! } }
            switch parts[0] {
            case "case":
                cases.append(Case(
                    name: parts[1],
                    unit: Double(parts[2])!,
                    originLon: Double(parts[3])!,
                    originLat: Double(parts[4])!,
                    unionArea: Double(parts[5])!
                ))
            case "outer":
                cases[cases.count - 1].outer = numbers()
            case "hole":
                cases[cases.count - 1].holes.append(numbers())
            default:
                break
            }
        }
        return cases
    }

    func testUnionKeepsTheAreaOfTheUnion() throws {
        let cases = try readCases()
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for c in cases {
            let holes = c.holes.map { c.toGeo($0) }
            let result: [[GeoPointProtocol]]
            if let outer = c.outer {
                let state = PolygonState(points: c.toGeo(outer), holes: holes)
                let unioned = state.unionHoles()
                XCTAssertEqual(unioned.points.count, state.points.count, "\(c.name): the outline is left alone")
                result = unioned.holes
            } else {
                // nil: the union left the holes as they were.
                result = unionHoleRings(holes)?.map { $0.map { $0 as GeoPointProtocol } } ?? holes
            }
            let area = result.reduce(0.0) { $0 + abs(c.areaInUnits($1)) }
            XCTAssertEqual(
                area, c.unionArea, accuracy: 1e-6 * c.unionArea,
                "\(c.name): \(result.count) rings from \(holes.count)"
            )
            XCTAssertTrue(result.allSatisfy { c.areaInUnits($0) < 0 }, "\(c.name): holes come back clockwise")
        }
    }
}
