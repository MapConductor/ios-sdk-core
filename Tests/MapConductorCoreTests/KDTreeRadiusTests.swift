import CoreGraphics
import XCTest

@testable import MapConductorCore

/**
 The unordered radius search returns the same cells as the sorted one.

 It exists because sorting dominated bounds queries — 42 ms of a 64 ms query at
 20k markers — and bounds queries throw the distances away. Its traversal was
 written out separately, so this pins the two against each other rather than
 trusting that the pruning was copied correctly.
 */
final class KDTreeRadiusTests: XCTestCase {

    private func cells(_ count: Int) -> [HexCell] {
        var seed: UInt64 = 42
        return (0..<count).map { index in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = Double(seed >> 40) / 1000.0
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = Double(seed >> 40) / 1000.0
            return HexCell(
                coord: HexCoord(q: index, r: index),
                centerLatLng: GeoPoint(latitude: 0, longitude: 0),
                centerXY: CGPoint(x: x, y: y),
                id: "cell-\(index)"
            )
        }
    }

    func testUnorderedMatchesSorted() {
        let tree = KDTree(points: cells(2_000))

        // A spread of radii: one that excludes everything, several partial, and
        // one that takes the lot. A traversal bug that only shows at the
        // boundary would survive a single radius.
        for radius in [0.0, 1.0, 50.0, 500.0, 5_000.0, 20_000.0] {
            let query = CGPoint(x: 8_000, y: 8_000)
            let sorted = Set(tree.withinRadiusWithDistance(query: query, radius: radius).map { $0.cell.id })
            let unordered = Set(tree.withinRadius(query: query, radius: radius).map { $0.id })
            XCTAssertEqual(sorted, unordered, "radius \(radius): \(sorted.count) vs \(unordered.count)")
        }
    }
}
