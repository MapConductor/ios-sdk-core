import Foundation

open class PolylineController<ActualPolyline, Renderer: PolylineOverlayRendererProtocol>: OverlayControllerProtocol, SlottedOverlayController
where Renderer.ActualPolyline == ActualPolyline {
    public typealias StateType = PolylineState
    public typealias EntityType = PolylineEntity<ActualPolyline>
    public typealias EventType = PolylineEvent

    public let polylineManager: PolylineManager<ActualPolyline>
    open var renderer: Renderer

    public let zIndex: Int = 5
    private let semaphore = AsyncSemaphore(1)

    /// Which overlays have reached the map, for their `onAdded`.
    @_spi(MapConductorDriver)
    public let addedTracker = OverlayAddedTracker()
    /// Written from the map's camera callbacks on the main thread and from
    /// `onCameraChanged`, which the overlay registry runs in a detached task.
    /// Two unguarded writes of a class reference release the old camera twice:
    /// with 100,000 polygons in tiles a pan ran fast enough to hit it, and the app
    /// crashed in the camera's release a few pans in.
    private let cameraLock = NSLock()
    private var cameraPositionValue: MapCameraPosition?
    private var currentCameraPosition: MapCameraPosition? {
        cameraLock.lock()
        defer { cameraLock.unlock() }
        return cameraPositionValue
    }

    public var clickListener: ((PolylineEvent) -> Void)?

    /// Set by a provider that can show polyline tiles (see ``PolylineTiler``).
    /// Polylines it tiles stay in ``polylineManager``, for taps, with no native
    /// overlay: their entity's `polyline` is nil and the renderer never sees them.
    @_spi(MapConductorDriver)
    public var tiler: PolylineTiler?
    private var tiledIds: Set<String> = []

    public init(
        polylineManager: PolylineManager<ActualPolyline>,
        renderer: Renderer,
        clickListener: ((PolylineEvent) -> Void)? = nil
    ) {
        self.polylineManager = polylineManager
        self.renderer = renderer
        self.clickListener = clickListener
    }

    public func dispatchClick(event: PolylineEvent) {
        // 配送座標の wrap は PolylineEvent の生成時に一元化済み。
        event.state.onClick?(event)
        clickListener?(event)
    }

    open func add(data: [PolylineState]) async {
        if polylineManager.isDestroyed { return }
        let landed: [PolylineState] = await semaphore.withPermit {
            if polylineManager.isDestroyed { return [] }
            // The app's list: anything it no longer has can be added again later.
            addedTracker.retain(Set(data.map(\.id)))
            var landed: [PolylineState] = []
            let wasTiled = tiledIds
            // `route` returns once the tile layer's URL template has been handed
            // to the map (the provider's `onTemplate` awaits its raster upsert).
            let tiled = await tiler?.route(data) ?? []
            if polylineManager.isDestroyed { return [] }
            tiledIds = tiled
            if !tiled.isEmpty, let tiler {
                // Tiled polylines are on the map now. Report them before the
                // bookkeeping below, as PolygonController does.
                await OverlayAddedTracker.notify(addedTracker.admit(tiler.tiledStates()))
            }
            let data = tiled.isEmpty ? data : data.filter { !tiled.contains($0.id) }
            // Only natively drawn polylines are diffed against the renderer.
            var previous = Set(
                polylineManager.allEntities()
                    .map { $0.state.id }
                    .filter { !wasTiled.contains($0) }
            )
            var added: [PolylineOverlayAddParams] = []
            var updated: [PolylineOverlayChangeParams<ActualPolyline>] = []
            var removed: [PolylineEntity<ActualPolyline>] = []

            for state in data {
                if previous.contains(state.id), let prevEntity = polylineManager.getEntity(state.id) {
                    if state.fingerPrint() == prevEntity.fingerPrint {
                        // 描画結果が不変なら renderer を呼ばず最新の state だけ採用する（react-sdk と同じ）。
                        polylineManager.registerEntity(PolylineEntity(polyline: prevEntity.polyline, state: state))
                        previous.remove(state.id)
                        continue
                    }
                    updated.append(
                        PolylineOverlayChangeParams(
                            current: PolylineEntity(polyline: prevEntity.polyline, state: state),
                            prev: prevEntity
                        )
                    )
                    previous.remove(state.id)
                } else {
                    added.append(PolylineOverlayAddParams(state: state))
                    previous.remove(state.id)
                }
            }

            for remainId in previous {
                if let removedEntity = polylineManager.removeEntity(remainId) {
                    removed.append(removedEntity)
                }
            }

            if !removed.isEmpty {
                await renderer.onRemove(data: removed)
                if polylineManager.isDestroyed { return [] }
            }

            if !added.isEmpty {
                let actualPolylines = await renderer.onAdd(data: added)
                if polylineManager.isDestroyed { return [] }
                for (index, polyline) in actualPolylines.enumerated() {
                    guard let polyline else { continue }
                    let entity = PolylineEntity(polyline: polyline, state: added[index].state)
                    polylineManager.registerEntity(entity)
                    landed.append(added[index].state)
                }
            }

            if !updated.isEmpty {
                let actualPolylines = await renderer.onChange(data: updated)
                if polylineManager.isDestroyed { return [] }
                for (index, polyline) in actualPolylines.enumerated() {
                    guard let polyline else { continue }
                    let params = updated[index]
                    let entity = PolylineEntity(polyline: polyline, state: params.current.state)
                    polylineManager.registerEntity(entity)
                }
            }

            // Tiled polylines: kept for taps, nothing native. Those that left the
            // tiles and the list are forgotten; those that left the tiles for
            // native drawing were added above.
            if !wasTiled.isEmpty {
                let nativeIds = Set(data.map(\.id))
                for id in wasTiled where !tiled.contains(id) && !nativeIds.contains(id) {
                    _ = polylineManager.removeEntity(id)
                }
            }
            if !tiled.isEmpty, let tiler {
                for state in tiler.tiledStates() {
                    polylineManager.registerEntity(PolylineEntity(polyline: nil, state: state))
                }
            }

            if polylineManager.isDestroyed { return [] }
            await renderer.onPostProcess()
            // A polyline that only moved from the tiles to native drawing is
            // still on the map: `admit` drops it.
            return addedTracker.admit(landed)
        }
        // After the renderer returned: the native objects exist on the map.
        await OverlayAddedTracker.notify(landed)
    }

    open func update(state: PolylineState) async {
        if polylineManager.isDestroyed { return }
        await semaphore.withPermit {
            guard let prevEntity = polylineManager.getEntity(state.id) else { return }
            if tiledIds.contains(state.id) {
                if PolylineTileSet.canTile(state) {
                    polylineManager.registerEntity(PolylineEntity(polyline: nil, state: state))
                    tiler?.update(state)
                    return
                }
                // No longer drawable in a tile (geodesic, half the world wide, or
                // under 2 points): the map SDK draws it from now on. Still on the
                // map, so this is not an add.
                tiledIds.remove(state.id)
                tiler?.remove(state.id)
                let polylines = await renderer.onAdd(data: [PolylineOverlayAddParams(state: state)])
                if polylineManager.isDestroyed { return }
                if polylines.count == 1, let actualPolyline = polylines[0] {
                    polylineManager.registerEntity(PolylineEntity(polyline: actualPolyline, state: state))
                } else {
                    _ = polylineManager.removeEntity(state.id)
                }
                await renderer.onPostProcess()
                return
            }
            let currentFinger = state.fingerPrint()
            let prevFinger = prevEntity.fingerPrint
            if currentFinger == prevFinger { return }

            let entity = PolylineEntity(polyline: prevEntity.polyline, state: state)
            let params = PolylineOverlayChangeParams(current: entity, prev: prevEntity)
            let polylines = await renderer.onChange(data: [params])
            if polylineManager.isDestroyed { return }

            if polylines.count == 1, let actualPolyline = polylines[0] {
                let updated = PolylineEntity(polyline: actualPolyline, state: state)
                polylineManager.registerEntity(updated)
            }

            if polylineManager.isDestroyed { return }
            await renderer.onPostProcess()
        }
    }

    open func clear() async {
        if polylineManager.isDestroyed { return }
        await semaphore.withPermit {
            addedTracker.reset()
            let tiled = tiledIds
            tiledIds = []
            await tiler?.clear()
            let entities = polylineManager.allEntities().filter { !tiled.contains($0.state.id) }
            await renderer.onRemove(data: entities)
            if polylineManager.isDestroyed { return }
            // manager を空にしてから onPostProcess を呼ぶ。GL 系の描画担当は remove では何もせず、
            // onPostProcess で manager の全部を描き直すので、逆の順だと clear() 後も地図に残る。
            polylineManager.clear()
            await renderer.onPostProcess()
        }
    }

    open func find(position: GeoPointProtocol) -> PolylineEntity<ActualPolyline>? {
        polylineManager.find(position: position, cameraPosition: currentCameraPosition)?.entity
    }

    public func findWithClosestPoint(position: GeoPointProtocol) -> PolylineHitResult<ActualPolyline>? {
        polylineManager.find(position: position, cameraPosition: currentCameraPosition)
    }

    public func setCurrentCameraPosition(_ cameraPosition: MapCameraPosition?) {
        cameraLock.lock()
        let previous = cameraPositionValue
        cameraPositionValue = cameraPosition
        cameraLock.unlock()
        // Released outside the lock.
        _ = previous
    }

    open func onCameraChanged(mapCameraPosition: MapCameraPosition) async {
        setCurrentCameraPosition(mapCameraPosition)
    }

    open func destroy() {
        tiler?.dispose()
        polylineManager.destroy()
    }
    // ── SlottedOverlayController ────────────────────────────────────────
    //
    // kind は**必須メンバ**。既定値を持たせると、宣言忘れがコンパイルを通ってしまい
    // カスケードとスロットから黙って漏れる（android-sdk で実際に踏んだ）。

    public var kind: OverlayKind { .polyline }

    public func hasId(_ id: String) -> Bool {
        polylineManager.hasEntity(id)
    }

    /// ポリラインだけ配送座標がタップ点ではない。**線上の最近傍点**を返す。
    /// 線の上をきっかりタップすることはないので、タップ点をそのまま返すと
    /// 線から外れた座標がアプリへ渡る。3 プラットフォーム共通の既存契約。
    public func resolveTap(position: GeoPointProtocol) -> OverlayHit? {
        guard let hit = findWithClosestPoint(position: position) else { return nil }
        return OverlayHit(kind: .polyline, clicked: hit.closestPoint) { [weak self] in
            self?.dispatchClick(event: PolylineEvent(state: hit.entity.state, clicked: hit.closestPoint))
        }
    }

}
