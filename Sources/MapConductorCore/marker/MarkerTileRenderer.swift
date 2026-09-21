import Foundation
import UIKit
/// タイル 1 枚の時間の行き先を出すかどうか。
///
/// 既定は環境変数 `MC_MARKER_PHASES`。ただし `xcodebuild test` はシェルの環境を
/// テストプロセスへ渡さないので、計測からは直接立てる。
///
/// `MarkerTileRenderer` はジェネリックなので static の格納プロパティを持てず、
/// ここに置いてある。
public enum MarkerTilePhaseTrace {
    public static var enabled = ProcessInfo.processInfo.environment["MC_MARKER_PHASES"] != nil
}


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
    /// Keep one marker per cell of this many pixels, or 0 to keep them all.
    private let declutterPx: Int
    private var gpuCached: MetalMarkerRasterizer?
    private var gpuResolved = false
    private let gpuLock = NSLock()

    private let cacheLock = NSLock()
    private let cache: NSCache<NSNumber, NSData>
    private var cacheVersion: Int = 0

    /// Largest icon half-extent any tile has needed so far, in points.
    ///
    /// Seeds the padding used to widen a tile's marker query. Starts from the
    /// default icon's own extent rather than a guess: the guess was 32pt, real
    /// icons are larger, and every tile therefore paid a second query and a
    /// second prepare — 102 ms of a 261 ms tile at z6 with 20k markers.
    ///
    /// `renderTile` can run concurrently and this is only a hint: a lost update
    /// costs one extra pass on one tile, which is the very thing it avoids.
    private var observedHalfExtentPx: Double

    private let defaultIcon: BitmapIcon

    public init(
        markerManager: MarkerManager<ActualMarker>,
        tileSize: Int = 256,
        extraIconScale: Double = 1.0,
        cacheSizeBytes: Int = 8 * 1024 * 1024,
        debugTileOverlay: Bool = false,
        iconScaleCallback: ((MarkerState, Int) -> Double)? = nil,
        declutterPx: Int = 0
    ) {
        self.markerManager = markerManager
        self.tileSize = tileSize
        self.extraIconScale = extraIconScale
        self.debugTileOverlay = debugTileOverlay
        self.iconScaleCallback = iconScaleCallback
        self.declutterPx = declutterPx
        let icon = DefaultMarkerIcon().toBitmapIcon()
        self.defaultIcon = icon
        let anchorX = Double(icon.anchor.x)
        let anchorY = Double(icon.anchor.y)
        let width = Double(icon.size.width) * extraIconScale
        let height = Double(icon.size.height) * extraIconScale
        self.observedHalfExtentPx = max(
            max(abs(width * anchorX), abs(width * (1.0 - anchorX))),
            max(abs(height * anchorY), abs(height * (1.0 - anchorY)))
        )

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

    /// タイル 1 枚の時間の行き先を出す。`MC_MARKER_PHASES` が立っているときだけ。
    ///
    /// android-vectortile の `MARKERTILE_PHASES` に対応する。合計だけ見ていると
    /// 「問い合わせが重いのか、描くのが重いのか」が分からず、打ち手を選べない。
    /// 実測（iPad Pro 11、ズーム 11、17,937 件）では合計 143ms のうち
    /// 問い合わせが 29ms で、残り 115ms が準備と描画だった。
    private static var tracePhases: Bool { MarkerTilePhaseTrace.enabled }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func since(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// 「マネージャにはマーカーがあるのに、このタイルの問い合わせは空」が
    /// 起きた瞬間に呼ばれる。
    ///
    /// この組み合わせは、本当に何も無い場所（皇居の堀の中）でも起きるので
    /// 即エラーではない。が、取り込みや更新の途中に重なった空振りだと、
    /// 描いた透明タイルが地図 SDK のセッションキャッシュに残り、霞が関に
    /// 四角い穴が空いたまま再要求されない -- 実機で起きた形。受け側
    /// （プロバイダ）はこれを合図に、少し置いてタイルキャッシュを捨てて
    /// 引き直させる。正しく空だった場所は引き直しても透明のままなので、
    /// 副作用は再描画 1 回で済む。
    public var onEmptyTileWhilePopulated: ((TileRequest) -> Void)?

    /// 同じタイルの問い合わせだけをやり直し、**今も**空かを返す。
    ///
    /// `onEmptyTileWhilePopulated` の受け側が使う。空タイルには 2 種類ある:
    /// 本当に何も無い場所（何度聞いても空）と、取り込みや更新の途中に重なった
    /// 空振り（少し置いて聞き直すとマーカーが居る）。前者でキャッシュを
    /// 捨てると全タイルの引き直しがループするので、後者だけを見分ける。
    public func tileStillEmpty(request: TileRequest) -> Bool {
        let z = request.z
        let worldTileCount = 1 << z
        guard request.y >= 0 && request.y < worldTileCount else { return true }
        let normalizedX = normalizeTileX(request.x, worldTileCount: worldTileCount)
        let nw = tileToGeoPoint(x: Double(normalizedX), y: Double(request.y), z: Double(z))
        let se = tileToGeoPoint(x: Double(normalizedX) + 1.0, y: Double(request.y) + 1.0, z: Double(z))
        let bounds = GeoRectBounds(
            southWest: GeoPoint(latitude: se.latitude, longitude: nw.longitude),
            northEast: GeoPoint(latitude: nw.latitude, longitude: se.longitude)
        )
        return queryByHalfExtentPx(observedHalfExtentPx, bounds: bounds, tilePx: Double(tileSize))
            .isEmpty
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
        let phaseStart = Self.tracePhases ? Self.now() : 0
        var entities = queryByHalfExtentPx(assumedHalfExtentPx, bounds: bounds, tilePx: tilePx)
        var queryMs = Self.tracePhases ? Self.since(phaseStart) : 0
        var passes = 1

        if entities.isEmpty && !debugTileOverlay {
            if let hook = onEmptyTileWhilePopulated, markerManager.getMemoryStats().entityCount > 0 {
                hook(request)
            }
            /*
             空のタイルは nil ではなく透明な PNG。

             nil はサーバで 404 になり、地図 SDK は「このタイルは存在しない」と
             覚えて二度と要求しない。マーカーの空タイルは**今**空なだけで、
             データの取り込み中・ネイティブ⇄タイルの切り替え中に一瞬だけ空に
             なることがある。その一瞬の 404 が恒久の穴になり、隣のタイルが
             はみ出し分だけ描くので、穴の縁でアイコンが半分に切れて見える --
             後楽園で実際に起きた形。

             透明タイルは 1 度だけ作って使い回す。数百バイトで、キャッシュ側の
             負担にはならない。本当にマーカーの無い場所も透明が正しい絵で、
             あとからそこにマーカーが現れたときはデータ変更がタイル URL の
             version を進めるので、古い透明が残ることもない。
             */
            return Self.transparentTile(size: tileSize)
        }

        let prepareStart = Self.tracePhases ? Self.now() : 0
        var prepared = prepareMarkers(entities, tileX: tileXDouble, tileY: tileYDouble, zoom: z, tilePx: tilePx)
        var prepareMs = Self.tracePhases ? Self.since(prepareStart) : 0

        // Second pass: re-query if actual icons are larger than assumed
        if prepared.maxHalfExtentPx > assumedHalfExtentPx + 1.0 {
            passes = 2
            observedHalfExtentPx = prepared.maxHalfExtentPx
            let requeryStart = Self.tracePhases ? Self.now() : 0
            entities = queryByHalfExtentPx(prepared.maxHalfExtentPx, bounds: bounds, tilePx: tilePx)
            if Self.tracePhases { queryMs += Self.since(requeryStart) }
            let reprepareStart = Self.tracePhases ? Self.now() : 0
            prepared = prepareMarkers(entities, tileX: tileXDouble, tileY: tileYDouble, zoom: z, tilePx: tilePx)
            if Self.tracePhases { prepareMs += Self.since(reprepareStart) }
        }
        let drawStart = Self.tracePhases ? Self.now() : 0

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
            // 上と左の線。タイルが敷き詰められれば格子として読める。
            let o = CGFloat(paddingPx)
            // 目立たせない。この格子は「どのタイルか」を読むための定規で、
            // 主役はマーカーの絵のほう。赤だと視線がそちらに奪われる。
            context.setStrokeColor(UIColor.gray.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(1.0)
            context.move(to: CGPoint(x: o, y: o))
            context.addLine(to: CGPoint(x: o + CGFloat(tileSize), y: o))
            context.strokePath()
            context.move(to: CGPoint(x: o, y: o))
            context.addLine(to: CGPoint(x: o, y: o + CGFloat(tileSize)))
            context.strokePath()

            // タイル番号。android-sdk のデバッグ描画と同じ内容で、継ぎ目の
            // 不具合報告を「どの 2 枚の間か」まで特定できるようにする。
            // flip 済みの context は UIKit と同じ向きなので、そのまま文字が描ける。
            UIGraphicsPushContext(context)
            let text = "x/y/z=\(normalizedX)/\(tileY)/\(z), entries=\(entities.count)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor.gray.withAlphaComponent(0.8),
            ]
            let shadow: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.8),
            ]
            let at = CGPoint(x: o + 10, y: o + 8)
            (text as NSString).draw(at: CGPoint(x: at.x + 1, y: at.y + 1), withAttributes: shadow)
            (text as NSString).draw(at: at, withAttributes: attributes)
            UIGraphicsPopContext()
        }

        // The cell the tile's own corner falls in. Subtracting it keeps the
        // group numbers small without moving the grid: two tiles still agree
        // about which markers share a cell, which is the only thing the
        // grouping is asked for. android-sdk needs the small numbers — it packs
        // the group and an index into one Long — and the three stay identical.
        let cellPx = Double(max(declutterPx, 1))
        let baseCellX = floor(tileXDouble * tilePx / cellPx)
        let baseCellY = floor(tileYDouble * tilePx / cellPx)

        var placements = [MarkerPlacement?](repeating: nil, count: prepared.markers.count)
        var groups = [MarkerPlacement?](repeating: nil, count: prepared.markers.count)
        var images = [CGImage?](repeating: nil, count: prepared.markers.count)
        var worldKeys = [Double](repeating: 0, count: prepared.markers.count)
        for (index, m) in prepared.markers.enumerated() {
            guard let bitmap = m.bitmap.cgImage else { continue }
            let centerX = m.centerNormX * tilePx + Double(paddingPx)
            let centerY = m.centerNormY * tilePx + Double(paddingPx)
            let drawW = Double(m.drawW)
            let drawH = Double(m.drawH)
            // Whole pixels, deliberately. The destination comes out of a
            // projection, so it lands on a fraction of a pixel almost every
            // time, and drawing to a non-integer rectangle makes the context
            // resample every marker. The same change measured 20x on Android
            // and 7x in Chromium; rounding moves a pin by at most half a pixel,
            // which is not visible at icon scale.
            images[index] = bitmap
            let anchorX: Double = Double(m.anchor.x)
            let anchorY: Double = Double(m.anchor.y)
            let left: Double = (centerX - drawW * anchorX).rounded()
            let top: Double = (centerY - drawH * anchorY).rounded()
            let width: Double = max(1.0, drawW.rounded())
            let height: Double = max(1.0, drawH.rounded())
            placements[index] = MarkerPlacement(
                left: Int(left),
                top: Int(top),
                width: Int(width),
                height: Int(height),
                icon: ObjectIdentifier(m.bitmap)
            )
            // The declutter cell is anchored to the world, not to this tile.
            //
            // `centerNormX` is the position within this tile, so a cell keyed
            // off it moves with the tile: the same ground lands in a different
            // cell on the tile next door, the two tiles keep different markers,
            // and a marker drawn on one and dropped on the other is **cut at
            // the seam.** Adding the tile's own coordinate back gives the world
            // tile coordinate the projection produced, which is the same number
            // whichever tile is asking.
            let worldX = (m.centerNormX + tileXDouble) * tilePx
            let worldY = (m.centerNormY + tileYDouble) * tilePx
            groups[index] = Self.declutterGroup(
                declutterPx: declutterPx,
                worldX: worldX,
                worldY: worldY,
                baseX: baseCellX,
                baseY: baseCellY,
                placement: placements[index]!
            )
            // セルの勝者を決める正準キー。下の間引きループの説明を参照。
            worldKeys[index] = worldY * 1_048_576.0 + worldX
        }

        // Drop markers that are completely hidden by a later one.
        //
        // Zoom out far enough and a whole city collapses onto a few hundred
        // pixels: at z6 a dataset of 20k markers resolves to roughly 2k
        // distinct positions, and the other 18k are drawn underneath copies of
        // themselves. Keeping the last of each group is what would have been
        // visible anyway, since drawing is in painter's order.
        //
        // Only exact agreement counts — same rectangle, same icon — so nothing
        // that could peek out from behind another is dropped. Two identical
        // icons stacked do differ from one where the icon's own edges are
        // partly transparent, by a fraction of a level; that difference is
        // overdraw rather than intent.
        // With decluttering on the group is a cell rather than a rectangle, and
        // the icon is not part of it: the caller has said markers that close
        // together are interchangeable, so one of them stands for the rest
        // whatever they draw.
        //
        // 間引きの勝者は「列挙順で最後」では決めない。列挙順は index のセルを
        // 歩く順で、それは**タイルごとに違う**。同じ間引きセルを共有する隣の
        // タイルが別の順で歩けば別の勝者を選び、境界では 2 本の木が半分ずつ
        // 縫い合わさる -- 赤と茶が 1 つの丸に重なって見えたのがこれ。勝者は
        // 世界座標のキー（worldY 優先、次に worldX、同座標はアイコンの識別子）
        // だけから決める。どちらのタイルが聞いても同じ答えになる。
        // 間引きが無いときは今まで通り「最後」でよい: グループは同一矩形 +
        // 同一アイコンなので、どれを描いても絵は変わらない。
        var lastAt: [MarkerPlacement: Int] = [:]
        lastAt.reserveCapacity(placements.count)
        if declutterPx > 0 {
            for (index, group) in groups.enumerated() {
                guard let group else { continue }
                if let current = lastAt[group] {
                    let a = worldKeys[index]
                    let b = worldKeys[current]
                    let iconA = UInt(bitPattern: placements[index]!.icon.hashValue)
                    let iconB = UInt(bitPattern: placements[current]!.icon.hashValue)
                    if a > b || (a == b && iconA > iconB) {
                        lastAt[group] = index
                    }
                } else {
                    lastAt[group] = index
                }
            }
        } else {
            for (index, group) in groups.enumerated() {
                if let group { lastAt[group] = index }
            }
        }

        // 残すものだけ先に集める。GPU 経路はこれをそのままインスタンスにする。
        var kept: [(placement: MarkerPlacement, bitmap: CGImage)] = []
        kept.reserveCapacity(lastAt.count)
        for (index, placement) in placements.enumerated() {
            guard let placement, let group = groups[index], let bitmap = images[index] else { continue }
            guard lastAt[group] == index else { continue }
            kept.append((placement, bitmap))
        }

        // GPU で描けたらそれを使う。描けなければ下の CPU 経路へ落ちる --
        // Metal が無い端末、アトラスに収まらない絵、パイプラインを拒む環境。
        if !debugTileOverlay,
           let gpu = gpuRasterizer(),
           let png = Self.renderOnGpu(gpu, kept: kept, paddingPx: paddingPx) {
            if Self.tracePhases {
                print(String(format: "MARKERTILE_PHASES z=%d markers=%d passes=%d query=%.1fms prepare=%.1fms gpuDraw=%.1fms",
                             z, prepared.markers.count, passes, queryMs, prepareMs, Self.since(drawStart)))
            }
            cacheLock.lock()
            if versionSnapshot == cacheVersion {
                cache.setObject(png as NSData, forKey: NSNumber(value: key), cost: png.count)
            }
            cacheLock.unlock()
            return png
        }

        for (placement, bitmap) in kept {

            // Drawn upside down and flipped back, because the context's own
            // flip above would otherwise turn every icon over.
            context.saveGState()
            context.translateBy(x: CGFloat(placement.left),
                                y: CGFloat(placement.top + placement.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(bitmap, in: CGRect(x: 0, y: 0,
                                            width: CGFloat(placement.width),
                                            height: CGFloat(placement.height)))
            context.restoreGState()
        }

        let drawMs = Self.tracePhases ? Self.since(drawStart) : 0
        let encodeStart = Self.tracePhases ? Self.now() : 0

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

        if Self.tracePhases {
            let encodeMs = Self.since(encodeStart)
            print(String(
                format: "MARKERTILE_PHASES z=%d markers=%d passes=%d query=%.1fms prepare=%.1fms draw=%.1fms encode=%.1fms",
                z, prepared.markers.count, passes, queryMs, prepareMs, drawMs, encodeMs))
        }

        cacheLock.lock()
        if versionSnapshot == cacheVersion {
            cache.setObject(pngData as NSData, forKey: NSNumber(value: key), cost: pngData.count)
        }
        cacheLock.unlock()

        return pngData
    }

    // MARK: - Private

    private static func transparentTile(size: Int) -> Data? {
        TransparentTileCache.tile(size: size)
    }

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

    /// GPU ラスタライザ。最初に要求されたときだけ作る。
    ///
    /// Metal が無ければ以後 nil を返し続ける。毎タイル試して毎回失敗するのは
    /// 無駄なので、結果を覚える。
    private func gpuRasterizer() -> MetalMarkerRasterizer? {
        gpuLock.lock()
        defer { gpuLock.unlock() }
        if gpuResolved { return gpuCached }
        gpuResolved = true
        /*
         既定は GPU。`MAPCONDUCTOR_MARKER_TILE_CPU=1` で切り分け用に CPU へ
         落とせる。

         一時期 GPU を既定から外していた。アトラスの UV が CGContext の
         下原点を考慮しておらず 1 行反転ぶん別のアイコンを指し、実機で
         「タイル右端のマーカーが消える」「1 つの丸に 2 色」という継ぎ目の
         割れになっていたため（詳細は MetalMarkerRasterizer.makeAtlas）。
         根治後、`MetalMarkerRasterizerTests`（単体）と
         `DeviceSeamReproBench`（実機の GPU/CPU 突き合わせ）が回帰網。
         */
        if ProcessInfo.processInfo.environment["MAPCONDUCTOR_MARKER_TILE_CPU"] == "1" {
            return nil
        }
        gpuCached = MetalMarkerRasterizer.createOrNull(tileSize: tileSize)
        return gpuCached
    }

    /// 残ったマーカーをインスタンスにして GPU へ渡す。
    ///
    /// 絵は種類が少ない（街路樹サンプルで 101 種）。同じ `CGImage` を指している
    /// ものをまとめてアトラスへ詰め、インスタンスごとには矩形と UV だけ渡す。
    private static func renderOnGpu(
        _ gpu: MetalMarkerRasterizer,
        kept: [(placement: MarkerPlacement, bitmap: CGImage)],
        paddingPx: Int
    ) -> Data? {
        guard !kept.isEmpty else { return nil }
        let atlasStart = tracePhases ? now() : 0

        var uniqueImages: [CGImage] = []
        var slotOf: [ObjectIdentifier: Int] = [:]
        var slots: [Int] = []
        slots.reserveCapacity(kept.count)
        for entry in kept {
            let identity = ObjectIdentifier(entry.bitmap)
            if let slot = slotOf[identity] {
                slots.append(slot)
            } else {
                let slot = uniqueImages.count
                slotOf[identity] = slot
                uniqueImages.append(entry.bitmap)
                slots.append(slot)
            }
        }

        guard let atlas = gpu.makeAtlas(uniqueImages) else { return nil }

        var instances: [MetalMarkerRasterizer.Instance] = []
        instances.reserveCapacity(kept.count)
        for (at, entry) in kept.enumerated() {
            let uv = atlas.uv[slots[at]]
            instances.append(MetalMarkerRasterizer.Instance(
                left: Float(entry.placement.left),
                top: Float(entry.placement.top),
                width: Float(entry.placement.width),
                height: Float(entry.placement.height),
                u0: Float(uv.minX), v0: Float(uv.minY),
                u1: Float(uv.maxX), v1: Float(uv.maxY)
            ))
        }
        // アトラスと描画を分けて出す。合わせて "gpuDraw" だが、中身は
        // マーカーの数に比例する部分（残ったぶんを並べる）と、しない部分
        // （テクスチャを作る・読み戻す・PNG にする）に割れている。どちらを
        // 削るかで打ち手が違う。
        let atlasMs = tracePhases ? since(atlasStart) : 0
        let drawStart = tracePhases ? now() : 0
        let png = gpu.renderPng(instances: instances, atlas: atlas.texture, paddingPx: paddingPx)
        if tracePhases {
            print(String(format: "MARKERTILE_GPU kept=%d icons=%d atlas=%.1fms drawEncode=%.1fms",
                         kept.count, uniqueImages.count, atlasMs, since(drawStart)))
        }
        return png
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
        // A whole declutter cell beyond the icon overhang.
        //
        // The overhang alone is enough to draw the tile, but not enough to
        // decide it: a declutter cell straddling the edge would have some of
        // its markers inside the query and some outside, and the tile next door
        // would see a different part of the same cell. Both would keep a marker
        // and the two would not be the same one, which is an icon cut at the
        // seam. Growing by the cell as well means every cell that reaches this
        // tile is here in full, so both tiles see all of it and agree.
        let padNorm = max((halfExtentPx + Double(declutterPx)) / tilePx, 0.0)
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
        // declutter が効いているときは index の段階で間引く。
        //
        // 呼び出し側が「これより近いマーカーは入れ替え可能」と言っているので、
        // index は自分のセルから答えてよい。zoom 9 なら東京の街路樹 144,183 本
        // ではなく、それを含む 5,000 セルほどを読むだけで済む。
        //
        // ここを飛ばして後段の辞書で間引いていたときは、捨てるぶんの配置と
        // 画像まで先に作っていたので、declutter を入れるほど遅くなっていた
        // （20,000 マーカーで 82.8ms -> 178.5ms）。index が粗すぎて分離を
        // 保証できない場合は全件クエリに落ちるので、後段の間引きは残してある。
        let separationDegrees = declutterPx > 0
            ? max(span.latitude, span.longitude) * Double(declutterPx) / tilePx
            : 0.0
        let found = separationDegrees > 0.0
            ? markerManager.findMarkersInBounds(expanded, minSeparationDegrees: separationDegrees)
            : markerManager.findMarkersInBounds(expanded)
        return found.filter { $0.tiling }
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

/// Where a marker is drawn, and which icon it draws.
///
/// Markers that agree on all of it sit exactly on top of one another, so all
/// but the last are invisible.
extension MarkerTileRenderer {
    /// What counts as "the same place" for the pass that drops hidden markers.
    /// What a marker is grouped by when deciding which ones to drop.
    ///
    /// Without decluttering that is the placement itself — same rectangle, same
    /// icon — so only markers drawn exactly on top of each other collapse.
    ///
    /// With decluttering it is a cell of `declutterPx`, taken in **world**
    /// pixels at this zoom rather than tile pixels, and the icon is not part of
    /// it: the caller has said markers that close together are interchangeable,
    /// so one of them stands for the rest whatever they draw. The world anchor
    /// is what makes two tiles agree about which one that is.
    fileprivate static func declutterGroup(
        declutterPx: Int,
        worldX: Double,
        worldY: Double,
        baseX: Double,
        baseY: Double,
        placement: MarkerPlacement
    ) -> MarkerPlacement {
        guard declutterPx > 0 else { return placement }
        let cell = Double(declutterPx)
        return MarkerPlacement(
            left: Int(floor(worldX / cell) - baseX),
            top: Int(floor(worldY / cell) - baseY),
            width: 0,
            height: 0,
            icon: MarkerPlacement.anyIcon
        )
    }
}

private struct MarkerPlacement: Hashable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let icon: ObjectIdentifier

    /// Stands in for "any icon" when the group is a cell rather than a
    /// rectangle. A cell holds whatever it holds.
    static let anyIcon = ObjectIdentifier(AnyIconMarker.self)

    private final class AnyIconMarker {}
}

/// 透明タイルの置き場。`MarkerTileRenderer` はジェネリックで static stored
/// property を持てないため、ここに出してある（`MarkerTilePhaseTrace` と同じ理由）。
private enum TransparentTileCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: Data] = [:]

    static func tile(size: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[size] { return cached }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let png = pixels.withUnsafeMutableBytes { raw -> Data? in
            guard let base = raw.baseAddress else { return nil }
            return TilePngEncoder.encode(rgba: base, width: size, height: size, premultiplied: true)
        }
        cache[size] = png
        return png
    }
}
