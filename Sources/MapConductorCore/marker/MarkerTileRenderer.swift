import Foundation
import UIKit

/// A tile renderer for markers that implements `TileProvider`.
///
/// Renders marker icons onto PNG tiles for use with a `LocalTileServer` + RasterLayer.
/// This enables SDK-agnostic marker rendering for large datasets without per-marker native overhead.
///
/// - Thread safety: `renderTile` may be called from multiple threads concurrently.
public final class MarkerTileRenderer<ActualMarker>: TileProvider {
    private let markerManager: MarkerManager<ActualMarker>
    public let tileSize: Int
    private let debugTileOverlay: Bool
    private let iconScaleCallback: ((MarkerState, Int) -> Double)?

    private let cacheLock = NSLock()
    private let cache: NSCache<NSNumber, NSData>
    private var cacheVersion: Int = 0

    private let defaultIcon: BitmapIcon

    public init(
        markerManager: MarkerManager<ActualMarker>,
        tileSize: Int = 256,
        cacheSizeBytes: Int = 8 * 1024 * 1024,
        debugTileOverlay: Bool = false,
        iconScaleCallback: ((MarkerState, Int) -> Double)? = nil
    ) {
        self.markerManager = markerManager
        self.tileSize = tileSize
        self.debugTileOverlay = debugTileOverlay
        self.iconScaleCallback = iconScaleCallback
        self.defaultIcon = DefaultMarkerIcon().toBitmapIcon()

        let cache = NSCache<NSNumber, NSData>()
        cache.totalCostLimit = cacheSizeBytes
        self.cache = cache
    }

    /// Invalidates all cached tiles. Call when marker data changes.
    public func invalidate() {
        cacheLock.lock()
        cacheVersion = (cacheVersion + 1) & 0x7fffffff
        cache.removeAllObjects()
        cacheLock.unlock()
    }

    /// Clears all cached tiles.
    public func clear() {
        cacheLock.lock()
        cacheVersion = (cacheVersion + 1) & 0x7fffffff
        cache.removeAllObjects()
        cacheLock.unlock()
    }

