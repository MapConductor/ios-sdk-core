open class RasterLayerController<ActualLayer, Renderer: RasterLayerOverlayRendererProtocol>: OverlayControllerProtocol
where Renderer.ActualLayer == ActualLayer {
    public typealias StateType = RasterLayerState
    public typealias EntityType = RasterLayerEntity<ActualLayer>
    public typealias EventType = RasterLayerEvent

    public let rasterLayerManager: RasterLayerManager<ActualLayer>
    open var renderer: Renderer

    public let zIndex: Int = 0
    private let semaphore = AsyncSemaphore(1)
    // android-sdk / react-sdk と同じく、内部的に upsert したレイヤー（例: マーカータイル）は
    // アプリ層の add()/composition の削除スイープ対象から除外する。
    private var upsertedIds: Set<String> = []

    public var clickListener: ((RasterLayerEvent) -> Void)?

    public init(
        rasterLayerManager: RasterLayerManager<ActualLayer>,
        renderer: Renderer,
        clickListener: ((RasterLayerEvent) -> Void)? = nil
    ) {
        self.rasterLayerManager = rasterLayerManager
        self.renderer = renderer
        self.clickListener = clickListener
    }

    public func dispatchClick(event: RasterLayerEvent) {
        clickListener?(event)
    }

    open func add(data: [RasterLayerState]) async {
        if rasterLayerManager.isDestroyed { return }
        await semaphore.withPermit {
            if rasterLayerManager.isDestroyed { return }
            var previous = Set(
                rasterLayerManager.allEntities()
                    .map { $0.state.id }
                    .filter { !upsertedIds.contains($0) }
            )
            var added: [RasterLayerOverlayAddParams] = []
            var updated: [RasterLayerOverlayChangeParams<ActualLayer>] = []
            var removed: [RasterLayerEntity<ActualLayer>] = []

            for state in data {
                if previous.contains(state.id), let prevEntity = rasterLayerManager.getEntity(state.id) {
                    if state.fingerPrint() == prevEntity.fingerPrint {
                        // 描画結果が不変なら renderer を呼ばず最新の state だけ採用する（react-sdk と同じ）。
                        rasterLayerManager.registerEntity(RasterLayerEntity(layer: prevEntity.layer, state: state))
                        previous.remove(state.id)
                        continue
                    }
                    updated.append(
                        RasterLayerOverlayChangeParams(
                            current: RasterLayerEntity(layer: prevEntity.layer, state: state),
                            prev: prevEntity
                        )
                    )
                    previous.remove(state.id)
                } else {
                    added.append(RasterLayerOverlayAddParams(state: state))
                    previous.remove(state.id)
                }
            }

            for remainId in previous {
                if let removedEntity = rasterLayerManager.removeEntity(remainId) {
                    removed.append(removedEntity)
                }
            }

            if !removed.isEmpty {
                await renderer.onRemove(data: removed)
            }

            if !added.isEmpty {
                let actualLayers = await renderer.onAdd(data: added)
                for (index, layer) in actualLayers.enumerated() {
                    guard let layer else { continue }
                    let entity = RasterLayerEntity(layer: layer, state: added[index].state)
                    rasterLayerManager.registerEntity(entity)
                }
            }

            if !updated.isEmpty {
                let actualLayers = await renderer.onChange(data: updated)
                for (index, layer) in actualLayers.enumerated() {
                    guard let layer else { continue }
                    let params = updated[index]
                    let entity = RasterLayerEntity(layer: layer, state: params.current.state)
                    rasterLayerManager.registerEntity(entity)
                }
            }

            await renderer.onPostProcess()
        }
    }

    open func update(state: RasterLayerState) async {
        if rasterLayerManager.isDestroyed { return }
        await semaphore.withPermit {
            guard let prevEntity = rasterLayerManager.getEntity(state.id) else { return }
            let currentFinger = state.fingerPrint()
            let prevFinger = prevEntity.fingerPrint
            if currentFinger == prevFinger { return }

            let entity = RasterLayerEntity(layer: prevEntity.layer, state: state)
            let params = RasterLayerOverlayChangeParams(current: entity, prev: prevEntity)
            let layers = await renderer.onChange(data: [params])

            if layers.count == 1, let actualLayer = layers[0] {
                let updated = RasterLayerEntity(layer: actualLayer, state: state)
                rasterLayerManager.registerEntity(updated)
            }

            await renderer.onPostProcess()
        }
    }

    /// アプリ層の add()/composition とは独立に、単一のレイヤーを追加・更新する
    /// （マーカータイル等の内部レイヤー用）。android-sdk / react-sdk と同一。
    open func upsert(state: RasterLayerState) async {
        if rasterLayerManager.isDestroyed { return }
        await semaphore.withPermit {
            if rasterLayerManager.isDestroyed { return }
            upsertedIds.insert(state.id)
            guard let prevEntity = rasterLayerManager.getEntity(state.id) else {
                let layers = await renderer.onAdd(data: [RasterLayerOverlayAddParams(state: state)])
                if layers.count == 1, let layer = layers[0] {
                    rasterLayerManager.registerEntity(RasterLayerEntity(layer: layer, state: state))
                }
                await renderer.onPostProcess()
                return
            }
            if state.fingerPrint() == prevEntity.fingerPrint { return }
            let params = RasterLayerOverlayChangeParams(
                current: RasterLayerEntity(layer: prevEntity.layer, state: state),
                prev: prevEntity
            )
            let layers = await renderer.onChange(data: [params])
            if layers.count == 1, let layer = layers[0] {
                rasterLayerManager.registerEntity(RasterLayerEntity(layer: layer, state: state))
            }
            await renderer.onPostProcess()
        }
    }

    /// upsert で追加した単一レイヤーを id 指定で削除する。android-sdk / react-sdk と同一。
    open func removeById(_ id: String) async {
        if rasterLayerManager.isDestroyed { return }
        await semaphore.withPermit {
            upsertedIds.remove(id)
            guard let entity = rasterLayerManager.removeEntity(id) else { return }
            await renderer.onRemove(data: [entity])
            await renderer.onPostProcess()
        }
    }

    open func clear() async {
        if rasterLayerManager.isDestroyed { return }
        await semaphore.withPermit {
            upsertedIds.removeAll()
            let entities = rasterLayerManager.allEntities()
            await renderer.onRemove(data: entities)
            await renderer.onPostProcess()
            rasterLayerManager.clear()
        }
    }

    open func find(position: GeoPointProtocol) -> RasterLayerEntity<ActualLayer>? {
        nil
    }

    open func onCameraChanged(mapCameraPosition: MapCameraPosition) async {
        await renderer.onCameraChanged(mapCameraPosition: mapCameraPosition)
    }

    open func destroy() {
        rasterLayerManager.destroy()
    }
}
