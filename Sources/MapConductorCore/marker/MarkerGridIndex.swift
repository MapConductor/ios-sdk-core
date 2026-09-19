import Foundation

/// A uniform lat/lng grid over the markers, held as one sorted array of Int64.
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
/// objects, no hashing, no strings. A bounds query walks the cells the box
/// covers and binary-searches each one's run.
///
/// Not synchronised. `MarkerManager` holds its lock across every call, and
/// taking a second one here would only add cost to a path that is already
/// serialised.
///
/// The Android and web SDKs index the same way, with the same cell size.
final class MarkerGridIndex<ActualMarker> {
    /// About 450 m at Tokyo's latitude.
    ///
    /// Chosen by measurement rather than by round number: on 144k markers a
    /// tile-sized query took 0.06 ms here, 0.03 ms at 0.001 degrees and 2.31 ms
    /// at 0.02 degrees — the last no better than scanning, because a cell that
    /// size returns five times the markers a tile needs. Finer wins on dense
    /// data and loses on sparse, where a tile spans more empty cells than it
    /// saves.
    private static var cellDegrees: Double { 0.005 }

    /// Past this many cells, scan every marker instead.
    ///
    /// A query covering most of the world touches more empty cells than there
    /// are markers. Measured on the same 144k: a box over all of Tokyo costs
    /// 2.27 ms through the grid and 1.98 ms scanning, so the index stops paying
    /// for itself well before the pathological case.
    private static var maxCellsPerQuery: Int64 { 4096 }

    /// Roughly 45 km of rings before giving up and scanning.
    private static var maxNearestRings: Int64 { 100 }

    /// Columns around the globe: the wrap the ring and box walks fold on.
    private static var lonCells: Int64 { Int64(360.0 / cellDegrees) }
    private static var minLonCell: Int64 { -lonCells / 2 }

    private static func wrapLon(_ lonCell: Int64) -> Int64 {
        let span = lonCells
        return minLonCell + ((lonCell - minLonCell) % span + span) % span
    }

    /// 24 bits of position, enough for 16.7M markers, under the cell key.
    /// 間引きクエリが index を使う上限のセル数。これを超える箱は、セルを
    /// 歩くより全件を走査したほうが安い。android の
    /// `MAX_CELLS_PER_THINNED_QUERY` と同じ値。
    private static var maxCellsPerThinnedQuery: Int64 { 1 << 18 }

    private static var indexBits: Int64 { 24 }
    private static var indexMask: Int64 { (1 << 24) - 1 }

    private let source: () -> [MarkerEntity<ActualMarker>]
    private var snapshot: [MarkerEntity<ActualMarker>] = []
    /// Sorted `(cellKey << indexBits) | position-in-snapshot`.
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

        let latFrom = Self.cell(southWest.latitude)
        let latTo = Self.cell(northEast.latitude)
        let lonFrom = Self.cell(southWest.longitude)
        let lonTo = Self.cell(northEast.longitude)

        // A box crossing the antimeridian has its east corner west of its west
        // one. Walking to the unwrapped end and folding each column back onto
        // the globe covers both halves without a second loop — and without the
        // `lonFrom...lonTo` that traps on a reversed range.
        let lonEnd = northEast.longitude < southWest.longitude ? lonTo + Self.lonCells : lonTo

        if (latTo - latFrom + 1) * (lonEnd - lonFrom + 1) > Self.maxCellsPerQuery {
            return source().filter { bounds.contains(point: $0.state.position) }
        }

