import Foundation

open class PolygonController<ActualPolygon, Renderer: PolygonOverlayRendererProtocol>: OverlayControllerProtocol, SlottedOverlayController
where Renderer.ActualPolygon == ActualPolygon {
    public typealias StateType = PolygonState
    public typealias EntityType = PolygonEntity<ActualPolygon>
    public typealias EventType = PolygonEvent

    public let polygonManager: PolygonManager<ActualPolygon>
    open var renderer: Renderer

    public let zIndex: Int = 3
    private let semaphore = AsyncSemaphore(1)

    /// Which polygons have reached the map, natively or in tiles, for their `onAdded`.
    @_spi(MapConductorDriver)
    public let addedTracker = OverlayAddedTracker()

    public var clickListener: ((PolygonEvent) -> Void)?

    /// Set by a provider that can show polygon tiles (see ``PolygonTiler``).
    /// Polygons it tiles stay in ``polygonManager``, for taps, with no native
    /// overlay: their entity's `polygon` is nil and the renderer never sees them.
    @_spi(MapConductorDriver)
    public var tiler: PolygonTiler?
    private var tiledIds: Set<String> = []

    public init(
        polygonManager: PolygonManager<ActualPolygon>,
        renderer: Renderer,
        clickListener: ((PolygonEvent) -> Void)? = nil
    ) {
        self.polygonManager = polygonManager
        self.renderer = renderer
        self.clickListener = clickListener
    }

    public func dispatchClick(event: PolygonEvent) {
        // 配送座標の wrap は PolygonEvent の生成時に一元化済み。
        event.state.onClick?(event)
        clickListener?(event)
    }

    open func add(data: [PolygonState]) async {
        if polygonManager.isDestroyed { return }
        let landed: [PolygonState] = await semaphore.withPermit {
            if polygonManager.isDestroyed { return [] }
            // The app's list: anything it no longer has can be added again later.
            addedTracker.retain(Set(data.map(\.id)))
            var landed: [PolygonState] = []
            let wasTiled = tiledIds
            // `route` returns once the tile layer's URL template has been handed
            // to the map (the provider's `onTemplate` awaits its raster upsert).
            let tiled = await tiler?.route(data) ?? []
            tiledIds = tiled
            if !tiled.isEmpty, let tiler {
                // Tiled polygons are on the map now. Report them before the
                // bookkeeping below: registering 100,000 entities for taps takes
                // about a second, and the tiles are already showing by then.
                await OverlayAddedTracker.notify(addedTracker.admit(tiler.tiledStates()))
            }
            let data = tiled.isEmpty ? data : data.filter { !tiled.contains($0.id) }
            // Only natively drawn polygons are diffed against the renderer.
            var previous = Set(
                polygonManager.allEntities()
                    .map { $0.state.id }
                    .filter { !wasTiled.contains($0) }
            )
            var added: [PolygonOverlayAddParams] = []
            var updated: [PolygonOverlayChangeParams<ActualPolygon>] = []
            var removed: [PolygonEntity<ActualPolygon>] = []

            for state in data {
                if previous.contains(state.id), let prevEntity = polygonManager.getEntity(state.id) {
                    if state.fingerPrint() == prevEntity.fingerPrint {
                        // 描画結果が不変なら renderer を呼ばず最新の state だけ採用する（react-sdk と同じ）。
                        polygonManager.registerEntity(PolygonEntity(polygon: prevEntity.polygon, state: state))
                        previous.remove(state.id)
                        continue
                    }
                    updated.append(
                        PolygonOverlayChangeParams(
                            current: PolygonEntity(polygon: prevEntity.polygon, state: state),
                            prev: prevEntity
                        )
                    )
                    previous.remove(state.id)
                } else {
                    added.append(PolygonOverlayAddParams(state: state))
                    previous.remove(state.id)
                }
            }

            for remainId in previous {
                if let removedEntity = polygonManager.getEntity(remainId) {
                    removed.append(removedEntity)
                }
            }

            // Remove from the map first, then forget the entities. If this sync is
            // cancelled mid-removal, the manager still tracks the leftovers so the
            // next sync retries the removal instead of orphaning graphics on the map.
            if !removed.isEmpty {
                await renderer.onRemove(data: removed)
                removed.forEach { polygonManager.removeEntity($0.state.id) }
            }

            if !added.isEmpty {
                let actualPolygons = await renderer.onAdd(data: added)
                for (index, polygon) in actualPolygons.enumerated() {
                    guard let polygon else { continue }
                    let entity = PolygonEntity(polygon: polygon, state: added[index].state)
                    polygonManager.registerEntity(entity)
                    landed.append(added[index].state)
                }
            }

            if !updated.isEmpty {
                let actualPolygons = await renderer.onChange(data: updated)
                for (index, polygon) in actualPolygons.enumerated() {
                    guard let polygon else { continue }
                    let params = updated[index]
                    let entity = PolygonEntity(polygon: polygon, state: params.current.state)
                    polygonManager.registerEntity(entity)
                }
            }

            // Tiled polygons: kept for taps, nothing native. Those that left the
            // tiles and the list are forgotten; those that left the tiles for
            // native drawing were added above.
            if !wasTiled.isEmpty {
                let nativeIds = Set(data.map(\.id))
                for id in wasTiled where !tiled.contains(id) && !nativeIds.contains(id) {
                    _ = polygonManager.removeEntity(id)
                }
            }
            if !tiled.isEmpty, let tiler {
                for state in tiler.tiledStates() {
                    polygonManager.registerEntity(PolygonEntity(polygon: nil, state: state))
                }
            }

            await renderer.onPostProcess()
            // A polygon that only moved from the tiles to native drawing is
            // still on the map: `admit` drops it.
            return addedTracker.admit(landed)
        }
        await OverlayAddedTracker.notify(landed)
    }

    open func update(state: PolygonState) async {
        if polygonManager.isDestroyed { return }
        await semaphore.withPermit {
            guard let prevEntity = polygonManager.getEntity(state.id) else { return }
            if tiledIds.contains(state.id) {
                if PolygonTileSet.canTile(state) {
                    polygonManager.registerEntity(PolygonEntity(polygon: nil, state: state))
                    tiler?.update(state)
                    return
                }
                // No longer drawable in a tile (geodesic, half the world wide, or
                // under 3 points): the map SDK draws it from now on. Still on the
                // map, so this is not an add. Whether the rest stay in tiles is
                // left to the next add, which decides tiling for the whole list.
                tiledIds.remove(state.id)
                tiler?.remove(state.id)
                let polygons = await renderer.onAdd(data: [PolygonOverlayAddParams(state: state)])
                if polygons.count == 1, let actualPolygon = polygons[0] {
                    polygonManager.registerEntity(PolygonEntity(polygon: actualPolygon, state: state))
                } else {
                    _ = polygonManager.removeEntity(state.id)
                }
                await renderer.onPostProcess()
                return
            }
            let currentFinger = state.fingerPrint()
            let prevFinger = prevEntity.fingerPrint
            if currentFinger == prevFinger { return }

            let entity = PolygonEntity(polygon: prevEntity.polygon, state: state)
            let params = PolygonOverlayChangeParams(current: entity, prev: prevEntity)
            let polygons = await renderer.onChange(data: [params])

            if polygons.count == 1, let actualPolygon = polygons[0] {
                let updated = PolygonEntity(polygon: actualPolygon, state: state)
                polygonManager.registerEntity(updated)
            }
            await renderer.onPostProcess()
        }
    }

    open func clear() async {
        if polygonManager.isDestroyed { return }
        await semaphore.withPermit {
            addedTracker.reset()
            let tiled = tiledIds
            tiledIds = []
            await tiler?.clear()
            let entities = polygonManager.allEntities().filter { !tiled.contains($0.state.id) }
            await renderer.onRemove(data: entities)
            // manager を空にしてから onPostProcess を呼ぶ。GL 系の描画担当は remove では何もせず、
            // onPostProcess で manager の全部を描き直すので、逆の順だと clear() 後も地図に残る。
            polygonManager.clear()
            await renderer.onPostProcess()
        }
    }

    open func find(position: GeoPointProtocol) -> PolygonEntity<ActualPolygon>? {
        polygonManager.find(position: position)
    }

    open func onCameraChanged(mapCameraPosition: MapCameraPosition) async {}

    open func destroy() {
        tiler?.dispose()
        polygonManager.destroy()
    }
    // ── SlottedOverlayController ────────────────────────────────────────
    //
    // kind は**必須メンバ**。既定値を持たせると、宣言忘れがコンパイルを通ってしまい
    // カスケードとスロットから黙って漏れる（android-sdk で実際に踏んだ）。

    public var kind: OverlayKind { .polygon }

    public func hasId(_ id: String) -> Bool {
        polygonManager.hasEntity(id)
    }

    public func resolveTap(position: GeoPointProtocol) -> OverlayHit? {
        guard let entity = find(position: position) else { return nil }
        return OverlayHit(kind: .polygon, clicked: position) { [weak self] in
            self?.dispatchClick(event: PolygonEvent(state: entity.state, clicked: position))
        }
    }

}
