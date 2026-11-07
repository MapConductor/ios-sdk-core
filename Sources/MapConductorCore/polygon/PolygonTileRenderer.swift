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

/**
 Draws a set of polygons into raster tiles.

 The native counterpart of the "Polygon tiles" section of js-sdk-core's
 `tile-sw.js`, and drawn the same way:

 - Every polygon is kept in Web Mercator coordinates in [0, 1], its outline
   wound one way and its holes the other, so a nonzero ("winding") fill leaves
   out the union of the holes without computing it.
 - Polygons are found through a grid of their bounding boxes (one z12 tile per
   cell); one covering too many cells is kept in a list every query checks.
 - Each zoom gets its own simplified copy of a polygon, built the first time a
   tile at that zoom needs it: vertices snapped to that zoom's pixel grid,
   repeats dropped, Douglas-Peucker at half a pixel, and a polygon smaller than
   a pixel drawn as one pixel. A few zooms are kept.
 - The outline only is stroked, and not at all for a polygon under 4 px on
   screen. Tiles query with a margin of the widest outline.
 - Draw order is the order given, which the caller sorted by zIndex.

 Taps never see any of this; they are resolved against the original shapes.

 Tiles are cached without a version. A change (``update(_:)``) drops only the
 cached tiles the changed polygons overlap, so the map, which must ask again
 because the URL's version changed, gets every other tile from the cache.
 */
final class PolygonTileRenderer: TileProvider {
    /// Cells of the polygon index, in Web Mercator units: one z12 tile.
    static let cellSize = 1.0 / 4096.0
    /// A polygon covering more cells than this is kept in a list every query checks.
    static let maxCells = 256
    /// Simplified copies kept, most recent zooms first.
    static let zoomsKept = 4
    static let dpTolerancePx = 0.5
    /// Below this size on screen a polygon's outline is left out: a 1 px line
    /// round a 3 px parcel is the whole parcel, and a city of them zoomed out
    /// turns into the outline colour.
    static let minOutlinedPx = 4.0

    /// Logical tile size (points), the grid the map asks tiles on.
    let tileSize: Int
    /// Pixels per point in the drawn tile.
    let pixelRatio: Int

    // MARK: Polygons

    final class Polygon {
        /// Mercator rings, flat `[x, y, ...]`; outline positive area, holes negative.
        let rings: [[Double]]
        let minX: Double, minY: Double, maxX: Double, maxY: Double
        let fill: CGColor?
        let stroke: CGColor?
        let strokeWidth: Double

        init?(_ shape: PolygonTileShape) {
            var rings: [[Double]] = []
            for (r, latLngs) in shape.rings.enumerated() {
                var ring = PolygonTileRenderer.toMercator(latLngs)
                if ring.count < 6 {
                    if r == 0 { return nil }
                    continue
                }
                let area = PolygonTileRenderer.signedArea(ring)
                if (r == 0 && area < 0) || (r > 0 && area > 0) { ring = PolygonTileRenderer.reversed(ring) }
                rings.append(ring)
            }
            let outer = rings[0]
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            var i = 0
            while i < outer.count {
                minX = Swift.min(minX, outer[i]); maxX = Swift.max(maxX, outer[i])
                minY = Swift.min(minY, outer[i + 1]); maxY = Swift.max(maxY, outer[i + 1])
                i += 2
            }
            self.rings = rings
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
            self.fill = PolygonTileRenderer.isVisible(shape.fill) ? shape.fill : nil
            self.stroke = shape.strokeWidth > 0 && PolygonTileRenderer.isVisible(shape.stroke) ? shape.stroke : nil
            self.strokeWidth = shape.strokeWidth
        }

        func sameBox(_ other: Polygon) -> Bool {
            minX == other.minX && minY == other.minY && maxX == other.maxX && maxY == other.maxY
        }
    }

    struct Index {
        var cells: [Int64: [Int32]] = [:]
        var large: [Int32] = []

