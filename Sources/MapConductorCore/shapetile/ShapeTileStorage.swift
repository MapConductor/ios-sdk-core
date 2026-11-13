import CoreGraphics
import Darwin
import Foundation

/// A render snapshot shares the read-only file mapping. Edits affect only the
/// snapshot's overrides, so in-flight tiles can safely finish on the old data.
struct ShapeTileStorage {
    typealias Shape = ShapeTileRenderer.Shape
    typealias Bounds = (minX: Double, minY: Double, maxX: Double, maxY: Double)

    private var memory: [Shape?] = []
    private var file: CircleGeometryFile?
    private var overrides: [Int: Shape?] = [:]
    var active: [Bool]?

    init(_ shapes: [Shape?]) { memory = shapes }
    init(_ file: CircleGeometryFile) { self.file = file }

    var count: Int { file?.count ?? memory.count }

    /// Stored position -> index, when the file is stored by place (see
    /// ``CircleGeometryFile``). A pass over every shape walks this order.
    var storageOrder: [Int32]? { file?.indexAt }

    subscript(index: Int) -> Shape? {
        get {
            guard let file else { return memory[index] }
            if let entry = overrides[index] { return entry }
            return file.shape(at: index)
        }
        set {
            if file == nil { memory[index] = newValue }
            else { overrides[index] = .some(newValue) }
        }
    }

    func bounds(at index: Int) -> Bounds? {
        if let file, overrides[index] == nil { return file.record(at: index).bounds }
        guard let p = self[index] else { return nil }
        return (p.minX, p.minY, p.maxX, p.maxY)
    }

    func strokeWidth(at index: Int) -> Double {
        if let file, overrides[index] == nil { return file.record(at: index).visibleStrokeWidth }
        return self[index]?.strokePx ?? 0
    }

    mutating func compactIfNeeded() {
        guard overrides.count > 2_048 else { return }
        let snapshot = self
        if let replacement = try? CircleGeometryFile(count: count, order: file?.indexAt, shapeAt: { snapshot[$0] }) {
            self = ShapeTileStorage(replacement)
            active = snapshot.active
        }
    }

    func matches(_ state: CircleState, at index: Int) -> Bool {
        guard let file, overrides[index] == nil else { return false }
        return file.matches(state, at: index)
    }

    /// A circle as the GPU path reads it: plain values, no objects made.
    struct CircleValues {
        var x: Double, y: Double, north: Double, south: Double, east: Double
        var strokeWidth: Double
        /// Premultiplied colours; nil when not drawn.
        var fill: SIMD4<Float>?
        var stroke: SIMD4<Float>?
    }

    /// The circle at `index` without building a ``Shape``: the file's record
    /// as it is, or the overriding shape. Nil for an empty slot or another kind.
    /// `colors` turns a colour into premultiplied RGBA once per colour.
    func circleValues(at index: Int, colors: ShapeColorCache) -> CircleValues? {
        if let file, overrides[index] == nil {
            let r = file.record(at: index)
            guard r.radius > 0 else { return nil }
            return CircleValues(
                x: r.x, y: r.y, north: r.north, south: r.south, east: r.east, strokeWidth: r.strokeWidth,
                fill: file.premultipliedColor(r.fill), stroke: r.strokeWidth > 0 ? file.premultipliedColor(r.stroke) : nil
            )
        }
        guard let p = self[index], let c = p.circle else { return nil }
        return CircleValues(
            x: c.x, y: c.y, north: c.northY, south: c.southY, east: c.eastX, strokeWidth: p.strokeWidth,
            fill: colors.premultiplied(p.fill), stroke: colors.premultiplied(p.stroke)
        )
    }
}

/// Premultiplied RGBA per `CGColor`, for one tile: a tile reuses a handful of colours.
final class ShapeColorCache {
    private var cache: [CGColor: SIMD4<Float>?] = [:]

