import Foundation

/// A hierarchical lat/lng grid over the markers, held as one sorted array of Int64.
///
/// Replaces the hex-cell registry on the paths that run per tile. That index was
/// built at a fixed zoom of 20, which puts a cell at about 12 cm — street trees
/// are metres apart, so every marker landed in its own cell and the index
/// grouped nothing, while costing a HexCell and a String id per marker plus a
/// kd-tree node each. On Tokyo's 144,183 street trees, building it on Android
/// aborted the process; this builds in 41 ms and 1.15 MB there.
///
/// Each marker is one Int64: its cell key above its position in a snapshot, so
/// building the index is arithmetic and a sort of a contiguous buffer — no
/// objects, no hashing, no strings.
///
/// The key itself is a Morton code over a hierarchy of cells, described in
/// `MarkerGrid`. What it buys the index is that a cell at *any* level is one
/// contiguous run, so a query walks the level that suits its box rather than
/// the finest one — the first version had a single fixed cell size of 0.005
/// degrees, and a continent-wide box paid for it.
///
/// Not synchronised. `MarkerManager` holds its lock across every call, and
/// taking a second one here would only add cost to a path that is already
/// serialised.
///
/// The Android and web SDKs index the same way, to the same depth.
final class MarkerGridIndex<ActualMarker> {

    /// 24 bits of position, enough for 16.7M markers, under the cell key.
    private static var indexBits: Int64 { 24 }
    private static var indexMask: Int64 { (1 << 24) - 1 }

    /// Past this many cells, decline the thinned query.
    ///
    /// Thinning cannot choose its own level — the caller's separation fixes it —
    /// so this bound stays. Same value as android's
    /// `MAX_CELLS_PER_THINNED_QUERY`.
    private static var maxCellsPerThinnedQuery: Int64 { 1 << 18 }

    /// The level `nearest` walks its rings at, and the reach that buys.
    ///
    /// Level 15 is 0.0055 degrees on a side, matching the flat cell this index
    /// used to have, so 100 rings is about 45 km as before.
    private static var nearestLevel: Int64 { 15 }
    private static var maxNearestRings: Int64 { 100 }

    private let source: () -> [MarkerEntity<ActualMarker>]
    private var snapshot: [MarkerEntity<ActualMarker>] = []
    /// Sorted `(mortonKey << indexBits) | position-in-snapshot`.
    private var packed: [Int64] = []
    private var dirty = true

    init(source: @escaping () -> [MarkerEntity<ActualMarker>]) {
        self.source = source
    }

    /// Whether the index currently holds a built snapshot.
    var isBuilt: Bool { !dirty }

    /// Roughly what the index costs: two words a marker, key and reference.
    func estimatedBytes() -> Int64 { Int64(packed.count) * 8 + Int64(snapshot.count) * 8 }

    /// Marks the index stale. The rebuild happens on the next query.
    func invalidate() {
        dirty = true
    }

    /// Markers whose position falls inside `bounds`.
    func inBounds(_ bounds: GeoRectBounds) -> [MarkerEntity<ActualMarker>] {
        guard let southWest = bounds.southWest, let northEast = bounds.northEast else { return [] }

        // A box crossing the antimeridian has its east corner west of its west
        // one. Walking to the unwrapped end and folding each column back onto
        // the globe covers both halves without a second loop — and without the
        // `lonFrom...lonTo` that traps on a reversed range.
        let lonSpan = MarkerGrid.eastwardSpan(from: southWest.longitude, to: northEast.longitude)
        let level = MarkerGrid.queryLevel(
            latSpan: northEast.latitude - southWest.latitude,
            lonSpan: lonSpan
        )
        let latFrom = MarkerGrid.latCell(southWest.latitude, level: level)
        let latTo = MarkerGrid.latCell(northEast.latitude, level: level)
        if latTo < latFrom { return [] }
        let columns = MarkerGrid.columnWalk(from: southWest.longitude, spanning: lonSpan, level: level)

        rebuildIfNeeded()
        var found: [MarkerEntity<ActualMarker>] = []
        for latCell in latFrom...latTo {
            for step in 0..<columns.count {
                let key = MarkerGrid.morton(
                    latCell,
                    MarkerGrid.wrap(columns.start + step, level: level),
                    level: level
                )
                forEach(inCell: key, level: level) { entity in
                    if bounds.contains(point: entity.state.position) { found.append(entity) }
                }
            }
        }
        return found
    }