        init(_ polygons: [Polygon?]) {
            for (i, p) in polygons.enumerated() {
                guard let p else { continue }
                let cx0 = Int64(floor(p.minX / PolygonTileRenderer.cellSize))
                let cx1 = Int64(floor(p.maxX / PolygonTileRenderer.cellSize))
                let cy0 = Int64(floor(p.minY / PolygonTileRenderer.cellSize))
                let cy1 = Int64(floor(p.maxY / PolygonTileRenderer.cellSize))
                if (cx1 - cx0 + 1) * (cy1 - cy0 + 1) > Int64(PolygonTileRenderer.maxCells) {
                    large.append(Int32(i))
                    continue
                }
                for cx in cx0...cx1 {
                    for cy in cy0...cy1 {
                        cells[cx &* 1_048_576 &+ cy, default: []].append(Int32(i))
                    }
                }
            }
        }
    }

    /// What is drawn; replaced as a whole (copy-on-write) so a tile being drawn
    /// keeps the version it started with.
    private struct Data {
        var polygons: [Polygon?] = []
        var index = Index([])
        var maxStrokePx = 0.0
        /// Bumped by every change, so a tile drawn before it is not cached after it.
        var generation = 0
    }

    /// A polygon as drawn at one zoom.
    enum Simplified {
        case none
        /// Under a pixel: one pixel at this world-pixel position.
        case dot(Double, Double)
        /// World-pixel rings, the first the outline.
        case rings([[Double]], outlined: Bool)
    }

    private final class ZoomCache {
        var entries: [Simplified?]
        init(count: Int) { entries = Array(repeating: nil, count: count) }
    }

    private struct TileKey: Hashable {
        let z: Int, x: Int, y: Int, ratio: Int
    }

    private let lock = NSLock()
    private var data = Data()
    /// Per zoom key (`z`), most recently used last.
    private var simplified: [(zoom: Int, cache: ZoomCache)] = []
    private var tiles: [TileKey: Foundation.Data] = [:]
    private var tileOrder: [TileKey] = []
    private var tileBytes = 0
    private let tileCacheBytes: Int

    init(tileSize: Int = 256, pixelRatio: Int = 1, tileCacheBytes: Int = 24 * 1024 * 1024) {
        self.tileSize = tileSize
        self.pixelRatio = max(1, pixelRatio)
        self.tileCacheBytes = tileCacheBytes
    }

    // MARK: Changes

    /// Replaces every polygon. Draw order is the order of `shapes`.
    func setPolygons(_ shapes: [PolygonTileShape]) {
        let polygons = shapes.map { Polygon($0) }
        var maxStroke = 0.0
        for p in polygons { if let p, p.stroke != nil { maxStroke = max(maxStroke, p.strokeWidth) } }
        let index = Index(polygons)
        lock.lock()
        data = Data(polygons: polygons, index: index, maxStrokePx: maxStroke, generation: data.generation + 1)
        simplified.removeAll()
        dropAllTilesLocked()
        lock.unlock()
    }

    /// Replaces the polygons at the given positions (as passed to ``setPolygons(_:)``).
    /// Only the cached tiles those polygons overlap, before or after, are dropped.
    func update(_ changes: [(index: Int, shape: PolygonTileShape)]) {
        guard !changes.isEmpty else { return }
        let decoded = changes.map { (index: $0.index, polygon: Polygon($0.shape)) }
        lock.lock()
        defer { lock.unlock() }
        var next = data
        next.generation += 1
        var touched: [Polygon] = []
        var moved = false
        for change in decoded where change.index >= 0 && change.index < next.polygons.count {
            let before = next.polygons[change.index]
            let after = change.polygon
            next.polygons[change.index] = after
            for zoom in simplified { zoom.cache.entries[change.index] = nil }
            if let before { touched.append(before) }
            if let after {
                touched.append(after)
                if after.stroke != nil { next.maxStrokePx = max(next.maxStrokePx, after.strokeWidth) }
            }
            // A shape that moved needs the index rebuilt; a restyle does not.
            if (before == nil) != (after == nil) { moved = true }
            if let before, let after, !before.sameBox(after) { moved = true }
        }
        if moved { next.index = Index(next.polygons) }
        data = next
        dropTilesLocked(overlapping: touched, strokePx: next.maxStrokePx)
    }

    func clear() {
        lock.lock()
        data = Data(generation: data.generation + 1)
        simplified.removeAll()
        dropAllTilesLocked()
        lock.unlock()
    }