    func premultiplied(_ color: CGColor?) -> SIMD4<Float>? {
        guard let color else { return nil }
        if let hit = cache[color] { return hit }
        let value = MetalShapeRasterizer.premultiplied(color)
        cache[color] = value
        return value
    }
}

/// Fixed-width geometry streamed to an anonymous cache file and paged by the OS.
/// The mapping is reclaimed when the last render snapshot releases it.
///
/// With an `order`, the records are stored by place: a tile's circles then lie
/// in a few pages instead of all over the file. Everything here still takes
/// the list's indices.
final class CircleGeometryFile {
    struct Record {
        var latitude = 0.0, longitude = 0.0, radius = 0.0
        var x = 0.0, y = 0.0, west = 0.0, north = 0.0, east = 0.0, south = 0.0
        var strokeWidth = 0.0
        var fill: UInt32 = 0, stroke: UInt32 = 0
        var geodesic = false

        var bounds: ShapeTileStorage.Bounds? { radius > 0 ? (west, north, east, south) : nil }
        var visibleStrokeWidth: Double { stroke == 0 ? 0 : strokeWidth }
    }

    private static let stride = MemoryLayout<Record>.stride
    let count: Int
    /// Stored position -> index, and back; nil when stored in index order.
    let indexAt: [Int32]?
    private let positionOf: [Int32]?
    private let mapping: UnsafeMutableRawPointer
    private let colors: [CGColor]
    /// The palette as premultiplied RGBA, made once: the GPU path reads a colour per circle.
    private let premultipliedPalette: [SIMD4<Float>?]

    init(count: Int, order: [Int32]? = nil, shapeAt: (Int) -> ShapeTileRenderer.Shape?) throws {
        precondition(order == nil || order!.count == count)
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = directory.appendingPathComponent("mc-circle-\(UUID().uuidString)")
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard unlink(url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var palette: [CGColor] = []
        var indices: [CGColor: UInt32] = [:]
        func colorIndex(_ color: CGColor?) -> UInt32 {
            guard let color else { return 0 }
            if let index = indices[color] { return index }
            palette.append(color)
            let index = UInt32(palette.count)
            indices[color] = index
            return index
        }

        var block = Data(count: 512 * Self.stride)
        for start in Swift.stride(from: 0, to: count, by: 512) {
            try Task.checkCancellation()
            let size = min(512, count - start)
            block.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for i in 0..<size {
                    var record = Record()
                    let index = order.map { Int($0[start + i]) } ?? start + i
                    if let p = shapeAt(index), let c = p.circle {
                        record = Record(latitude: c.latitude, longitude: c.longitude, radius: c.radiusMeters,
                                        x: c.x, y: c.y, west: c.westX, north: c.northY, east: c.eastX, south: c.southY,
                                        strokeWidth: p.strokeWidth, fill: colorIndex(p.fill), stroke: colorIndex(p.stroke),
                                        geodesic: c.geodesic)
                    }
                    bytes.storeBytes(of: record, toByteOffset: i * Self.stride, as: Record.self)
                }
            }
            try handle.write(contentsOf: block.prefix(size * Self.stride))
        }
        let mapped = mmap(nil, count * Self.stride, PROT_READ, MAP_PRIVATE, fd, 0)
        guard let mapped, mapped != MAP_FAILED else { throw CocoaError(.fileReadUnknown) }
        self.count = count
        self.indexAt = order
        if let order {
            var positions = [Int32](repeating: 0, count: count)
            for (position, index) in order.enumerated() { positions[Int(index)] = Int32(position) }
            self.positionOf = positions
        } else {
            self.positionOf = nil
        }
        self.mapping = mapped
        self.colors = palette
        self.premultipliedPalette = palette.map { MetalShapeRasterizer.premultiplied($0) }
    }

    deinit { munmap(mapping, count * Self.stride) }

