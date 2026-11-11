import XCTest
@_spi(MapConductorDriver) @testable import MapConductorCore

final class ShapeGridIndexTests: XCTestCase {
    func testMixedShapeSizesMatchBruteForceAtEveryZoom() {
        var seed: UInt64 = 307
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let shapes: [ShapeTileRenderer.Shape?] = (0..<2000).map { i in
            if i % 17 == 0 { return nil }
            let latitude = -70 + random() * 140
            let longitude = -170 + random() * 340
            let radius = [10.0, 1000, 40_000, 300_000][i % 4]
            return ShapeTileRenderer.Shape(CircleTileShape(
                latitude: latitude, longitude: longitude, radiusMeters: radius,
                geodesic: true, fill: nil, stroke: nil, strokeWidth: 0
            ))
        }
        let index = ShapeTileRenderer.Index(shapes)
        for z in [0, 2, 4, 8, 12, 18] {
            for _ in 0..<30 {
                let x = random() * 1.2 - 0.1, y = random() * 1.2 - 0.1
                let size = 1 / Double(1 << z)
                let expected = shapes.indices.compactMap { i -> Int32? in
                    guard let p = shapes[i] else { return nil }
                    return p.minX <= x + size && p.maxX >= x && p.minY <= y + size && p.maxY >= y ? Int32(i) : nil
                }
                XCTAssertEqual(index.query(shapes, minX: x, minY: y, maxX: x + size, maxY: y + size), expected, "z=\(z)")
            }
        }
    }
}