    public func renderTile(request: TileRequest) -> Data? {
        let z = request.z
        let worldTileCount = 1 << z
        guard request.y >= 0 && request.y < worldTileCount else { return nil }
        let normalizedX = normalizeTileX(request.x, worldTileCount: worldTileCount)
        let tileY = request.y

        cacheLock.lock()
        let versionSnapshot = cacheVersion
        cacheLock.unlock()

        let key = tileCacheKey(x: normalizedX, y: tileY, z: z, debug: debugTileOverlay,
                               version: versionSnapshot, tileSize: tileSize)
        cacheLock.lock()
        if let cached = cache.object(forKey: NSNumber(value: key)) {
            cacheLock.unlock()
            return cached as Data
        }
        cacheLock.unlock()

        let tileXDouble = Double(normalizedX)
        let tileYDouble = Double(tileY)
        let tilePx = Double(tileSize)

        // Compute geographic bounds of this tile
        let nw = tileToGeoPoint(x: tileXDouble, y: tileYDouble, z: Double(z))
        let se = tileToGeoPoint(x: tileXDouble + 1.0, y: tileYDouble + 1.0, z: Double(z))
        let bounds = GeoRectBounds(
            southWest: GeoPoint(latitude: se.latitude, longitude: nw.longitude),
            northEast: GeoPoint(latitude: nw.latitude, longitude: se.longitude)
        )

        // First pass: conservative 32pt padding to catch nearby icons
        let assumedHalfExtentPx: Double = 32.0
        var entities = queryByHalfExtentPx(assumedHalfExtentPx, bounds: bounds, tilePx: tilePx)

        if entities.isEmpty && !debugTileOverlay {
            return nil
        }

        var prepared = prepareMarkers(entities, tileX: tileXDouble, tileY: tileYDouble, zoom: z, tilePx: tilePx)

        // Second pass: re-query if actual icons are larger than assumed
        if prepared.maxHalfExtentPx > assumedHalfExtentPx + 1.0 {
            entities = queryByHalfExtentPx(prepared.maxHalfExtentPx, bounds: bounds, tilePx: tilePx)
            prepared = prepareMarkers(entities, tileX: tileXDouble, tileY: tileYDouble, zoom: z, tilePx: tilePx)
        }

        let paddingPx = max(Int(ceil(prepared.maxHalfExtentPx + 2.0)), 2)
        let offscreenSize = tileSize + paddingPx * 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        // Draw all markers into an offscreen canvas (tile + padding)
        let offscreenRenderer = UIGraphicsImageRenderer(
            size: CGSize(width: offscreenSize, height: offscreenSize),
            format: format
        )
        let offscreenImage = offscreenRenderer.image { ctx in
            if debugTileOverlay {
                let o = CGFloat(paddingPx)
                let cgCtx = ctx.cgContext
                cgCtx.setStrokeColor(UIColor.red.cgColor)
                cgCtx.setLineWidth(1.0)
                cgCtx.move(to: CGPoint(x: o, y: o))
                cgCtx.addLine(to: CGPoint(x: o + CGFloat(tileSize), y: o))
                cgCtx.strokePath()
                cgCtx.move(to: CGPoint(x: o, y: o))
                cgCtx.addLine(to: CGPoint(x: o, y: o + CGFloat(tileSize)))
                cgCtx.strokePath()
            }

            for m in prepared.markers {
                let centerX = m.centerNormX * tilePx + Double(paddingPx)
                let centerY = m.centerNormY * tilePx + Double(paddingPx)
                let drawW = Double(m.drawW)
                let drawH = Double(m.drawH)
                let anchorX = Double(m.anchor.x)
                let anchorY = Double(m.anchor.y)
                let destRect = CGRect(
                    x: centerX - drawW * anchorX,
                    y: centerY - drawH * anchorY,
                    width: drawW,
                    height: drawH
                )
                m.bitmap.draw(in: destRect)
            }
        }

        // Crop to tile bounds
        let finalRenderer = UIGraphicsImageRenderer(
            size: CGSize(width: tileSize, height: tileSize),
            format: format
        )
        let finalImage = finalRenderer.image { _ in
            offscreenImage.draw(at: CGPoint(x: -paddingPx, y: -paddingPx))
        }

        guard let pngData = finalImage.pngData() else { return nil }

        cacheLock.lock()
        if versionSnapshot == cacheVersion {
            cache.setObject(pngData as NSData, forKey: NSNumber(value: key), cost: pngData.count)
        }
        cacheLock.unlock()

        return pngData
    }

    // MARK: - Private

    private struct PreparedMarker {
        let bitmap: UIImage
        let centerNormX: Double
        let centerNormY: Double
        let drawW: CGFloat
        let drawH: CGFloat
        let anchor: CGPoint
    }

    private struct PreparedResult {
        let markers: [PreparedMarker]
        let maxHalfExtentPx: Double
    }

    private func prepareMarkers(
        _ entities: [MarkerEntity<ActualMarker>],
        tileX: Double,
        tileY: Double,
        zoom: Int,
        tilePx: Double
    ) -> PreparedResult {
        var maxHalfExtentPx: Double = 0.0
        var markers: [PreparedMarker] = []
        markers.reserveCapacity(entities.count)

        for entity in entities {
            let icon = (entity.state.icon?.toBitmapIcon() ?? defaultIcon)
            let pos = entity.state.position
            let tilePoint = geoToTilePoint(longitude: pos.longitude, latitude: pos.latitude, zoom: zoom)
            let centerNormX = tilePoint.x - tileX
            let centerNormY = tilePoint.y - tileY

            let callbackScale = max(iconScaleCallback?(entity.state, zoom) ?? 1.0, 0.0)
            let scale = max((Double(icon.scale)) * callbackScale, 0.0)
            let drawW = max(Double(icon.size.width) * scale, 1.0)
            let drawH = max(Double(icon.size.height) * scale, 1.0)

            let anchorX = Double(icon.anchor.x)
            let anchorY = Double(icon.anchor.y)
            let halfX = max(abs(drawW * anchorX), abs(drawW * (1.0 - anchorX)))
            let halfY = max(abs(drawH * anchorY), abs(drawH * (1.0 - anchorY)))
            maxHalfExtentPx = max(maxHalfExtentPx, max(halfX, halfY))

            markers.append(PreparedMarker(
                bitmap: icon.bitmap,
                centerNormX: centerNormX,
                centerNormY: centerNormY,
                drawW: CGFloat(drawW),
                drawH: CGFloat(drawH),
                anchor: icon.anchor
            ))
        }

        return PreparedResult(markers: markers, maxHalfExtentPx: maxHalfExtentPx)
    }