    // MARK: TileProvider

    func renderTile(request: TileRequest) -> Foundation.Data? {
        (try? renderTile(request: request, isCancelled: { false })) ?? nil
    }

    func renderTile(request: TileRequest, isCancelled: () -> Bool) throws -> Foundation.Data? {
        let z = request.z
        let worldTiles = 1 << z
        guard z >= 0, z < 31, request.y >= 0, request.y < worldTiles else { return nil }
        let x = ((request.x % worldTiles) + worldTiles) % worldTiles
        let ratio = request.pixelRatio > 1 ? request.pixelRatio : pixelRatio
        let key = TileKey(z: z, x: x, y: request.y, ratio: ratio)

        lock.lock()
        if let cached = tiles[key] {
            lock.unlock()
            return cached
        }
        let snapshot = data
        lock.unlock()

        let outcome = try draw(snapshot, z: z, x: x, y: request.y, ratio: ratio, isCancelled: isCancelled)

        guard let png = outcome else { return nil }
        lock.lock()
        // The polygons may have changed while this tile was drawn.
        if data.generation == snapshot.generation { storeTileLocked(key, png) }
        lock.unlock()
        return png
    }

    // MARK: Drawing

    private struct Cancelled: Error {}

    private func draw(
        _ data: Data, z: Int, x: Int, y: Int, ratio: Int, isCancelled: () -> Bool
    ) throws -> Foundation.Data? {
        let size = Double(tileSize)
        let scale = size * Double(1 << z)
        let originX = Double(x) * size, originY = Double(y) * size
        let pad = data.maxStrokePx / 2 + 1
        let candidates = Self.query(
            data,
            minX: (originX - pad) / scale, minY: (originY - pad) / scale,
            maxX: (originX + size + pad) / scale, maxY: (originY + size + pad) / scale
        )
        if candidates.isEmpty { return nil }

        let pixels = tileSize * ratio
        let bytesPerRow = pixels * 4
        guard let buffer = NSMutableData(length: bytesPerRow * pixels),
              let context = CGContext(
                data: buffer.mutableBytes, width: pixels, height: pixels, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw Cancelled()
        }
        // y down, in points of this tile.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(ratio), y: -CGFloat(ratio))
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let zoomCache = zoomCache(for: z, count: data.polygons.count)
        var drew = false
        for (n, index) in candidates.enumerated() {
            if n & 255 == 255, isCancelled() { throw Cancelled() }
            guard let p = data.polygons[Int(index)] else { continue }
            let shape = simplified(p, index: Int(index), z: z, scale: scale, cache: zoomCache)
            switch shape {
            case .none:
                continue
            case let .dot(px, py):
                guard let color = p.fill ?? p.stroke else { continue }
                context.setFillColor(color)
                context.fill(CGRect(x: px - originX, y: py - originY, width: 1, height: 1))
                drew = true
            case let .rings(rings, outlined):
                if let fill = p.fill {
                    let path = CGMutablePath()
                    for ring in rings { Self.add(ring, to: path, originX: originX, originY: originY) }
                    context.addPath(path)
                    context.setFillColor(fill)
                    context.fillPath(using: .winding)
                    drew = true
                }
                if outlined, let stroke = p.stroke {
                    // Outline only, as the map SDKs draw it.
                    let path = CGMutablePath()
                    Self.add(rings[0], to: path, originX: originX, originY: originY)
                    context.addPath(path)
                    context.setStrokeColor(stroke)
                    context.setLineWidth(CGFloat(p.strokeWidth))
                    context.strokePath()
                    drew = true
                }
            }
        }
        if !drew { return nil }
        if isCancelled() { throw Cancelled() }

        if let png = TilePngEncoder.encode(
            rgba: buffer.mutableBytes, width: pixels, height: pixels, premultiplied: true
        ) {
            return png
        }
        guard let image = context.makeImage(), let png = UIImage(cgImage: image).pngData() else {
            throw Cancelled()
        }
        return png
    }