    /// One marker for each cell the bounds touch.
    ///
    /// The caller has said that markers closer together than
    /// `minSeparationDegrees` are interchangeable, so the index is free to hand
    /// back whichever of a cell's markers it likes. That is what lets it answer
    /// from its cells instead of reading every marker: at zoom 9 that is the
    /// roughly 5,000 cells holding Tokyo's street trees rather than all 144,183
    /// of them, and merely reading a position off an entity costs about
    /// 0.72 microseconds — looking at the full set is 100 ms before anything is
    /// done with it.
    ///
    /// The level comes from the separation: the coarsest one whose cells are no
    /// wider than the caller asked for.
    ///
    /// ## Why the winner cannot depend on the bounds
    ///
    /// A cell's representative is the **last entry of its run, always** — not
    /// the last entry that falls inside the bounds. The difference is what a
    /// map made of tiles looks like at the seams.
    ///
    /// Tiles are rendered one at a time, each asking for its own box grown by
    /// the icon overhang. A cell straddling the boundary is asked about twice,
    /// by two different boxes. Choose the winner from what is inside the box
    /// and the two tiles choose **different markers:** one marker gets its left
    /// half drawn on the left tile and nothing on the right, so the icon is cut
    /// down the seam with no error anywhere. Measured on Tokyo's street trees,
    /// 74 markers at zoom 9 and 84 at zoom 10 were drawn by one tile and not by
    /// its neighbour.
    ///
    /// Choosing without looking at the box removes the disagreement: a marker
    /// whose icon reaches the next tile is inside that tile's grown box too, so
    /// that tile asks about the same cell and gets the same answer.
    ///
    /// A returned marker may therefore lie just outside `bounds`, by less than
    /// one cell. The renderer clips it; what it must not do is filter the list
    /// back down to the box, because that would put the disagreement back.
    ///
    /// Returns nil when the index cannot help: a separation finer than the
    /// bottom level would thin more than it asked for, and a box spanning more
    /// cells than `maxCellsPerThinnedQuery` is cheaper to scan.
    ///
    /// Mirrors `MarkerGridIndex.inBoundsThinned` in android-sdk.
    func inBoundsThinned(
        _ bounds: GeoRectBounds,
        minSeparationDegrees: Double
    ) -> [MarkerEntity<ActualMarker>]? {
        guard let level = MarkerGrid.level(forSeparation: minSeparationDegrees) else { return nil }
        guard let southWest = bounds.southWest, let northEast = bounds.northEast else { return nil }

        let lonSpan = MarkerGrid.eastwardSpan(from: southWest.longitude, to: northEast.longitude)
        let latFrom = MarkerGrid.latCell(southWest.latitude, level: level)
        let latTo = MarkerGrid.latCell(northEast.latitude, level: level)
        if latTo < latFrom { return [] }
        let columns = MarkerGrid.columnWalk(from: southWest.longitude, spanning: lonSpan, level: level)

        if (latTo - latFrom + 1) * columns.count > Self.maxCellsPerThinnedQuery { return nil }

        rebuildIfNeeded()
        let shift = Self.indexBits + 2 * (MarkerGrid.gridDepth - level)
        var found: [MarkerEntity<ActualMarker>] = []
        for latCell in latFrom...latTo {
            for step in 0..<columns.count {
                let key = MarkerGrid.morton(
                    latCell,
                    MarkerGrid.wrap(columns.start + step, level: level),
                    level: level
                )
                let at = lowerBound(key << shift)
                if at >= packed.count { continue }
                let limit = (key + 1) << shift
                if packed[at] >= limit { continue }
                // The run's last entry. No containment test anywhere: that is
                // the whole point, and it is also why this is cheaper than the
                // version that scanned every border cell.
                var last = at
                while last + 1 < packed.count && packed[last + 1] < limit { last += 1 }
                found.append(snapshot[Int(packed[last] & Self.indexMask)])
            }
        }
        return found
    }