        rebuildIfNeeded()
        var found: [MarkerEntity<ActualMarker>] = []
        for latCell in latFrom...latTo {
            for lonCell in lonFrom...lonEnd {
                forEach(inCell: Self.cellKey(latCell, Self.wrapLon(lonCell))) { entity in
                    if bounds.contains(point: entity.state.position) { found.append(entity) }
                }
            }
        }
        return found
    }

    /// The markers in `bounds`, at most one per cell.
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
    /// A cell wholly inside the box needs no containment test, and the last
    /// entry of its run can be taken without looking at the rest.
    ///
    /// Returns nil when the index cannot help: cells coarser than the caller's
    /// separation would thin more than it asked for, and a box spanning more
    /// cells than `maxCellsPerThinnedQuery` is cheaper to scan.
    ///
    /// Mirrors `MarkerGridIndex.inBoundsThinned` in android-sdk.
    func inBoundsThinned(
        _ bounds: GeoRectBounds,
        minSeparationDegrees: Double
    ) -> [MarkerEntity<ActualMarker>]? {
        if minSeparationDegrees < Self.cellDegrees { return nil }
        guard let southWest = bounds.southWest, let northEast = bounds.northEast else { return nil }

        let latFrom = Self.cell(southWest.latitude)
        let latTo = Self.cell(northEast.latitude)
        let lonFrom = Self.cell(southWest.longitude)
        let lonTo = Self.cell(northEast.longitude)
        // As in `inBounds`: a box crossing the antimeridian has its east corner
        // west of its west one, so walk to the unwrapped end and fold back.
        let lonEnd = northEast.longitude < southWest.longitude ? lonTo + Self.lonCells : lonTo

        if (latTo - latFrom + 1) * (lonEnd - lonFrom + 1) > Self.maxCellsPerThinnedQuery { return nil }

        rebuildIfNeeded()
        var found: [MarkerEntity<ActualMarker>] = []
        for latCell in latFrom...latTo {
            let latInside = latCell > latFrom && latCell < latTo
            for lonCell in lonFrom...lonEnd {
                let key = Self.cellKey(latCell, Self.wrapLon(lonCell))
                let at = lowerBound(key << Self.indexBits)
                if at >= packed.count { continue }
                let limit = (key + 1) << Self.indexBits
                if packed[at] >= limit { continue }

                if latInside && lonCell > lonFrom && lonCell < lonEnd {
                    var last = at
                    while last + 1 < packed.count && packed[last + 1] < limit { last += 1 }
                    found.append(snapshot[Int(packed[last] & Self.indexMask)])
                    continue
                }
                // On the border the cell straddles the box, so the last entry
                // inside it is not necessarily the last entry of the run.
                var winner: MarkerEntity<ActualMarker>?
                var cursor = at
                while cursor < packed.count && packed[cursor] < limit {
                    let entity = snapshot[Int(packed[cursor] & Self.indexMask)]
                    if bounds.contains(point: entity.state.position) { winner = entity }
                    cursor += 1
                }
                if let winner { found.append(winner) }
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

        let centreLat = Self.cell(position.latitude)
        let centreLon = Self.cell(position.longitude)

        var best: MarkerEntity<ActualMarker>?
        var bestDistance = Double.greatestFiniteMagnitude
        var ring: Int64 = 0

        while ring <= Self.maxNearestRings {
            forEach(inRing: ring, centreLat: centreLat, centreLon: centreLon) { entity in
                let distance = Self.squaredDegrees(entity, position)
                if distance < bestDistance {
                    bestDistance = distance
                    best = entity
                }
            }
            let reach = Double(ring) * Self.cellDegrees
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
        _ body: (MarkerEntity<ActualMarker>) -> Void
    ) {
        if ring == 0 {
            forEach(inCell: Self.cellKey(centreLat, centreLon), body)
            return
        }
        for offset in -ring...ring {
            forEach(inCell: Self.cellKey(centreLat - ring, Self.wrapLon(centreLon + offset)), body)
            forEach(inCell: Self.cellKey(centreLat + ring, Self.wrapLon(centreLon + offset)), body)
        }
        if ring > 1 {
            for offset in (-ring + 1)...(ring - 1) {
                forEach(inCell: Self.cellKey(centreLat + offset, Self.wrapLon(centreLon - ring)), body)
                forEach(inCell: Self.cellKey(centreLat + offset, Self.wrapLon(centreLon + ring)), body)
            }
        }
    }

    private func forEach(inCell key: Int64, _ body: (MarkerEntity<ActualMarker>) -> Void) {
        var at = lowerBound(key << Self.indexBits)
        let limit = (key + 1) << Self.indexBits
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
            keys.append((Self.cellKey(for: entity.state.position) << Self.indexBits) | Int64(at))
        }
        keys.sort()
        snapshot = entities
        packed = keys
        dirty = false
    }

    private static func cell(_ degrees: Double) -> Int64 {
        Int64((degrees / cellDegrees).rounded(.down))
    }

    private static func cellKey(for position: GeoPointProtocol) -> Int64 {
        cellKey(cell(position.latitude), cell(position.longitude))
    }

    /// Offsets keep the keys positive, so their ordering matches the numeric
    /// ordering the sort and the binary search depend on.
    private static func cellKey(_ latCell: Int64, _ lonCell: Int64) -> Int64 {
        ((latCell + 262_144) << 20) | (lonCell + 524_288)
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
