import Foundation
import UIKit

public final class PolygonRasterTileRenderer: TileProvider {
    public let tileSize: Int

    private let lock = NSLock()
    private var _points: [GeoPointProtocol] = []
    private var _holes: [[GeoPointProtocol]] = []
    private var _fillColor: UIColor = .clear
    private var _geodesic: Bool = false

    public init(tileSize: Int = 256) {
        self.tileSize = tileSize
    }

    public func update(
        points: [GeoPointProtocol],
        holes: [[GeoPointProtocol]],
        fillColor: UIColor,
        geodesic: Bool
    ) {
        lock.lock()
        _points = points
        _holes = holes
        _fillColor = fillColor
        _geodesic = geodesic
        lock.unlock()
    }

    public func renderTile(request: TileRequest) -> Data? {
        lock.lock()
        let points = _points
        let holes = _holes
        let fillColor = _fillColor
        let geodesic = _geodesic
        lock.unlock()

        guard !points.isEmpty else { return emptyTileData }

        let z = request.z
        let worldTileCount = 1 << z
        let x = ((request.x % worldTileCount) + worldTileCount) % worldTileCount
        let y = request.y
        guard y >= 0 && y < worldTileCount else { return nil }

        let sz = tileSize
        guard let context = CGContext(
            data: nil,
            width: sz,
            height: sz,
            bitsPerComponent: 8,
            bytesPerRow: sz * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return emptyTileData }

        // CGContext origin is bottom-left; tile coordinates have origin at top-left.
        context.translateBy(x: 0, y: CGFloat(sz))
        context.scaleBy(x: 1, y: -1)

        let tileOriginX = Double(x * sz)
        let tileOriginY = Double(y * sz)

        func buildPath(for ring: [GeoPointProtocol]) -> CGPath {
            let path = CGMutablePath()
            let densified: [GeoPointProtocol] = geodesic ? createInterpolatePoints(ring) : ring
            for fragment in splitByMeridian(densified, geodesic: geodesic) {
                guard fragment.count >= 2 else { continue }
                var first = true
                for point in fragment {
                    let px = CGFloat(lonToPixelX(point.longitude, z: z) - tileOriginX)
                    let py = CGFloat(latToPixelY(point.latitude, z: z) - tileOriginY)
                    if first {
                        path.move(to: CGPoint(x: px, y: py))
                        first = false
                    } else {
                        path.addLine(to: CGPoint(x: px, y: py))
                    }
                }
                path.closeSubpath()
            }
            return path
        }

        // Fill outer ring
        context.setFillColor(fillColor.cgColor)
        context.addPath(buildPath(for: points))
        context.fillPath()

        // Clear each hole independently — overlapping holes all become transparent (union semantics)
        for holePoints in holes where !holePoints.isEmpty {
            context.setBlendMode(.clear)
            context.addPath(buildPath(for: holePoints))
            context.fillPath()
        }
        context.setBlendMode(.normal)

        guard let cgImage = context.makeImage() else { return emptyTileData }
        return UIImage(cgImage: cgImage).pngData() ?? emptyTileData
    }

    private func lonToPixelX(_ lon: Double, z: Int) -> Double {
        (lon + 180.0) / 360.0 * Double(tileSize * (1 << z))
    }

    private func latToPixelY(_ lat: Double, z: Int) -> Double {
        let siny = max(-0.9999, min(0.9999, sin(lat * .pi / 180.0)))
        return (0.5 - log((1.0 + siny) / (1.0 - siny)) / (4.0 * .pi)) * Double(tileSize * (1 << z))
    }

    private lazy var emptyTileData: Data = {
        let sz = tileSize
        guard let ctx = CGContext(
            data: nil, width: sz, height: sz, bitsPerComponent: 8, bytesPerRow: sz * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let img = ctx.makeImage() else { return Data() }
        return UIImage(cgImage: img).pngData() ?? Data()
    }()
}
