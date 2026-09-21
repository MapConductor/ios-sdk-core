import Foundation

/// The cell arithmetic behind `MarkerGridIndex`, with no marker in sight.
///
/// Kept apart from the index for two reasons. The index is generic over the
/// marker type, and Swift will not let a generic type hold a stored static, so
/// every constant here would have had to be a computed property returning a
/// literal. More to the point, none of this depends on what a marker is: it is
/// a way of naming a patch of the globe, and the conformance fixtures the three
/// SDKs share test it on its own.
///
/// ## The scheme
///
/// The world starts as **two square cells** — the western and eastern halves,
/// 180 degrees on a side — and each is halved in latitude and in longitude,
/// repeatedly. The key records the half chosen each time, latitude bit above
/// longitude bit, under the bit that says which hemisphere it started in. That
/// makes **every prefix of a key a cell:** dropping the low `2n` bits names the
/// cell `n` levels up, and all of its children share the prefix, so they form
/// one run in a sorted array. A query picks the level that suits its box
/// instead of paying the finest one.
///
/// ## Why two root cells and not one
///
/// One root cell covering the whole globe is what cordova-plugin-googlemaps'
/// `geomodel.js` uses, and it is what this started as. It makes every cell
/// **twice as wide as it is tall**, because the same number of divisions covers
/// 360 degrees of longitude and 180 of latitude.
///
/// That costs real time. A query asks for cells no wider than some separation;
/// with a 2:1 cell, satisfying the width over-resolves the height by a factor
/// of two, so the query walks twice the cells and returns twice the markers it
/// asked for. Measured on Tokyo's 144,183 street trees at zoom 11, a tile
/// returned 9,715 markers of which the caller kept 2,156, and the work that
/// scales with that count — the walk, positioning each marker, and grouping
/// them — was 44 ms of the tile's 52 ms.
///
/// Splitting the root into two square halves removes the factor of two. The
/// string form keeps its shape: a hemisphere digit followed by geocell
/// characters over `0123456789abcdef`, one per 4x4 subdivision, and a prefix is
/// still a cell. What it is no longer is byte-identical to `geomodel.js`.
///
/// The three SDKs hold the key as a `Long`, an `Int64` and a `number`; the
/// string is what their conformance fixtures compare, because it does not
/// depend on that choice.
enum MarkerGrid {

    /// Levels of 2x2 subdivision below the two root cells.
    ///
    /// 18 is the largest depth that still leaves room for the position: the key
    /// is `2 * 18 + 1 = 37` bits — the extra one is the hemisphere — and the
    /// position below it is 24, which is 61 of the 63 an `Int64` has. It is
    /// also an even number of levels, so the string form packs into whole
    /// 4-bit characters with no ragged tail.
    ///
    /// A cell at the bottom is 0.000687 degrees on a side, about 76 m at the
    /// equator. The flat grid this replaced was 0.005 degrees.
    static var gridDepth: Int64 { 18 }

    /// Roughly how many cells across a box a query aims to walk.
    ///
    /// The level is chosen so the box covers about this many cells per axis,
    /// which bounds the walk at `cellsAcross^2` lookups no matter how large the
    /// box is. That is what removed the old "past 4096 cells, scan everything
    /// instead" escape: a world-sized box now asks a coarse level and reads
    /// roughly the markers it would have scanned anyway, without the cliff.
    static var cellsAcross: Double { 32 }

    /// The most cells a query walks along either axis.
    ///
    /// Only bites on a box so flat or so narrow that its area says nothing
    /// about how many cells it crosses.
    static var maxCellsPerAxis: Double { 64 }

    // MARK: - Cells

    /// Degrees a cell spans, on either axis. Cells are square.
    static func cellSize(_ level: Int64) -> Double { 180.0 / Double(Int64(1) << level) }

    /// Rows of cells from pole to pole at `level`.
    static func rows(_ level: Int64) -> Int64 { Int64(1) << level }

    /// Columns of cells around the globe at `level`. Twice the rows, because
    /// the world is twice as wide as it is tall and the cells are square.
    static func columns(_ level: Int64) -> Int64 { Int64(1) << (level + 1) }

    /// The coarsest level whose cells are no wider than `separation`, or nil if
    /// even the bottom level is coarser than that.
    ///
    /// Counted up rather than solved with a logarithm, because the three SDKs
    /// have to agree on the answer and they do not have the same `log2`. Java
    /// has none at all — Kotlin computes `ln(x) / ln(2)`, which is off by an ulp
    /// where the true answer is a whole number, and the `ceil` above it turns
    /// that ulp into a different level. Halving a double and comparing it is
    /// exact on all three.
    static func level(forSeparation separation: Double) -> Int64? {
        guard separation > 0 else { return nil }
        var level: Int64 = 0
        while level <= gridDepth {
            if cellSize(level) <= separation { return level }
            level += 1
        }
        return nil
    }

    /// The level a bounds query walks, chosen so the box covers about
    /// `cellsAcross` squared cells.
    ///
    /// Counted up for the same reason as `level(forSeparation:)`.
    ///
    /// The area rule alone is not enough. A box with no height — a click box
    /// flattened by a degenerate projection, a bounds built from two points on
    /// the same parallel — has an area of nothing, which asks for the bottom
    /// level, which is a quarter of a million columns to walk. `maxCellsPerAxis`
    /// steps back up until neither axis is absurd. On a box of ordinary shape
    /// the area rule binds first and this does nothing.
    static func queryLevel(latSpan: Double, lonSpan: Double) -> Int64 {
        let area = max(lonSpan, 1e-12) * max(latSpan, 1e-12)
        // cells at a level = area / cellSize^2, and cellSize = 180 / 2^level
        let budget = cellsAcross * cellsAcross * 180.0 * 180.0
        var level: Int64 = 0
        while level < gridDepth, area * Double(Int64(1) << (2 * (level + 1))) <= budget {
            level += 1
        }
        while level > 0,
              lonSpan / cellSize(level) > maxCellsPerAxis
                || latSpan / cellSize(level) > maxCellsPerAxis {
            level -= 1
        }
        return level
    }

