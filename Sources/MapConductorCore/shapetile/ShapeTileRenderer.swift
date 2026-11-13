import CoreGraphics
import Foundation
import UIKit

/**
 Draws a set of shapes — polygons, polylines or circles — into raster tiles.

 The renderer under ``PolygonTileSet`` (polygons), ``PolylineTileSet``
 (polylines) and ``CircleTileSet`` (circles); each tile set has its own
 renderer, so one renderer only ever holds one kind. The native counterpart of the "Shape tiles" section of
 js-sdk-core's `tile-sw.js`, and drawn the same way:

 - Every shape is kept in Web Mercator coordinates in [0, 1]. A polygon's
   outline is wound one way and its holes the other, so a nonzero ("winding")
   fill leaves out the union of the holes without computing it. A polyline is
   one open path.
 - Shapes are found through grids of their bounding boxes. The finest cell
   is one z12 tile; wide shapes use coarser grids. Candidates are deduplicated
   before their bounds are tested, keeping queries bounded by actual shapes.
 - Each zoom gets its own simplified copy of a shape, built the first time a
   tile at that zoom needs it: vertices snapped to that zoom's pixel grid,
   repeats dropped, Douglas-Peucker at half a pixel (a path keeps both ends).
   A polygon smaller than a pixel is drawn as one pixel; a polyline that
   collapses to one point is drawn as a dot as wide as the line.
 - A circle is kept as its centre and radius (``CircleTilePainter``): a true
   circle at each zoom, or the native 128-gon where the projection bends it,
   one pixel when it is smaller than one. Its radius is on the ground, so it
   doubles with each zoom; its outline is on screen, as a polygon's.
 - A polygon's outline only is stroked, and not at all for a polygon under 4 px
   on screen. A polyline is stroked, never filled. Caps and joins are round.
 - Line widths are on screen (points), so they do not change with the zoom.
   Tiles query with a margin of the widest line and draw what overhangs the
   tile as it is; the neighbour draws the same line at the same place, so a
   line crossing a tile edge is never cut or thinned there.
 - Draw order is the order given, which the caller sorted by zIndex.

 Taps never see any of this; they are resolved against the original shapes.

 Tiles are cached without a version. A change (``update(_:)``) drops only the
 cached tiles the changed shapes overlap, so the map, which must ask again
 because the URL's version changed, gets every other tile from the cache.
 */
final class ShapeTileRenderer: TileProvider {
    /// Cells of the shape index, in Web Mercator units: one z12 tile.
    static let cellSize = 1.0 / 4096.0
    /// Simplified copies kept, most recent zooms first.
    static let zoomsKept = 4
    static let dpTolerancePx = 0.5
    /// Below this size on screen a polygon's outline is left out: a 1 px line
    /// round a 3 px parcel is the whole parcel, and a city of them zoomed out
    /// turns into the outline colour.
    static let minOutlinedPx = 4.0
    /// The Web Mercator world's edge, where ``toMercator(_:)`` clamps latitudes.
    static let maxLatitude = 85.05112878

    /// Logical tile size (points), the grid the map asks tiles on.
    let tileSize: Int
    /// Pixels per point in the drawn tile.
    let pixelRatio: Int

    // MARK: Shapes

    /// One shape as drawn: plain values, so drawing never touches a state.
    final class Shape {
        enum Kind { case polygon, line, circle }

        let kind: Kind
        /// Mercator rings, flat `[x, y, ...]`. A polygon's outline has positive
        /// area and its holes negative; a polyline has one ring, its open path.
        let rings: [[Double]]
        let minX: Double, minY: Double, maxX: Double, maxY: Double
        let fill: CGColor?
        let stroke: CGColor?
        let strokeWidth: Double
        /// A circle's centre and extent; nil for the other kinds.
        let circle: CircleTilePainter.Geometry?