    /// The marker nearest `position`, by squared degrees.
    ///
    /// Rings of cells are searched outward from the one holding the point. The
    /// stopping rule is a distance, not a ring count: a ring is a square, so a
    /// hit in one of its corners sits about 1.4 cells further out than a hit on
    /// its edge, and stopping a fixed ring after the first hit returns the
    /// wrong marker. Having finished ring r, everything still unsearched is at
    /// least r cells away, so the search ends once that already exceeds the
    /// best distance found.
    func nearest(position: GeoPointProtocol) -> MarkerEntity<ActualMarker>? {
        rebuildIfNeeded()
        if packed.isEmpty { return nil }

        let level = Self.nearestLevel
        let centreLat = MarkerGrid.latCell(position.latitude, level: level)
        let centreLon = MarkerGrid.lonCell(position.longitude, level: level)

        var best: MarkerEntity<ActualMarker>?
        var bestDistance = Double.greatestFiniteMagnitude
        var ring: Int64 = 0

        while ring <= Self.maxNearestRings {
            forEach(inRing: ring, centreLat: centreLat, centreLon: centreLon, level: level) { entity in
                let distance = Self.squaredDegrees(entity, position)
                if distance < bestDistance {
                    bestDistance = distance
                    best = entity
                }
            }
            // A ring is a square: the nearest unsearched point is `ring` cells
            // away on the shorter axis, which is latitude.
            let reach = Double(ring) * MarkerGrid.cellSize(level)
            if best != nil, reach * reach >= bestDistance { break }
            ring += 1
        }

        // Nothing within the rings searched: the set is sparse enough here that
        // scanning is cheaper than widening further.
        return best ?? source().min { Self.squaredDegrees($0, position) < Self.squaredDegrees($1, position) }
    }

    private static func squaredDegrees(
        _ entity: MarkerEntity<ActualMarker>,
        _ position: GeoPointProtocol
    ) -> Double {
        let deltaLat = entity.state.position.latitude - position.latitude
        let deltaLon = entity.state.position.longitude - position.longitude
        return deltaLat * deltaLat + deltaLon * deltaLon
    }

    private func forEach(
        inRing ring: Int64,
        centreLat: Int64,
        centreLon: Int64,
        level: Int64,
        _ body: (MarkerEntity<ActualMarker>) -> Void
    ) {
        func visit(_ latCell: Int64, _ lonCell: Int64) {
            let rows = MarkerGrid.rows(level)
            if latCell < 0 || latCell >= rows { return }
            forEach(inCell: MarkerGrid.morton(latCell, MarkerGrid.wrap(lonCell, level: level), level: level),
                    level: level, body)
        }
        if ring == 0 {
            visit(centreLat, centreLon)
            return
        }
        for offset in -ring...ring {
            visit(centreLat - ring, centreLon + offset)
            visit(centreLat + ring, centreLon + offset)
        }
        if ring > 1 {
            for offset in (-ring + 1)...(ring - 1) {
                visit(centreLat + offset, centreLon - ring)
                visit(centreLat + offset, centreLon + ring)
            }
        }
    }

    /// Walks one cell at `level`. Its markers are the run whose keys share the
    /// cell's prefix, which is what interleaving the bits bought.
    private func forEach(
        inCell key: Int64,
        level: Int64,
        _ body: (MarkerEntity<ActualMarker>) -> Void
    ) {
        let shift = Self.indexBits + 2 * (MarkerGrid.gridDepth - level)
        var at = lowerBound(key << shift)
        let limit = (key + 1) << shift
        while at < packed.count, packed[at] < limit {
            body(snapshot[Int(packed[at] & Self.indexMask)])
            at += 1
        }
    }

    private func rebuildIfNeeded() {
        guard dirty else { return }
        let entities = source()
        var keys = [Int64]()
        keys.reserveCapacity(entities.count)
        for (at, entity) in entities.enumerated() {
            keys.append((MarkerGrid.mortonKey(for: entity.state.position) << Self.indexBits) | Int64(at))
        }
        keys.sort()
        snapshot = entities
        packed = keys
        dirty = false
    }

    private func lowerBound(_ target: Int64) -> Int {
        var low = 0
        var high = packed.count
        while low < high {
            let mid = (low + high) / 2
            if packed[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
