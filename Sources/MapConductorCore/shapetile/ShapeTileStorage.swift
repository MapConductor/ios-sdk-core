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
        if let replacement = try? CircleGeometryFile(count: count, shapeAt: { snapshot[$0] }) {
            self = ShapeTileStorage(replacement)
            active = snapshot.active
        }
    }

    func matches(_ state: CircleState, at index: Int) -> Bool {
        guard let file, overrides[index] == nil else { return false }
        return file.matches(state, at: index)
    }
}

/// Fixed-width geometry streamed to an anonymous cache file and paged by the OS.
/// The mapping is reclaimed when the last render snapshot releases it.
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
    private let mapping: UnsafeMutableRawPointer
    private let colors: [CGColor]

    init(count: Int, shapeAt: (Int) -> ShapeTileRenderer.Shape?) throws {
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
                    if let p = shapeAt(start + i), let c = p.circle {
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
        self.mapping = mapped
        self.colors = palette
    }

    deinit { munmap(mapping, count * Self.stride) }

    func record(at index: Int) -> Record {
        mapping.load(fromByteOffset: index * Self.stride, as: Record.self)
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