    /// How far east the box runs, from its west edge to its east one.
    ///
    /// A box crossing the antimeridian has its east corner west of its west
    /// one, and a padded box can run past ±180 outright. Normalising to a
    /// single eastward span removes both cases: everything downstream walks
    /// east from the west edge for this many degrees, and never compares two
    /// longitudes.
    static func eastwardSpan(from west: Double, to east: Double) -> Double {
        if east - west >= 360.0 { return 360.0 }
        return (((east - west).truncatingRemainder(dividingBy: 360.0)) + 360.0)
            .truncatingRemainder(dividingBy: 360.0)
    }

    /// The columns a box covers: where to start, and how many to walk.
    ///
    /// The end column is taken from `west + span`, not from the east corner.
    /// Taking it from the corner cannot work once column indices fold: the
    /// column holding 180 and the column holding -180 are the same one, so a
    /// box from -180.2 to 179.8 starts and ends on the same column and the walk
    /// covers one column out of the level's many. Nothing errors; the query
    /// simply answers for a thin slice of the world.
    ///
    /// The old row-major key did not have this hazard, because it indexed on
    /// unwrapped column numbers that kept growing eastward. Folding is what
    /// makes a Morton key a fixed width, so the walk has to carry the span
    /// itself.
    static func columnWalk(
        from west: Double,
        spanning span: Double,
        level: Int64
    ) -> (start: Int64, count: Int64) {
        let total = columns(level)
        let start = Int64(((west + 180.0) / 360.0 * Double(total)).rounded(.down))
        let end = Int64(((west + span + 180.0) / 360.0 * Double(total)).rounded(.down))
        // A full turn ends on the column it started on; walking both would
        // return that column's markers twice.
        return (start, min(end - start + 1, total))
    }

    static func latCell(_ latitude: Double, level: Int64) -> Int64 {
        let count = rows(level)
        let at = Int64(((latitude + 90.0) / 180.0 * Double(count)).rounded(.down))
        return min(max(at, 0), count - 1)
    }

    static func lonCell(_ longitude: Double, level: Int64) -> Int64 {
        let count = columns(level)
        let at = Int64(((longitude + 180.0) / 360.0 * Double(count)).rounded(.down))
        return wrap(at, level: level)
    }

    static func wrap(_ lonCell: Int64, level: Int64) -> Int64 {
        let count = columns(level)
        return ((lonCell % count) + count) % count
    }

    static func mortonKey(for position: GeoPointProtocol) -> Int64 {
        morton(
            latCell(position.latitude, level: gridDepth),
            lonCell(position.longitude, level: gridDepth),
            level: gridDepth
        )
    }

    /// Interleaves the two indices, latitude in the odd bits, under the bit
    /// that says which root cell they are in.
    ///
    /// Longitude carries one bit more than latitude — twice as many columns as
    /// rows — and that top bit is the hemisphere. It sits above the interleaved
    /// pairs rather than inside them, so dropping the low two bits still names
    /// the parent cell.
    static func morton(_ latCell: Int64, _ lonCell: Int64, level: Int64) -> Int64 {
        let hemisphere = lonCell >> level
        let within = lonCell & ((Int64(1) << level) - 1)
        return (hemisphere << (2 * level)) | (spread(latCell) << 1) | spread(within)
    }

    /// Spreads a value's bits apart, leaving a zero between each pair.
    private static func spread(_ value: Int64) -> Int64 {
        var x = UInt64(bitPattern: value) & 0xFFFF_FFFF
        x = (x | (x << 16)) & 0x0000_FFFF_0000_FFFF
        x = (x | (x << 8)) & 0x00FF_00FF_00FF_00FF
        x = (x | (x << 4)) & 0x0F0F_0F0F_0F0F_0F0F
        x = (x | (x << 2)) & 0x3333_3333_3333_3333
        x = (x | (x << 1)) & 0x5555_5555_5555_5555
        return Int64(bitPattern: x)
    }

    /// The cell's name as a string: a hemisphere digit, then one character per
    /// 4x4 subdivision over `0123456789abcdef`.
    ///
    /// Each character after the first is two levels of this grid, so a string of
    /// `characters` names the cell at level `2 * (characters - 1)`. Not used by
    /// the index itself — the key is the same information, and faster — but it
    /// is the form the three SDKs' conformance fixtures compare, because it does
    /// not depend on how a platform stores an integer.
    static func geocell(latitude: Double, longitude: Double, characters: Int) -> String {
        let alphabet = Array("0123456789abcdef")
        let level = min(Int64(max(characters - 1, 0)) * 2, gridDepth)
        let key = morton(
            latCell(latitude, level: level),
            lonCell(longitude, level: level),
            level: level
        )
        var text = String(key >> (2 * level))
        var at = level * 2 - 4
        while at >= 0 {
            text.append(alphabet[Int((key >> at) & 0xF)])
            at -= 4
        }
        return text
    }
}