        private convenience init(kind: Kind, rings: [[Double]], fill: CGColor?, stroke: CGColor?, strokeWidth: Double) {
            let first = rings[0]
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            var i = 0
            while i < first.count {
                minX = Swift.min(minX, first[i]); maxX = Swift.max(maxX, first[i])
                minY = Swift.min(minY, first[i + 1]); maxY = Swift.max(maxY, first[i + 1])
                i += 2
            }
            self.init(
                kind: kind, rings: rings, minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                fill: fill, stroke: stroke, strokeWidth: strokeWidth, circle: nil
            )
        }

        init(
            kind: Kind, rings: [[Double]], minX: Double, minY: Double, maxX: Double, maxY: Double,
            fill: CGColor?, stroke: CGColor?, strokeWidth: Double, circle: CircleTilePainter.Geometry?
        ) {
            self.kind = kind
            self.rings = rings
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
            self.fill = ShapeTileRenderer.isVisible(fill) ? fill : nil
            self.stroke = strokeWidth > 0 && ShapeTileRenderer.isVisible(stroke) ? stroke : nil
            self.strokeWidth = strokeWidth
            self.circle = circle
        }

        /// A circle; nil when it has no extent (a radius of 0 or less, or not finite).
        convenience init?(_ shape: CircleTileShape) {
            guard let geometry = CircleTilePainter.Geometry(shape) else { return nil }
            self.init(
                kind: .circle, rings: [],
                minX: geometry.westX, minY: geometry.northY, maxX: geometry.eastX, maxY: geometry.southY,
                fill: shape.fill, stroke: shape.stroke, strokeWidth: shape.strokeWidth, circle: geometry
            )
        }

        /// A polygon; nil when its outline has fewer than 3 points.
        convenience init?(_ shape: PolygonTileShape) {
            var rings: [[Double]] = []
            for (r, latLngs) in shape.rings.enumerated() {
                var ring = ShapeTileRenderer.toMercator(latLngs)
                if ring.count < 6 {
                    if r == 0 { return nil }
                    continue
                }
                let area = ShapeTileRenderer.signedArea(ring)
                if (r == 0 && area < 0) || (r > 0 && area > 0) { ring = ShapeTileRenderer.reversed(ring) }
                rings.append(ring)
            }
            self.init(kind: .polygon, rings: rings, fill: shape.fill, stroke: shape.stroke, strokeWidth: shape.strokeWidth)
        }

        /// A polyline; nil when it has fewer than 2 points.
        convenience init?(_ shape: PolylineTileShape) {
            let path = ShapeTileRenderer.toMercator(shape.points)
            if path.count < 4 { return nil }
            self.init(kind: .line, rings: [path], fill: nil, stroke: shape.stroke, strokeWidth: shape.strokeWidth)
        }

        /// The widest line this shape draws, in points (0 when it draws none).
        var strokePx: Double { stroke != nil ? strokeWidth : 0 }

        func sameBox(_ other: Shape) -> Bool {
            minX == other.minX && minY == other.minY && maxX == other.maxX && maxY == other.maxY
        }
    }

    /// The name ``PolygonTileRendererTests`` use.
    typealias Polygon = Shape

    struct Index {
        struct Level {
            let size: Double
            var cells: [Int64: [Int32]] = [:]
            var groups: [Int64: [[Int32]]] = [:]
            var canGroup = true
        }
        var levels = (0..<7).map { Level(size: ShapeTileRenderer.cellSize * Double(1 << ($0 * 2))) }

        init(_ shapes: [Shape?]) { self.init(ShapeTileStorage(shapes)) }

