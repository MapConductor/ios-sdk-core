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
    public let extraIconScale: Double
    private let debugTileOverlay: Bool
    private let iconScaleCallback: ((MarkerState, Int) -> Double)?

    private let cacheLock = NSLock()
    private let cache: NSCache<NSNumber, NSData>
    private var cacheVersion: Int = 0

    /// Largest icon half-extent any tile has needed so far, in points.
    ///
    /// Seeds the padding used to widen a tile's marker query. `renderTile` can
    /// run concurrently and this is only a hint: a lost update costs one extra
    /// pass on one tile, which is the very thing it exists to avoid.
    private var observedHalfExtentPx: Double = 32.0

    private let defaultIcon: BitmapIcon

    public init(
        markerManager: MarkerManager<ActualMarker>,
        tileSize: Int = 256,
        extraIconScale: Double = 1.0,
        cacheSizeBytes: Int = 8 * 1024 * 1024,
        debugTileOverlay: Bool = false,
        iconScaleCallback: ((MarkerState, Int) -> Double)? = nil
    ) {
        self.markerManager = markerManager
        self.tileSize = tileSize
        self.extraIconScale = extraIconScale
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

    /// Returns the closest marker whose rendered icon bounds contain the screen point.
    public func hitTest(
        screenPoint: CGPoint,
        markerIds: Set<String>,
        zoom: Int,
        tolerance: CGFloat = 14,
        renderScaleToScreenScale: CGFloat = UIScreen.main.scale,
        unproject: (CGPoint) -> GeoPoint?,
        project: (GeoPoint) -> CGPoint?
    ) -> MarkerState? {
        // Android resolves one spatially indexed nearest marker before applying the
        // rendered-icon bounds check. Do the same here: iterating every tiled marker
        // made each tap O(n), including a projection and icon conversion per marker.
        guard let position = unproject(screenPoint),
              let entity = markerManager.findNearest(position: position),
              markerIds.contains(entity.state.id),
              entity.state.clickable,
              let markerPoint = project(entity.state.position) else { return nil }

        let icon = entity.state.icon?.toBitmapIcon() ?? defaultIcon
        let callbackScale = max(iconScaleCallback?(entity.state, zoom) ?? 1, 0)
        let scale = CGFloat(callbackScale * extraIconScale) / max(renderScaleToScreenScale, 1)
        let width = max(icon.size.width * scale, 1)
        let height = max(icon.size.height * scale, 1)
        let dx = screenPoint.x - markerPoint.x
        let dy = screenPoint.y - markerPoint.y
        let left = -icon.anchor.x * width - tolerance
        let right = (1 - icon.anchor.x) * width + tolerance
        let top = -icon.anchor.y * height - tolerance
        let bottom = (1 - icon.anchor.y) * height + tolerance

        guard dx >= left, dx <= right, dy >= top, dy <= bottom else { return nil }
        return entity.state
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

        // Starts at 32pt but widens to whatever a tile has actually needed.
        // Left fixed, the "conservative first pass" never pays off — real icons
        // are larger than the guess — and the query and prepare passes simply
        // run twice for every tile.
        let assumedHalfExtentPx: Double = observedHalfExtentPx
        var entities = queryByHalfExtentPx(assumedHalfExtentPx, bounds: bounds, tilePx: tilePx)

        if entities.isEmpty && !debugTileOverlay {
            return nil
        }

        var prepared = prepareMarkers(entities, tileX: tileXDouble, tileY: tileYDouble, zoom: z, tilePx: tilePx)

        // Second pass: re-query if actual icons are larger than assumed
        if prepared.maxHalfExtentPx > assumedHalfExtentPx + 1.0 {
            observedHalfExtentPx = prepared.maxHalfExtentPx
            entities = queryByHalfExtentPx(prepared.maxHalfExtentPx, bounds: bounds, tilePx: tilePx)
            prepared = prepareMarkers(entities, tileX: tileXDouble, tileY: tileYDouble, zoom: z, tilePx: tilePx)
        }

        let paddingPx = max(Int(ceil(prepared.maxHalfExtentPx + 2.0)), 2)

        // A bitmap context we own, not UIGraphicsImageRenderer.
        //
        // The renderer records the drawing and replays it when the image is
        // materialised, so its cost scales with the number of draw calls rather
        // than the size of the canvas: 20k blits into a 612px buffer measured
        // 534 ms through it against 58 ms into a plain bitmap context on an
        // iPad Pro. The renderer's own profile showed the same shape — the draw
        // loop reported 81 ms while the block containing it took 1739 ms.
        //
        // Owning the buffer also removes the crop pass and the copy the encoder
        // used to need: markers are drawn straight into a tile-sized canvas
        // that is translated by the padding, so anything overhanging the edge is
        // clipped where it used to be composited and then cut away.
        let bytesPerRow = tileSize * 4
        let pixels = NSMutableData(length: bytesPerRow * tileSize)!
        guard let context = CGContext(
            data: pixels.mutableBytes,
            width: tileSize,
            height: tileSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Core Graphics puts the origin at the bottom left and draws images
        // bottom-up; tile coordinates run top-down. Flipping here keeps every
        // destination rectangle below in tile coordinates.
        context.translateBy(x: 0, y: CGFloat(tileSize))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(-paddingPx), y: CGFloat(-paddingPx))
        context.interpolationQuality = .none

        if debugTileOverlay {
            let o = CGFloat(paddingPx)
            context.setStrokeColor(UIColor.red.cgColor)
            context.setLineWidth(1.0)
            context.move(to: CGPoint(x: o, y: o))
            context.addLine(to: CGPoint(x: o + CGFloat(tileSize), y: o))
            context.strokePath()
            context.move(to: CGPoint(x: o, y: o))
            context.addLine(to: CGPoint(x: o, y: o + CGFloat(tileSize)))
            context.strokePath()
        }

        for m in prepared.markers {
            guard let bitmap = m.bitmap.cgImage else { continue }
            let centerX = m.centerNormX * tilePx + Double(paddingPx)
            let centerY = m.centerNormY * tilePx + Double(paddingPx)
            let drawW = Double(m.drawW)
            let drawH = Double(m.drawH)
            let anchorX = Double(m.anchor.x)
            let anchorY = Double(m.anchor.y)
            // Whole pixels, deliberately. The destination comes out of a
            // projection, so it lands on a fraction of a pixel almost every
            // time, and drawing to a non-integer rectangle makes the context
            // resample every marker. The same change measured 20x on Android
            // and 7x in Chromium; rounding moves a pin by at most half a pixel,
            // which is not visible at icon scale.
            let left = (centerX - drawW * anchorX).rounded()
            let top = (centerY - drawH * anchorY).rounded()
            let width = max(1, drawW.rounded())
            let height = max(1, drawH.rounded())

            // Drawn upside down and flipped back, because the context's own
            // flip above would otherwise turn every icon over.
            context.saveGState()
            context.translateBy(x: left, y: top + height)
            context.scaleBy(x: 1, y: -1)
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }

        // The buffer is already what the encoder wants, so there is no image to
        // wrap it in and unwrap again.
        let pngData: Data
        if let encoded = TilePngEncoder.encode(
            rgba: pixels.mutableBytes, width: tileSize, height: tileSize, premultiplied: true
        ) {
            pngData = encoded
        } else if let image = context.makeImage().map({ UIImage(cgImage: $0) }),
                  let fallback = image.pngData() {
            pngData = fallback
        } else {
            return nil
        }

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
            // icon.size already includes MarkerIconProtocol.scale (baked into the
            // bitmap by toBitmapIcon), so it must not be applied again here.
            let scale = max(callbackScale, 0.0) * self.extraIconScale
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
        // タイルに描くのは「タイル担当」の entity だけ。
        //
        // 多くのプロバイダはコントローラの markerManager をそのままこのレンダラへ渡すため、
        // 絞らないとネイティブマーカーとして描いているもの（draggable / animation 付き）まで
        // PNG に焼かれ、同じ場所へ二重に出る。地図を回転させるとタイル側だけ傾くので、
        // ゴーストとして見える。
        //
        // longdo のようにタイル専用の manager を別に持つプロバイダでは全 entity が
        // tiling = true なので、この絞り込みは何もしない。
        return markerManager.findMarkersInBounds(expanded).filter { $0.tiling }
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