    private static func add(_ ring: [Double], to path: CGMutablePath, originX: Double, originY: Double) {
        path.move(to: CGPoint(x: ring[0] - originX, y: ring[1] - originY))
        var i = 2
        while i < ring.count {
            path.addLine(to: CGPoint(x: ring[i] - originX, y: ring[i + 1] - originY))
            i += 2
        }
        path.closeSubpath()
    }

    /// Indices of the polygons whose box meets the given one, in draw order.
    private static func query(_ data: Data, minX: Double, minY: Double, maxX: Double, maxY: Double) -> [Int32] {
        var out: [Int32] = []
        let take: (Int32) -> Void = { i in
            guard let p = data.polygons[Int(i)] else { return }
            if p.minX <= maxX && p.maxX >= minX && p.minY <= maxY && p.maxY >= minY { out.append(i) }
        }
        for i in data.index.large { take(i) }
        let cx0 = Int64(floor(minX / cellSize)), cx1 = Int64(floor(maxX / cellSize))
        let cy0 = Int64(floor(minY / cellSize)), cy1 = Int64(floor(maxY / cellSize))
        if cx0 <= cx1, cy0 <= cy1 {
            for cx in cx0...cx1 {
                for cy in cy0...cy1 {
                    if let bucket = data.index.cells[cx &* 1_048_576 &+ cy] { bucket.forEach(take) }
                }
            }
        }
        // A polygon spanning several cells is found once per cell; draw order is list order.
        out.sort()
        var unique: [Int32] = []
        unique.reserveCapacity(out.count)
        for i in out where unique.last != i { unique.append(i) }
        return unique
    }

    private func zoomCache(for z: Int, count: Int) -> ZoomCache {
        lock.lock()
        defer { lock.unlock() }
        if let at = simplified.firstIndex(where: { $0.zoom == z }) {
            let entry = simplified.remove(at: at)
            simplified.append(entry)
            if entry.cache.entries.count == count { return entry.cache }
        }
        let cache = ZoomCache(count: count)
        simplified.removeAll { $0.zoom == z }
        simplified.append((z, cache))
        while simplified.count > Self.zoomsKept { simplified.removeFirst() }
        return cache
    }

    private func simplified(_ p: Polygon, index: Int, z: Int, scale: Double, cache: ZoomCache) -> Simplified {
        lock.lock()
        let cached = cache.entries[index]
        lock.unlock()
        if let cached { return cached }
        let result = Self.simplify(p, scale: scale)
        lock.lock()
        cache.entries[index] = result
        lock.unlock()
        return result
    }

    /// The polygon at the zoom whose world is `scale` pixels wide.
    static func simplify(_ p: Polygon, scale: Double) -> Simplified {
        let w = (p.maxX - p.minX) * scale, h = (p.maxY - p.minY) * scale
        if w < 1 && h < 1 {
            return .dot(floor((p.minX + p.maxX) / 2 * scale), floor((p.minY + p.maxY) / 2 * scale))
        }
        guard let outer = simplifyRing(p.rings[0], scale: scale) else {
            return .dot(((p.minX + p.maxX) / 2 * scale).rounded(), ((p.minY + p.maxY) / 2 * scale).rounded())
        }
        var rings = [outer]
        for r in 1..<p.rings.count {
            if let hole = simplifyRing(p.rings[r], scale: scale) { rings.append(hole) }
        }
        return .rings(rings, outlined: max(w, h) >= minOutlinedPx)
    }

    static func simplifyRing(_ ring: [Double], scale: Double) -> [Double]? {
        var snapped: [Double] = []
        snapped.reserveCapacity(ring.count)
        var px = Double.nan, py = Double.nan
        var i = 0
        while i < ring.count {
            let x = (ring[i] * scale).rounded(), y = (ring[i + 1] * scale).rounded()
            i += 2
            if x == px && y == py { continue }
            snapped.append(x); snapped.append(y)
            px = x; py = y
        }
        let out = douglasPeucker(snapped, tolerance: dpTolerancePx)
        return out.count >= 6 ? out : nil
    }