        init(_ shapes: ShapeTileStorage) {
            // In storage order: a file stored by place is then read page by page.
            let order = shapes.storageOrder
            for position in 0..<shapes.count {
                let i = order.map { Int($0[position]) } ?? position
                guard let p = shapes.bounds(at: i) else { continue }
                var level = 0
                func cellCount(_ size: Double) -> Double {
                    (floor(p.maxX / size) - floor(p.minX / size) + 1) *
                        (floor(p.maxY / size) - floor(p.minY / size) + 1)
                }
                // A nationwide circle must not be replicated in hundreds of
                // z12 cells, or checked by every tile in a global overflow list.
                while level < levels.count - 1 && cellCount(levels[level].size) > 16 { level += 1 }
                let size = levels[level].size
                let cx0 = Int64(floor(p.minX / size)), cx1 = Int64(floor(p.maxX / size))
                let cy0 = Int64(floor(p.minY / size)), cy1 = Int64(floor(p.maxY / size))
                if cy0 < 0 || cy1 >= 1_048_576 { levels[level].canGroup = false }
                for cx in cx0...cx1 {
                    for cy in cy0...cy1 {
                        levels[level].cells[cx &* 1_048_576 &+ cy, default: []].append(Int32(i))
                    }
                }
            }
            for level in levels.indices where levels[level].canGroup {
                for (key, bucket) in levels[level].cells {
                    let cy = key & 1_048_575
                    let cx = (key - cy) / 1_048_576
                    let gx = Int64(floor(Double(cx) / 16)), gy = cy / 16
                    levels[level].groups[gx &* 1_048_576 &+ gy, default: []].append(bucket)
                }
            }
            levels.removeAll { $0.cells.isEmpty }
        }

        /// Each matching shape once, in the original draw order.
        func query(_ shapes: [Shape?], minX: Double, minY: Double, maxX: Double, maxY: Double) -> [Int32] {
            query(ShapeTileStorage(shapes), minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }

        func query(_ shapes: ShapeTileStorage, minX: Double, minY: Double, maxX: Double, maxY: Double) -> [Int32] {
            var matches = [UInt64](repeating: 0, count: (shapes.count + 63) / 64)
            func take(_ index: Int32) {
                let i = Int(index), word = i >> 6
                let bit = UInt64(1) << (i & 63)
                matches[word] |= bit
            }
            for level in levels {
                let cx0 = Int64(floor(minX / level.size)), cx1 = Int64(floor(maxX / level.size))
                let cy0 = Int64(floor(minY / level.size)), cy1 = Int64(floor(maxY / level.size))
                let cells = Double(cx1 - cx0 + 1) * Double(cy1 - cy0 + 1)
                if cells > 16_384, level.canGroup, !level.groups.isEmpty {
                    let gx0 = Int64(floor(Double(cx0) / 16)), gx1 = Int64(floor(Double(cx1) / 16))
                    let gy0 = Int64(floor(Double(cy0) / 16)), gy1 = Int64(floor(Double(cy1) / 16))
                    let groupArea = Double(gx1 - gx0 + 1) * Double(gy1 - gy0 + 1)
                    if groupArea > Double(level.groups.count) {
                        for bucket in level.cells.values { for i in bucket { take(i) } }
                    } else if gx0 <= gx1, gy0 <= gy1 {
                        for gx in gx0...gx1 { for gy in gy0...gy1 {
                            if let buckets = level.groups[gx &* 1_048_576 &+ gy] {
                                for bucket in buckets { for i in bucket { take(i) } }
                            }
                        } }
                    }
                } else if cells > Double(level.cells.count) {
                    for bucket in level.cells.values { for i in bucket { take(i) } }
                } else if cx0 <= cx1, cy0 <= cy1 {
                    for cx in cx0...cx1 {
                        for cy in cy0...cy1 {
                            if let bucket = level.cells[cx &* 1_048_576 &+ cy] {
                                for i in bucket { take(i) }
                            }
                        }
                    }
                }
            }
            // Deduplicate before bounding-box checks, then enumerate set bits:
            // no giant temporary list or sorting of duplicate candidates.
            var result: [Int32] = []
            for (word, value) in matches.enumerated() {
                var bits = value
                while bits != 0 {
                    let i = word * 64 + bits.trailingZeroBitCount
                    if shapes.active?[i] != false, let p = shapes.bounds(at: i),
                       p.minX <= maxX && p.maxX >= minX && p.minY <= maxY && p.maxY >= minY {
                        result.append(Int32(i))
                    }
                    bits &= bits - 1
                }
            }
            return result
        }
    }

