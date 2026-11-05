import Foundation

/// A hierarchical lat/lng grid over the markers, held as one sorted array of Int64.
///
/// Replaced the hex-cell registry, since removed, on the paths that run per
/// tile. That index was built at a fixed zoom of 20, which puts a cell at about
/// 12 cm — street trees are metres apart, so every marker landed in its own
/// cell and the index grouped nothing, while costing a HexCell and a String id
/// per marker plus a kd-tree node each. On Tokyo's 144,183 street trees, building it on Android
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
/// ## Changes are applied, not rebuilt
///
/// The first version threw the index away on every change, so a query after
/// any change paid the full build. An app that swaps a few hundred markers on
/// every pan paid it on every tap and every tile; on Android's Pixel 5a that
/// was 83 ms at 60,000 markers and 212 ms at 144,000 after 300 swaps, and a
/// drag paid it every frame.
///
/// Now a marker that arrives takes the next slot and its entry waits in
/// `pending`; the next query sorts only those and merges them into `packed` in
/// one linear pass. A marker that leaves only empties its slot — queries skip
/// empty slots, and the next merge drops their entries. Only when half the
/// slots are empty, or the index lost track of a marker, does it rebuild from
/// the manager's collection.
///
/// Finding a leaving marker's entry needs no map. Its entry is in the run of
/// the cell its position falls in, found by binary search and matched by
/// identity. The exception is a marker whose position was changed in place
/// after it was filed — a drag does that — and for that one the slots are
/// scanned, which is still far less than a rebuild.
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

    /// Slots the index can hand out before it has to rebuild to renumber them.
    private static var maxSlots: Int { 1 << 24 }

    /// Below this many empty slots a rebuild is never worth it. Above it, the
    /// index rebuilds once half its slots are empty: the dead entries cost a
    /// skip on every query, and the snapshot holds a slot for each.
    private static var rebuildMinSlots: Int { 4096 }

    private let source: () -> [MarkerEntity<ActualMarker>]
    /// Slot -> marker. A marker that left leaves a nil.
    private var snapshot: [MarkerEntity<ActualMarker>?] = []
    /// Sorted `(mortonKey << indexBits) | slot`.
    private var packed: [Int64] = []
    /// Entries for markers that arrived since the last merge, unsorted.
    private var pending: [Int64] = []
    /// Slots emptied by markers that left.
    private var emptySlots = 0
    private var dirty = true

    init(source: @escaping () -> [MarkerEntity<ActualMarker>]) {
        self.source = source
    }

    /// Whether the index currently holds a built snapshot.
    var isBuilt: Bool { !dirty }

    /// Roughly what the index costs: two words a marker, key and reference.
    func estimatedBytes() -> Int64 {
        Int64(packed.count) * 8 + Int64(snapshot.count) * 8 + Int64(pending.count) * 8
    }

    /// Marks the index stale. The rebuild happens on the next query.
    func invalidate() {
        dirty = true
    }

    /// Files a marker that was not in the index.
    func add(_ entity: MarkerEntity<ActualMarker>) {
        // Until the first build, or while a rebuild is due, the rebuild reads the
        // manager's collection and will see this marker there.
        if dirty { return }
        if snapshot.count == Self.maxSlots {
            dirty = true
            return
        }
        let slot = snapshot.count
        snapshot.append(entity)
        pending.append((MarkerGrid.mortonKey(for: entity.state.position) << Self.indexBits) | Int64(slot))
    }

    /// Forgets a marker.
    func remove(_ entity: MarkerEntity<ActualMarker>) {
        if dirty { return }
        guard let slot = locate(entity) else {
            // Not where it should be: the index lost track of it somewhere, so
            // stop trusting it rather than return a marker that has gone.
            dirty = true
            return
        }
        snapshot[slot] = nil
        emptySlots += 1
    }

    /// `previous` is replaced by `entity` under the same id — the same object
    /// after a change, or a new one.
    ///
    /// Most updates leave the marker in its cell: an icon or a flag changed.
    /// Then only the reference in its slot is swapped, and nothing waits for a
    /// merge.
    func replace(_ previous: MarkerEntity<ActualMarker>, with entity: MarkerEntity<ActualMarker>) {
        if dirty { return }
        if let slot = locate(previous, inCell: MarkerGrid.mortonKey(for: entity.state.position)) {
            snapshot[slot] = entity
            return
        }
        remove(previous)
        add(entity)
    }

    /// The slot holding `entity`, if any.
    private func locate(_ entity: MarkerEntity<ActualMarker>) -> Int? {
        if let slot = locate(entity, inCell: MarkerGrid.mortonKey(for: entity.state.position)) {
            return slot
        }
        // Its position changed in place since it was filed, so its entry is in
        // some other cell's run. Scan the slots.
        return snapshot.firstIndex { $0 === entity }
    }

    /// The slot holding `entity` if it was filed under bottom-level `key`.
    private func locate(_ entity: MarkerEntity<ActualMarker>, inCell key: Int64) -> Int? {
        for entry in pending where entry >> Self.indexBits == key {
            let slot = Int(entry & Self.indexMask)
            if snapshot[slot] === entity { return slot }
        }
        let limit = (key + 1) << Self.indexBits
        var at = lowerBound(key << Self.indexBits)
        while at < packed.count, packed[at] < limit {
            let slot = Int(packed[at] & Self.indexMask)
            if snapshot[slot] === entity { return slot }
            at += 1
        }
        return nil
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
                // The run's last live entry. No containment test anywhere: that
                // is the whole point, and it is also why this is cheaper than
                // the version that scanned every border cell. A marker that
                // left empties its slot without moving the entries, so step
                // back over those.
                var last = at
                while last + 1 < packed.count && packed[last + 1] < limit { last += 1 }
                while last >= at {
                    if let entity = snapshot[Int(packed[last] & Self.indexMask)] {
                        found.append(entity)
                        break
                    }
                    last -= 1
                }
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
            if let entity = snapshot[Int(packed[at] & Self.indexMask)] { body(entity) }
            at += 1
        }
    }

    private func rebuildIfNeeded() {
        if !dirty, emptySlots > Self.rebuildMinSlots, emptySlots * 2 > snapshot.count { dirty = true }
        if dirty {
            rebuild()
        } else if !pending.isEmpty {
            merge()
        }
    }

    private func rebuild() {
        let entities = source()
        var keys = [Int64]()
        keys.reserveCapacity(entities.count)
        for (at, entity) in entities.enumerated() {
            keys.append((MarkerGrid.mortonKey(for: entity.state.position) << Self.indexBits) | Int64(at))
        }
        keys.sort()
        snapshot = entities
        packed = keys
        pending = []
        emptySlots = 0
        dirty = false
    }

    /// Folds the markers that arrived into `packed`: sort those alone, then one
    /// pass over both sorted runs. Entries whose slot was emptied are dropped on
    /// the way, from either side.
    private func merge() {
        pending.sort()
        var merged: [Int64] = []
        merged.reserveCapacity(packed.count + pending.count)
        var i = 0
        var j = 0
        while i < packed.count || j < pending.count {
            let takeOld = j >= pending.count || (i < packed.count && packed[i] < pending[j])
            let entry: Int64
            if takeOld {
                entry = packed[i]
                i += 1
            } else {
                entry = pending[j]
                j += 1
            }
            if snapshot[Int(entry & Self.indexMask)] != nil { merged.append(entry) }
        }
        packed = merged
        pending.removeAll(keepingCapacity: true)
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