    /// Douglas-Peucker on flat points; returns the kept points.
    static func douglasPeucker(_ points: [Double], tolerance: Double) -> [Double] {
        let n = points.count / 2
        if n < 3 { return points }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[n - 1] = true
        var stack: [(Int, Int)] = [(0, n - 1)]
        while let (a, b) = stack.popLast() {
            let ax = points[a * 2], ay = points[a * 2 + 1], bx = points[b * 2], by = points[b * 2 + 1]
            let dx = bx - ax, dy = by - ay, len = (dx * dx + dy * dy).squareRoot()
            var best = -1.0, bestIndex = -1
            var i = a + 1
            while i < b {
                let qx = points[i * 2], qy = points[i * 2 + 1]
                let d = len > 0
                    ? abs(dy * (qx - ax) - dx * (qy - ay)) / len
                    : ((qx - ax) * (qx - ax) + (qy - ay) * (qy - ay)).squareRoot()
                if d > best { best = d; bestIndex = i }
                i += 1
            }
            if best > tolerance {
                keep[bestIndex] = true
                stack.append((a, bestIndex))
                stack.append((bestIndex, b))
            }
        }
        var out: [Double] = []
        for i in 0..<n where keep[i] {
            out.append(points[i * 2]); out.append(points[i * 2 + 1])
        }
        return out
    }

    // MARK: Tile cache

    private func storeTileLocked(_ key: TileKey, _ png: Foundation.Data) {
        if let old = tiles[key] {
            tileBytes -= old.count
        } else {
            tileOrder.append(key)
        }
        tiles[key] = png
        tileBytes += png.count
        while tileBytes > tileCacheBytes, !tileOrder.isEmpty {
            let oldest = tileOrder.removeFirst()
            if let dropped = tiles.removeValue(forKey: oldest) { tileBytes -= dropped.count }
        }
    }

    private func dropAllTilesLocked() {
        tiles.removeAll()
        tileOrder.removeAll()
        tileBytes = 0
    }

    private func dropTilesLocked(overlapping boxes: [Polygon], strokePx: Double) {
        guard !boxes.isEmpty, !tiles.isEmpty else { return }
        let size = Double(tileSize)
        var dropped = Set<TileKey>()
        for key in tiles.keys {
            let scale = size * Double(1 << key.z)
            let pad = (strokePx + 2) / scale
            let tx0 = Double(key.x) * size / scale - pad, tx1 = Double(key.x + 1) * size / scale + pad
            let ty0 = Double(key.y) * size / scale - pad, ty1 = Double(key.y + 1) * size / scale + pad
            if boxes.contains(where: { $0.minX <= tx1 && $0.maxX >= tx0 && $0.minY <= ty1 && $0.maxY >= ty0 }) {
                dropped.insert(key)
            }
        }
        for key in dropped { if let png = tiles.removeValue(forKey: key) { tileBytes -= png.count } }
        if !dropped.isEmpty { tileOrder.removeAll { dropped.contains($0) } }
    }

    /// Number of tiles in the cache, for tests.
    var cachedTileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tiles.count
    }

    // MARK: Geometry

    static func toMercator(_ latLngs: [Double]) -> [Double] {
        let n = latLngs.count / 2
        var ring = [Double](repeating: 0, count: n * 2)
        for i in 0..<n {
            let lat = min(85.05112878, max(-85.05112878, latLngs[i * 2]))
            let s = sin(lat * .pi / 180)
            ring[i * 2] = (latLngs[i * 2 + 1] + 180) / 360
            ring[i * 2 + 1] = 0.5 - log((1 + s) / (1 - s)) / (4 * .pi)
        }
        return ring
    }

    static func signedArea(_ ring: [Double]) -> Double {
        let n = ring.count / 2
        var area = 0.0
        var j = n - 1
        for i in 0..<n {
            area += ring[j * 2] * ring[i * 2 + 1] - ring[i * 2] * ring[j * 2 + 1]
            j = i
        }
        return area / 2
    }

    static func reversed(_ ring: [Double]) -> [Double] {
        let n = ring.count / 2
        var out = [Double](repeating: 0, count: ring.count)
        for i in 0..<n {
            out[i * 2] = ring[(n - 1 - i) * 2]
            out[i * 2 + 1] = ring[(n - 1 - i) * 2 + 1]
        }
        return out
    }

    static func isVisible(_ color: CGColor?) -> Bool {
        guard let color else { return false }
        return color.alpha > 0
    }
}