    /// What is drawn; replaced as a whole (copy-on-write) so a tile being drawn
    /// keeps the version it started with.
    private struct Data {
        var shapes = ShapeTileStorage([])
        var index = Index(ShapeTileStorage([]))
        var maxStrokePx = 0.0
        /// Bumped by every change, so a tile drawn before it is not cached after it.
        var generation = 0
    }

    /// A shape as drawn at one zoom.
    enum Simplified {
        case none
        /// Collapsed to one point, at this world-pixel position: one pixel for a
        /// polygon, a dot as wide as the line for a polyline.
        case dot(Double, Double)
        /// World-pixel rings of a polygon, the first the outline.
        case rings([[Double]], outlined: Bool)
        /// World-pixel points of a polyline, flat `[x, y, ...]`, at least two.
        case path([Double])
        /// A circle drawn as a true circle: world-pixel centre and radius.
        case arc(Double, Double, Double, outlined: Bool)
    }

    private final class ZoomCache {
        let shapeCount: Int
        // A new zoom used to initialise a large optional-enum array for every
        // registered shape, even when only a few circles touch the viewport.
        // Store just the shapes actually requested at this zoom.
        var entries: [Int: Simplified] = [:]
        init(count: Int) { shapeCount = count }
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

    /// Replaces every shape. Draw order is the order of `shapes`; a nil keeps a
    /// slot that draws nothing.
    func setShapes(_ shapes: [Shape?]) {
        setStorage(ShapeTileStorage(shapes))
    }

    func setStorage(_ shapes: ShapeTileStorage) {
        prepareStorage(shapes)()
    }

    /// Build the index away from the route lock; publication is a short operation.
    func prepareStorage(_ shapes: ShapeTileStorage) -> () -> Void {
        var maxStroke = 0.0
        let order = shapes.storageOrder
        for position in 0..<shapes.count {
            maxStroke = max(maxStroke, shapes.strokeWidth(at: order.map { Int($0[position]) } ?? position))
        }
        let index = Index(shapes)
        return {
            self.lock.lock()
            self.data = Data(shapes: shapes, index: index, maxStrokePx: maxStroke, generation: self.data.generation + 1)
            self.simplified.removeAll()
            self.dropAllTilesLocked()
            self.lock.unlock()
        }
    }

    func reuseCircles(_ states: [CircleState], slots: [Int], active: [Bool]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for (state, slot) in zip(states, slots) where !data.shapes.matches(state, at: slot) { return false }
        data.shapes.active = active
        data.generation += 1
        dropAllTilesLocked()
        return true
    }

