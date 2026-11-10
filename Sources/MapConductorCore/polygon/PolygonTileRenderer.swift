import CoreGraphics
import Foundation
import UIKit

/// One polygon as the tile renderer takes it: plain values, read from a
/// ``PolygonState`` once, so drawing never touches the state again.
struct PolygonTileShape {
    /// Rings as flat `[lat, lng, lat, lng, ...]`; the first is the outline, the rest holes.
    var rings: [[Double]]
    var fill: CGColor?
    var stroke: CGColor?
    var strokeWidth: Double

    init(rings: [[Double]], fill: CGColor?, stroke: CGColor?, strokeWidth: Double) {
        self.rings = rings
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }

    init(state: PolygonState) {
        let flat: ([GeoPointProtocol]) -> [Double] = { ring in
            var out = [Double]()
            out.reserveCapacity(ring.count * 2)
            for p in ring {
                out.append(p.latitude)
                out.append(p.longitude)
            }
            return out
        }
        var rings = [flat(state.points)]
        for hole in state.holes { rings.append(flat(hole)) }
        self.init(
            rings: rings,
            fill: state.fillColor.cgColor,
            stroke: state.strokeColor.cgColor,
            strokeWidth: state.strokeWidth
        )
    }
}

/// The polygon tile renderer: ``ShapeTileRenderer`` holding polygons.
/// The name stays for the tests and for symmetry with android-sdk / js-sdk-core.
typealias PolygonTileRenderer = ShapeTileRenderer

extension ShapeTileRenderer {
    /// Replaces every polygon. Draw order is the order of `shapes`.
    func setPolygons(_ shapes: [PolygonTileShape]) {
        setShapes(shapes.map { Shape($0) })
    }

    /// Replaces the polygons at the given positions (as passed to ``setPolygons(_:)``);
    /// a nil shape empties the slot (a polygon taken out of the tiles).
    func update(_ changes: [(index: Int, shape: PolygonTileShape?)]) {
        update(changes.map { (index: $0.index, shape: $0.shape.flatMap { Shape($0) }) })
    }
}
