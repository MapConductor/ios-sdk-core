import Foundation

open class GroundImageController<ActualGroundImage, Renderer: GroundImageOverlayRendererProtocol>: OverlayControllerProtocol, SlottedOverlayController
where Renderer.ActualGroundImage == ActualGroundImage {
    public typealias StateType = GroundImageState
    public typealias EntityType = GroundImageEntity<ActualGroundImage>
    public typealias EventType = GroundImageEvent

    public let groundImageManager: GroundImageManager<ActualGroundImage>
    open var renderer: Renderer

    public let zIndex: Int = 2
    private let semaphore = AsyncSemaphore(1)

    public var clickListener: ((GroundImageEvent) -> Void)?

    public init(
        groundImageManager: GroundImageManager<ActualGroundImage>,
        renderer: Renderer,
        clickListener: ((GroundImageEvent) -> Void)? = nil
    ) {
        self.groundImageManager = groundImageManager
        self.renderer = renderer
        self.clickListener = clickListener
    }

    public func dispatchClick(event: GroundImageEvent) {
        // 配送座標の wrap は GroundImageEvent の生成時に一元化済み。
        event.state.onClick?(event)
        clickListener?(event)
    }

    open func add(data: [GroundImageState]) async {
        if groundImageManager.isDestroyed { return }
        await semaphore.withPermit {
            if groundImageManager.isDestroyed { return }
            var previous = Set(groundImageManager.allEntities().map { $0.state.id })
            var added: [GroundImageOverlayAddParams] = []
            var updated: [GroundImageOverlayChangeParams<ActualGroundImage>] = []
            var removed: [GroundImageEntity<ActualGroundImage>] = []

            for state in data {
                if previous.contains(state.id), let prevEntity = groundImageManager.getEntity(state.id) {
                    if state.fingerPrint() == prevEntity.fingerPrint {
                        // 描画結果が不変なら renderer を呼ばず最新の state だけ採用する（react-sdk と同じ）。
                        groundImageManager.registerEntity(GroundImageEntity(groundImage: prevEntity.groundImage, state: state))
                        previous.remove(state.id)
                        continue
                    }
                    updated.append(
                        GroundImageOverlayChangeParams(
                            current: GroundImageEntity(groundImage: prevEntity.groundImage, state: state),
                            prev: prevEntity
                        )
                    )
                    previous.remove(state.id)
                } else {
                    added.append(GroundImageOverlayAddParams(state: state))
                    previous.remove(state.id)
                }
            }

            for remainId in previous {
                if let removedEntity = groundImageManager.removeEntity(remainId) {
                    removed.append(removedEntity)
                }
            }

            if !removed.isEmpty {
                await renderer.onRemove(data: removed)
            }

            if !added.isEmpty {
                let actualGroundImages = await renderer.onAdd(data: added)
                for (index, groundImage) in actualGroundImages.enumerated() {
                    guard let groundImage else { continue }
                    let entity = GroundImageEntity(groundImage: groundImage, state: added[index].state)
                    groundImageManager.registerEntity(entity)
                }
            }

            if !updated.isEmpty {
                let actualGroundImages = await renderer.onChange(data: updated)
                for (index, groundImage) in actualGroundImages.enumerated() {
                    guard let groundImage else { continue }
                    let params = updated[index]
                    let entity = GroundImageEntity(groundImage: groundImage, state: params.current.state)
                    groundImageManager.registerEntity(entity)
                }
            }

            await renderer.onPostProcess()
        }
    }

    open func update(state: GroundImageState) async {
        if groundImageManager.isDestroyed { return }
        await semaphore.withPermit {
            guard let prevEntity = groundImageManager.getEntity(state.id) else { return }
            let currentFinger = state.fingerPrint()
            let prevFinger = prevEntity.fingerPrint
            if currentFinger == prevFinger { return }

            let entity = GroundImageEntity(groundImage: prevEntity.groundImage, state: state)
            let params = GroundImageOverlayChangeParams(current: entity, prev: prevEntity)
            let groundImages = await renderer.onChange(data: [params])

            if groundImages.count == 1, let actualGroundImage = groundImages[0] {
                let updated = GroundImageEntity(groundImage: actualGroundImage, state: state)
                groundImageManager.registerEntity(updated)
            }
            await renderer.onPostProcess()
        }
    }

    open func clear() async {
        if groundImageManager.isDestroyed { return }
        await semaphore.withPermit {
            let entities = groundImageManager.allEntities()
            await renderer.onRemove(data: entities)
            // android-sdk / react-sdk と同じく clear() でも onPostProcess を呼ぶ。
            await renderer.onPostProcess()
            groundImageManager.clear()
        }
    }

    open func find(position: GeoPointProtocol) -> GroundImageEntity<ActualGroundImage>? {
        groundImageManager.find(position: position)
    }

    open func onCameraChanged(mapCameraPosition: MapCameraPosition) async {
        await renderer.onPostProcess()
    }

    open func destroy() {
        groundImageManager.destroy()
    }
    // ── SlottedOverlayController ────────────────────────────────────────
    //
    // kind は**必須メンバ**。既定値を持たせると、宣言忘れがコンパイルを通ってしまい
    // カスケードとスロットから黙って漏れる（android-sdk で実際に踏んだ）。

    public var kind: OverlayKind { .groundImage }

    public func hasId(_ id: String) -> Bool {
        groundImageManager.hasEntity(id)
    }

    public func resolveTap(position: GeoPointProtocol) -> OverlayHit? {
        guard let entity = find(position: position) else { return nil }
        return OverlayHit(kind: .groundImage, clicked: position) { [weak self] in
            self?.dispatchClick(event: GroundImageEvent(state: entity.state, clicked: position))
        }
    }

}