    /// The colour at a record's index (0 is none) as premultiplied RGBA.
    func premultipliedColor(_ index: UInt32) -> SIMD4<Float>? {
        guard index > 0 else { return nil }
        return premultipliedPalette[Int(index) - 1]
    }

    func record(at index: Int) -> Record {
        let position = positionOf.map { Int($0[index]) } ?? index
        return mapping.load(fromByteOffset: position * Self.stride, as: Record.self)
    }

    /// The indices `0..<count` sorted by `keyOf` (24-bit keys), ties in index
    /// order: two stable 12-bit counting passes, since a comparison sort of a
    /// nationwide set takes most of a second on a phone.
    static func sortedOrder(count: Int, keyOf: (Int) -> Int) -> [Int32] {
        let keys = (0..<count).map { UInt32(truncatingIfNeeded: keyOf($0)) & 0xffffff }
        var from = (0..<count).map { Int32($0) }
        var to = [Int32](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: 4096)
        for shift in [UInt32(0), 12] {
            for b in 0..<4096 { counts[b] = 0 }
            for i in 0..<count { counts[Int((keys[Int(from[i])] >> shift) & 4095)] += 1 }
            var sum = 0
            for b in 0..<4096 {
                let c = counts[b]
                counts[b] = sum
                sum += c
            }
            for i in 0..<count {
                let bucket = Int((keys[Int(from[i])] >> shift) & 4095)
                to[counts[bucket]] = from[i]
                counts[bucket] += 1
            }
            swap(&from, &to)
        }
        return from
    }

    /// The z12 cell of a point in Z-order (Morton), 24 bits: cells next to each
    /// other mostly get keys next to each other. The same key as js-sdk-core's
    /// `mortonCellKey` and android-sdk-core's `StorageOrder.mortonCellKey`.
    static func mortonCellKey(latitude: Double, longitude: Double) -> Int {
        let x = (longitude + 180) / 360
        let s = sin(min(85, max(-85, latitude)) * .pi / 180)
        let y = 0.5 - log((1 + s) / (1 - s)) / (4 * .pi)
        let cx = min(4095, max(0, Int(floor(x * 4096))))
        let cy = min(4095, max(0, Int(floor(y * 4096))))
        var key = 0
        for bit in 0..<12 {
            key |= ((cx >> bit) & 1) << (2 * bit) | ((cy >> bit) & 1) << (2 * bit + 1)
        }
        return key
    }

    func shape(at index: Int) -> ShapeTileRenderer.Shape? {
        let r = record(at: index)
        guard r.radius > 0 else { return nil }
        let geometry = CircleTilePainter.Geometry(
            latitude: r.latitude, longitude: r.longitude, radiusMeters: r.radius, geodesic: r.geodesic,
            x: r.x, y: r.y, northY: r.north, southY: r.south, westX: r.west, eastX: r.east
        )
        return ShapeTileRenderer.Shape(
            kind: .circle, rings: [], minX: r.west, minY: r.north, maxX: r.east, maxY: r.south,
            fill: r.fill == 0 ? nil : colors[Int(r.fill) - 1],
            stroke: r.stroke == 0 ? nil : colors[Int(r.stroke) - 1], strokeWidth: r.strokeWidth, circle: geometry
        )
    }

    func matches(_ state: CircleState, at index: Int) -> Bool {
        let r = record(at: index)
        let fill = state.fillColor.cgColor
        let stroke = state.strokeColor.cgColor
        return r.radius == state.radiusMeters && r.latitude == state.center.latitude
            && r.longitude == normalizeLngDegrees(state.center.longitude) && r.geodesic == state.geodesic
            && r.strokeWidth == state.strokeWidth
            && (r.fill == 0 ? fill.alpha == 0 : fill == colors[Int(r.fill) - 1])
            && (r.stroke == 0 ? stroke.alpha == 0 || r.strokeWidth <= 0 : stroke == colors[Int(r.stroke) - 1])
    }
}
