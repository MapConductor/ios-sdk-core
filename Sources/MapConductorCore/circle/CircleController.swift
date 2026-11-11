import Foundation

open class CircleController<ActualCircle, Renderer: CircleOverlayRendererProtocol>: OverlayControllerProtocol, SlottedOverlayController
where Renderer.ActualCircle == ActualCircle {
    public typealias StateType = CircleState
    public typealias EntityType = CircleEntity<ActualCircle>
    public typealias EventType = CircleEvent

    public let circleManager: CircleManager<ActualCircle>
    open var renderer: Renderer

    public let zIndex: Int = 3
    private let semaphore = AsyncSemaphore(1)

    /// Which overlays have reached the map, for their `onAdded`.
    @_spi(MapConductorDriver)
    public let addedTracker = OverlayAddedTracker()

    /// Written from the map's camera callbacks and from `onCameraChanged`; guarded
    /// as ``PolylineController`` guards its own (two unguarded writes of a class
    /// reference release the old camera twice).
    private let cameraLock = NSLock()
    private var cameraPositionValue: MapCameraPosition?
    private var currentCameraPosition: MapCameraPosition? {
        cameraLock.lock()
        defer { cameraLock.unlock() }
        return cameraPositionValue
    }

    public var clickListener: ((CircleEvent) -> Void)?

    /// Set by a provider that can show circle tiles (see ``CircleTiler``).
    /// Circles it tiles stay in ``circleManager``, for taps, with no native
    /// overlay: their entity's `circle` is nil, and a renderer that redraws from
    /// the manager must skip such entities.
    @_spi(MapConductorDriver)
    public var tiler: CircleTiler?
    private var tiledIds: Set<String> = []

    public init(
        circleManager: CircleManager<ActualCircle>,
        renderer: Renderer,
        clickListener: ((CircleEvent) -> Void)? = nil
    ) {
        self.circleManager = circleManager
        self.renderer = renderer
        self.clickListener = clickListener
    }

    public func dispatchClick(event: CircleEvent) {
        // 配送座標の wrap は CircleEvent の生成時に一元化済み。
        event.state.onClick?(event)
        clickListener?(event)
    }

    open func add(data: [CircleState]) async {
        if circleManager.isDestroyed { return }
        let landed: [CircleState] = await semaphore.withPermit {
            if circleManager.isDestroyed { return [] }
            // The app's list: anything it no longer has can be added again later.
            addedTracker.retain(Set(data.map(\.id)))
            var landed: [CircleState] = []
            let wasTiled = tiledIds
            // `route` returns once the tile layer's URL template has been handed
            // to the map (the provider's `onTemplate` awaits its raster upsert).
            let tiled = await tiler?.route(data) ?? []
            circleManager.setTiledSource(tiler)
            if circleManager.isDestroyed { return [] }
            tiledIds = tiled
            if !tiled.isEmpty, let tiler {
                // Tiled circles are on the map now. Report them before the
                // bookkeeping below, as PolylineController does.
                await OverlayAddedTracker.notify(addedTracker.admit(tiler.tiledStates()))
            }
            let data = tiled.isEmpty ? data : data.filter { !tiled.contains($0.id) }
            // Only natively drawn circles are diffed against the renderer.
            var previous = Set(
                circleManager.nativeEntities()
                    .map { $0.state.id }
                    .filter { !wasTiled.contains($0) }
            )
            var added: [CircleOverlayAddParams] = []
            var updated: [CircleOverlayChangeParams<ActualCircle>] = []
            var removed: [CircleEntity<ActualCircle>] = []

            for state in data {
                if previous.contains(state.id), let prevEntity = circleManager.getEntity(state.id) {
                    if prevEntity.changeMask(state) == 0 {
                        // 描画結果が不変なら renderer を呼ばず最新の state だけ採用する
                        // （react-sdk と同じ。composition ごとの無駄な onChange 再実行を避ける）。
                        circleManager.registerEntity(CircleEntity(circle: prevEntity.circle, state: state))
                        previous.remove(state.id)
                        continue
                    }
                    updated.append(
                        CircleOverlayChangeParams(
                            current: CircleEntity(circle: prevEntity.circle, state: state),
                            prev: prevEntity
                        )
                    )
                    previous.remove(state.id)
                } else {
                    added.append(CircleOverlayAddParams(state: state))
                    previous.remove(state.id)
                }
            }

            for remainId in previous {
                if let removedEntity = circleManager.removeEntity(remainId) {
                    removed.append(removedEntity)
                }
            }

            if !removed.isEmpty {
                await renderer.onRemove(data: removed)
                if circleManager.isDestroyed { return [] }
            }

            if !added.isEmpty {
                let actualCircles = await renderer.onAdd(data: added)
                if circleManager.isDestroyed { return [] }
                for (index, circle) in actualCircles.enumerated() {
                    guard let circle else { continue }
                    let entity = CircleEntity(circle: circle, state: added[index].state)
                    circleManager.registerEntity(entity)
                    landed.append(added[index].state)
                }
            }

            if !updated.isEmpty {
                let actualCircles = await renderer.onChange(data: updated)
                if circleManager.isDestroyed { return [] }
                for (index, circle) in actualCircles.enumerated() {
                    guard let circle else { continue }
                    let params = updated[index]
                    let entity = CircleEntity(circle: circle, state: params.current.state)
                    circleManager.registerEntity(entity)
                }
            }

            // Tiled circles: kept for taps, nothing native. Those that left the
            // tiles and the list are forgotten; those that left the tiles for
            // native drawing were added above.
            if !wasTiled.isEmpty {
                let nativeIds = Set(data.map(\.id))
                for id in wasTiled where !tiled.contains(id) && !nativeIds.contains(id) {
                    _ = circleManager.removeEntity(id)
                }
            }

            if circleManager.isDestroyed { return [] }
            await renderer.onPostProcess()
            // A circle that only moved from the tiles to native drawing is
            // still on the map: `admit` drops it.
            return addedTracker.admit(landed)
        }
        // After the renderer returned: the native objects exist on the map.
        await OverlayAddedTracker.notify(landed)
    }

    open func update(state: CircleState) async {
        if circleManager.isDestroyed { return }
        await semaphore.withPermit {
            guard let prevEntity = circleManager.getEntity(state.id) else { return }
            if tiledIds.contains(state.id) {
                if CircleTileSet.canTile(state) {
                    circleManager.registerEntity(CircleEntity(circle: nil, state: state))
                    tiler?.update(state)
                    return
                }
                // No longer drawable in a tile (onto the antimeridian or a pole,
                // or no radius): the map SDK draws it from now on. Still on the
                // map, so this is not an add.
                tiledIds.remove(state.id)
                tiler?.remove(state.id)
                let circles = await renderer.onAdd(data: [CircleOverlayAddParams(state: state)])
                if circleManager.isDestroyed { return }
                if circles.count == 1, let actualCircle = circles[0] {
                    circleManager.registerEntity(CircleEntity(circle: actualCircle, state: state))
                } else {
                    _ = circleManager.removeEntity(state.id)
                }
                await renderer.onPostProcess()
                return
            }
            if prevEntity.changeMask(state) == 0 { return }

            let entity = CircleEntity(circle: prevEntity.circle, state: state)
            let params = CircleOverlayChangeParams(current: entity, prev: prevEntity)
            let circles = await renderer.onChange(data: [params])
            if circleManager.isDestroyed { return }

            if circles.count == 1, let actualCircle = circles[0] {
                let updated = CircleEntity(circle: actualCircle, state: state)
                circleManager.registerEntity(updated)
            }
            await renderer.onPostProcess()
        }
    }

    open func clear() async {
        if circleManager.isDestroyed { return }
        await semaphore.withPermit {
            addedTracker.reset()
            let tiled = tiledIds
            tiledIds = []
            await tiler?.clear()
            let entities = circleManager.nativeEntities().filter { !tiled.contains($0.state.id) }
            await renderer.onRemove(data: entities)
            if circleManager.isDestroyed { return }
            // manager を空にしてから onPostProcess を呼ぶ。GL 系の描画担当は remove では何もせず、
            // onPostProcess で manager の全部を描き直すので、逆の順だと clear() 後も地図に残る。
            circleManager.clear()
            await renderer.onPostProcess()
        }
    }

    /// The circle a tap at `position` hits, tiled or not; its outline counts at
    /// the last camera this controller was told of.
    open func find(position: GeoPointProtocol) -> CircleEntity<ActualCircle>? {
        circleManager.find(position: position, cameraPosition: currentCameraPosition)
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
        await renderer.onPostProcess()
    }

    open func destroy() {
        tiler?.dispose()
        circleManager.destroy()
    }
    // ── SlottedOverlayController ────────────────────────────────────────
    //
    // kind は**必須メンバ**。既定値を持たせると、宣言忘れがコンパイルを通ってしまい
    // カスケードとスロットから黙って漏れる（android-sdk で実際に踏んだ）。

    public var kind: OverlayKind { .circle }

    public func hasId(_ id: String) -> Bool {
        circleManager.hasEntity(id)
    }

    public func resolveTap(position: GeoPointProtocol) -> OverlayHit? {
        guard let entity = find(position: position) else { return nil }
        return OverlayHit(kind: .circle, clicked: position) { [weak self] in
            self?.dispatchClick(event: CircleEvent(state: entity.state, clicked: position))
        }
    }

}