    private func queryByHalfExtentPx(
        _ halfExtentPx: Double,
        bounds: GeoRectBounds,
        tilePx: Double
    ) -> [MarkerEntity<ActualMarker>] {
        guard let span = bounds.toSpan() else { return [] }
        let padNorm = max(halfExtentPx / tilePx, 0.0)
        let latPad = span.latitude * padNorm
        let lonPad = span.longitude * padNorm
        let expanded = bounds.expandedByDegrees(latPad: latPad, lonPad: lonPad)
        return markerManager.findMarkersInBounds(expanded)
    }

    private func tileToGeoPoint(x: Double, y: Double, z: Double) -> GeoPoint {
        let n = pow(2.0, z)
        let lonDeg = (x / n) * 360.0 - 180.0
        let latRad = atan(sinh(.pi * (1.0 - 2.0 * (y / n))))
        let latDeg = latRad * 180.0 / .pi
        return GeoPoint(latitude: latDeg, longitude: lonDeg)
    }

    private func geoToTilePoint(longitude: Double, latitude: Double, zoom: Int) -> (x: Double, y: Double) {
        let n = pow(2.0, Double(zoom))
        let lonWrapped = ((longitude + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0) - 180.0
        let x0 = ((lonWrapped + 180.0) / 360.0) * n
        let x = ((x0.truncatingRemainder(dividingBy: n)) + n).truncatingRemainder(dividingBy: n)
        let latClamped = min(max(latitude, -maxMercatorLat), maxMercatorLat)
        let latRad = latClamped * .pi / 180.0
        let y = (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n
        return (x: x, y: min(max(y, 0.0), n - 1e-9))
    }

    private func normalizeTileX(_ x: Int, worldTileCount: Int) -> Int {
        let wrapped = x % worldTileCount
        return wrapped < 0 ? wrapped + worldTileCount : wrapped
    }

    private func tileCacheKey(x: Int, y: Int, z: Int, debug: Bool, version: Int, tileSize: Int) -> Int64 {
        let version7 = Int64(version & 0x7f)
        let debug1: Int64 = debug ? 1 : 0
        let tileSize11 = Int64(tileSize & 0x7ff)
        if z >= 0 && z <= 24 && x >= 0 && x < (1 << 24) && y >= 0 && y < (1 << 24) {
            return (Int64(y) & 0xffffff)
                | ((Int64(x) & 0xffffff) << 24)
                | ((Int64(z) & 0x3f) << 48)
                | (debug1 << 54)
                | (tileSize11 << 55)
                | (version7 << 58)
        }
        var k = (Int64(x) << 32) ^ (Int64(y) & 0xffffffff)
        k ^= Int64(z) << 16
        k ^= debug1 << 1
        k ^= tileSize11 << 2
        k ^= version7 << 13
        return mixKey(k)
    }

    private func mixKey(_ key: Int64) -> Int64 {
        var k = key
        k ^= k >> 33
        k = k &* Int64(bitPattern: 0xff51afd7ed558ccd)
        k ^= k >> 33
        k = k &* Int64(bitPattern: 0xc4ceb9fe1a85ec53)
        k ^= k >> 33
        return k
    }

    private let maxMercatorLat: Double = 85.05112878
}