    /// Replaces the shapes at the given positions (as passed to ``setShapes(_:)``);
    /// a nil shape empties the slot (a shape taken out of the tiles).
    /// Only the cached tiles those shapes overlap, before or after, are dropped.
    func update(_ changes: [(index: Int, shape: Shape?)]) {
        guard !changes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var next = data
        next.generation += 1
        var touched: [Shape] = []
        var moved = false
        for change in changes where change.index >= 0 && change.index < next.shapes.count {
            let before = next.shapes[change.index]
            let after = change.shape
            next.shapes[change.index] = after
            for zoom in simplified { zoom.cache.entries[change.index] = nil }
            if let before { touched.append(before) }
            if let after {
                touched.append(after)
                next.maxStrokePx = max(next.maxStrokePx, after.strokePx)
            }
            // A shape that moved needs the index rebuilt; a restyle does not.
            if before == nil && after != nil { moved = true }
            if let before, let after, !before.sameBox(after) { moved = true }
        }
        if moved { next.index = Index(next.shapes) }
        next.shapes.compactIfNeeded()
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
        // The shapes may have changed while this tile was drawn.
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

        let zoomCache = zoomCache(for: z, count: data.shapes.count)
        let thinCircles = data.shapes[Int(candidates[0])]?.kind == .circle
        if thinCircles, let gpu = gpuRasterizer(),
           case let .drawn(png) = try drawCircles(
               on: gpu, data, candidates: candidates, scale: scale,
               originX: originX, originY: originY, ratio: ratio, isCancelled: isCancelled
           ) {
            return png
        }

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

        var lastDot = [Int32](repeating: 0, count: thinCircles ? tileSize * tileSize : 0)
        if thinCircles { for (n, index) in candidates.enumerated() {
            if n & 255 == 255, isCancelled() { throw Cancelled() }
            guard let p = data.shapes[Int(index)], p.kind == .circle,
                  p.fill != nil || (p.strokeWidth > 0 && p.stroke != nil) else { continue }
            let slot = CircleTilePainter.subpixelSlot(p, scale: scale, originX: originX, originY: originY, tileSize: tileSize)
            if slot >= 0 { lastDot[slot] = index + 1 }
        } }
        var drew = false
        for (n, index) in candidates.enumerated() {
            if n & 255 == 255, isCancelled() { throw Cancelled() }
            guard let p = data.shapes[Int(index)] else { continue }
            if thinCircles {
                let slot = CircleTilePainter.subpixelSlot(p, scale: scale, originX: originX, originY: originY, tileSize: tileSize)
                if slot == -1 || (slot >= 0 && lastDot[slot] != index + 1) { continue }
            }
            let shape = simplified(p, index: Int(index), z: z, scale: scale, cache: zoomCache)
            switch shape {
            case .none:
                continue
            case let .dot(px, py):
                if p.kind == .line {
                    guard let color = p.stroke else { continue }
                    // As wide as the line, and at least one pixel.
                    let d = max(p.strokeWidth, 1 / Double(ratio))
                    context.setFillColor(color)
                    context.fillEllipse(in: CGRect(x: px - originX - d / 2, y: py - originY - d / 2, width: d, height: d))
                } else {
                    guard let color = p.fill ?? p.stroke else { continue }
                    context.setFillColor(color)
                    context.fill(CGRect(x: px - originX, y: py - originY, width: 1, height: 1))
                }
                drew = true
            case let .rings(rings, outlined):
                if let fill = p.fill {
                    let path = CGMutablePath()
                    for ring in rings { Self.add(ring, to: path, originX: originX, originY: originY, close: true) }
                    context.addPath(path)
                    context.setFillColor(fill)
                    context.fillPath(using: .winding)
                    drew = true
                }
                if outlined, let stroke = p.stroke {
                    // Outline only, as the map SDKs draw it.
                    let path = CGMutablePath()
                    Self.add(rings[0], to: path, originX: originX, originY: originY, close: true)
                    context.addPath(path)
                    context.setStrokeColor(stroke)
                    context.setLineWidth(CGFloat(p.strokeWidth))
                    context.strokePath()
                    drew = true
                }
            case let .arc(cx, cy, radius, outlined):
                if CircleTilePainter.drawArc(
                    p, in: context, cx: cx - originX, cy: cy - originY, radius: radius, outlined: outlined
                ) {
                    drew = true
                }
            case let .path(points):
                guard let stroke = p.stroke else { continue }
                let path = CGMutablePath()
                Self.add(points, to: path, originX: originX, originY: originY, close: false)
                context.addPath(path)
                context.setStrokeColor(stroke)
                context.setLineWidth(CGFloat(p.strokeWidth))
                context.strokePath()
                drew = true
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

    private enum GpuOutcome {
        /// Drawn on the GPU: the PNG, or nil when nothing was drawn.
        case drawn(Foundation.Data?)
        /// The tile needs the CPU (a circle drawn as its 128-gon, or the GPU failed).
        case fallback
    }

    /// Circles only, on the GPU (``MetalShapeRasterizer``): the same choices as
    /// the CPU loop in ``draw(_:z:x:y:ratio:isCancelled:)`` and ``CircleTilePainter``
    /// -- which circle a pixel keeps, Dot or Arc, outlined or not -- made into instances.
    ///
    /// Reads plain values (``ShapeTileStorage/circleValues(at:colors:)``): building a
    /// ``Shape`` per circle from the geometry file took 6 µs, seconds for a tile of
    /// a few hundred thousand, against milliseconds for drawing them all.
    private func drawCircles(
        on gpu: MetalShapeRasterizer, _ data: Data, candidates: [Int32], scale: Double,
        originX: Double, originY: Double, ratio: Int, isCancelled: () -> Bool
    ) throws -> GpuOutcome {
        let colors = ShapeColorCache()
        let tile = Double(tileSize)
        /// -2: a circle of a pixel or more; -1: a dot outside this tile; else its pixel.
        func slot(_ c: ShapeTileStorage.CircleValues) -> Int {
            let radius = max(c.east - c.x, c.y - c.north, c.south - c.y) * scale
            guard radius < 0.5 else { return -2 }
            let x = floor(c.x * scale) - originX, y = floor(c.y * scale) - originY
            guard x >= 0, x < tile, y >= 0, y < tile else { return -1 }
            return Int(y) * tileSize + Int(x)
        }
        var lastDot = [Int32](repeating: 0, count: tileSize * tileSize)
        for (n, index) in candidates.enumerated() {
            if n & 4095 == 4095, isCancelled() { throw Cancelled() }
            guard let c = data.shapes.circleValues(at: Int(index), colors: colors),
                  c.fill != nil || c.stroke != nil else { continue }
            let at = slot(c)
            if at >= 0 { lastDot[at] = index + 1 }
        }
        let r = Float(ratio)
        var instances: [MetalShapeRasterizer.Instance] = []
        instances.reserveCapacity(min(candidates.count, tileSize * tileSize))
        for (n, index) in candidates.enumerated() {
            if n & 4095 == 4095, isCancelled() { throw Cancelled() }
            guard let c = data.shapes.circleValues(at: Int(index), colors: colors) else { continue }
            let at = slot(c)
            if at == -1 || (at >= 0 && lastDot[at] != index + 1) { continue }
            let cx = c.x * scale, cy = c.y * scale
            let rx = (c.east - c.x) * scale
            let ryN = (c.y - c.north) * scale, ryS = (c.south - c.y) * scale
            if max(rx, ryN, ryS) < 0.5 {
                // Dot: one point, the fill colour or else the outline's.
                guard let color = c.fill ?? c.stroke else { continue }
                instances.append(.init(
                    x: Float(floor(cx) - originX) * r, y: Float(floor(cy) - originY) * r, radius: r, strokeWidth: r,
                    fill: color, stroke: .zero, kind: 1
                ))
                continue
            }
            // Bent by the projection: the 128-gon, which only the CPU draws.
            if max(abs(ryN - rx), abs(ryS - rx)) > CircleTilePainter.arcTolerancePx { return .fallback }
            let outlined = 2 * max(rx, ryN, ryS) >= Self.minOutlinedPx
            let stroke = outlined ? c.stroke : nil
            if c.fill == nil && stroke == nil { continue }
            instances.append(.init(
                x: Float(cx - originX) * r, y: Float(cy - originY) * r, radius: Float(rx) * r,
                strokeWidth: stroke == nil ? 0 : Float(c.strokeWidth) * r,
                fill: c.fill ?? .zero, stroke: stroke ?? .zero, kind: 0
            ))
        }
        if instances.isEmpty { return .drawn(nil) }
        if isCancelled() { throw Cancelled() }
        guard let png = gpu.renderPng(instances: instances, pixels: tileSize * ratio) else { return .fallback }
        return .drawn(png)
    }

    /// The GPU rasterizer for circle tiles; nil without Metal, or with
    /// `MAPCONDUCTOR_SHAPE_TILE_CPU=1` to compare against the CPU drawing.
    private func gpuRasterizer() -> MetalShapeRasterizer? {
        if ProcessInfo.processInfo.environment["MAPCONDUCTOR_SHAPE_TILE_CPU"] == "1" { return nil }
        return MetalShapeRasterizer.shared
    }

    private static func add(_ ring: [Double], to path: CGMutablePath, originX: Double, originY: Double, close: Bool) {
        path.move(to: CGPoint(x: ring[0] - originX, y: ring[1] - originY))
        var i = 2
        while i < ring.count {
            path.addLine(to: CGPoint(x: ring[i] - originX, y: ring[i + 1] - originY))
            i += 2
        }
        if close { path.closeSubpath() }
    }

    /// Slots whose shape's box meets the given one (Web Mercator). For taps: the caller tests the few candidates
    /// against their states instead of reading every state.
    func candidates(minX: Double, minY: Double, maxX: Double, maxY: Double) -> [Int32] {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return Self.query(snapshot, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// The widest outline drawn (points).
    var maxStrokePx: Double {
        lock.lock()
        defer { lock.unlock() }
        return data.maxStrokePx
    }

    /// Indices of the shapes whose box meets the given one, in draw order.
    private static func query(_ data: Data, minX: Double, minY: Double, maxX: Double, maxY: Double) -> [Int32] {
        data.index.query(data.shapes, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func zoomCache(for z: Int, count: Int) -> ZoomCache {
        lock.lock()
        defer { lock.unlock() }
        if let at = simplified.firstIndex(where: { $0.zoom == z }) {
            let entry = simplified.remove(at: at)
            simplified.append(entry)
            if entry.cache.shapeCount == count { return entry.cache }
        }
        let cache = ZoomCache(count: count)
        simplified.removeAll { $0.zoom == z }
        simplified.append((z, cache))
        while simplified.count > Self.zoomsKept { simplified.removeFirst() }
        return cache
    }

    private func simplified(_ p: Shape, index: Int, z: Int, scale: Double, cache: ZoomCache) -> Simplified {
        // Dot/Arc projection is cheap; retaining one object per circle at
        // several zooms costs more than recomputing it for visible tiles.
        if p.kind == .circle { return CircleTilePainter.simplify(p, scale: scale) }
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

    /// The shape at the zoom whose world is `scale` pixels wide.
    static func simplify(_ p: Shape, scale: Double) -> Simplified {
        switch p.kind {
        case .polygon: return simplifyPolygon(p, scale: scale)
        case .line: return simplifyLine(p, scale: scale)
        case .circle: return CircleTilePainter.simplify(p, scale: scale)
        }
    }

    private static func simplifyPolygon(_ p: Shape, scale: Double) -> Simplified {
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

    /// An open path: snapped, repeats dropped, Douglas-Peucker with both ends
    /// kept. One that collapses to a single point (or fits in a pixel) is a dot.
    private static func simplifyLine(_ p: Shape, scale: Double) -> Simplified {
        let w = (p.maxX - p.minX) * scale, h = (p.maxY - p.minY) * scale
        if w < 1 && h < 1 {
            return .dot(((p.minX + p.maxX) / 2 * scale).rounded(), ((p.minY + p.maxY) / 2 * scale).rounded())
        }
        let snapped = snap(p.rings[0], scale: scale)
        if snapped.count < 4 { return .dot(snapped[0], snapped[1]) }
        return .path(douglasPeucker(snapped, tolerance: dpTolerancePx))
    }

    /// Vertices on the pixel grid of `scale`, consecutive repeats dropped.
    static func snap(_ ring: [Double], scale: Double) -> [Double] {
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
        return snapped
    }

    static func simplifyRing(_ ring: [Double], scale: Double) -> [Double]? {
        let out = douglasPeucker(snap(ring, scale: scale), tolerance: dpTolerancePx)
        return out.count >= 6 ? out : nil
    }

    /// Douglas-Peucker on flat points; returns the kept points. The first and
    /// last are always kept.
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

    private func dropTilesLocked(overlapping boxes: [Shape], strokePx: Double) {
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
            let lat = min(maxLatitude, max(-maxLatitude, latLngs[i * 2]))
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
