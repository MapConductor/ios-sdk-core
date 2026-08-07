import Foundation

open class AbstractMarkerController<
    ActualMarker,
    Renderer: MarkerOverlayRendererProtocol
>: OverlayControllerProtocol where Renderer.ActualMarker == ActualMarker {
    public typealias StateType = MarkerState
    public typealias EntityType = MarkerEntity<ActualMarker>
    public typealias EventType = MarkerState

    public let markerManager: MarkerManager<ActualMarker>
    open var renderer: Renderer
    private var rendererRef: Renderer

    public let zIndex: Int = 10
    private let semaphore = AsyncSemaphore(1)
    private let defaultMarkerIcon = DefaultMarkerIcon().toBitmapIcon()

    public var clickListener: ((MarkerState) -> Void)?

    public var dragStartListener: OnMarkerEventHandler?
    public var dragListener: OnMarkerEventHandler?
    public var dragEndListener: OnMarkerEventHandler?
    public var animateStartListener: OnMarkerEventHandler?
    public var animateEndListener: OnMarkerEventHandler?

    private var animatingMarkerIds: Set<String> = []

    /// ドラッグ中のマーカー id。
    ///
    /// react-sdk が `AbstractMarkerController` に持つ WeakMap のドラッグ状態の移植。
    /// `MarkerState` は `hashCode()` ベースの `Equatable` なので、キーは
    /// `animatingMarkerIds` と同じく id を使う。
    ///
    /// **ここは「facility」であって既定の挙動ではない。**
    /// react-sdk では、ネイティブにドラッグ可能なマーカーを持つプロバイダ（Leaflet の
    /// Draggable、HERE の H.map behavior など）が `update()` を override して
    /// `isDragging` でスキップする。マーカーを動かしているのは SDK 側なので、そこへ
    /// `MarkerState` の位置を再適用すると綱引きになるため。
    ///
    /// 一方 ios-sdk のプロバイダは 9 つとも**ドラッグを自前のジェスチャ処理で実装**し、
    /// `.update` で `state.position` を書き換えて、その変更通知から来る `update(state:)` の
    /// 再描画でマーカーを動かしている（`HereMarkerController.handleLongPress` が典型）。
    /// つまり `update()` こそがドラッグの駆動経路なので、ここで一律にスキップすると
    /// マーカーが指に追従しなくなる。GoogleMaps だけは GMS のネイティブドラッグ
    /// （`didDrag` デリゲート）で、位置を state へミラーしているだけ。
    ///
    /// そのため既定では `update()` をスキップしない。ネイティブドラッグを持つプロバイダが
    /// 必要に応じて `update()` を override して `isDragging(_:)` で判断すること。
    private var draggingMarkerIds: Set<String> = []

    public init(
        markerManager: MarkerManager<ActualMarker>,
        renderer: Renderer,
        clickListener: ((MarkerState) -> Void)? = nil
    ) {
        self.markerManager = markerManager
        self.renderer = renderer
        self.rendererRef = renderer
        self.clickListener = clickListener

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rendererRef.animateStartListener = { [weak self] state in
                self?.dispatchAnimateStart(state: state)
            }
            self.rendererRef.animateEndListener = { [weak self] state in
                self?.dispatchAnimateEnd(state: state)
            }
        }
    }

    public func dispatchClick(state: MarkerState) {
        state.onClick?(state)
        clickListener?(state)
    }

    public func dispatchDragStart(state: MarkerState) {
        setDraggingState(markerState: state, dragging: true)
        state.onDragStart?(state)
        dragStartListener?(state)
    }

    public func dispatchDrag(state: MarkerState) {
        state.onDrag?(state)
        dragListener?(state)
    }

    public func dispatchDragEnd(state: MarkerState) {
        setDraggingState(markerState: state, dragging: false)
        state.onDragEnd?(state)
        dragEndListener?(state)
    }

    public func dispatchAnimateStart(state: MarkerState) {
        animatingMarkerIds.insert(state.id)
        state.onAnimateStart?(state)
        animateStartListener?(state)
    }

    public func dispatchAnimateEnd(state: MarkerState) {
        animatingMarkerIds.remove(state.id)
        state.onAnimateEnd?(state)
        animateEndListener?(state)
    }

    /// ドラッグ中フラグを立て下げする。`dispatchDragStart` / `dispatchDragEnd` が自動で呼ぶ。
    ///
    /// フラグを立てるだけで既定の挙動は変わらない（`draggingMarkerIds` の説明を参照）。
    /// 参照するかどうかは各プロバイダの判断。
    open func setDraggingState(markerState: MarkerState, dragging: Bool) {
        if dragging {
            draggingMarkerIds.insert(markerState.id)
        } else {
            draggingMarkerIds.remove(markerState.id)
        }
    }

    public func isDragging(_ markerState: MarkerState) -> Bool {
        draggingMarkerIds.contains(markerState.id)
    }

    open func add(data: [MarkerState]) async {
        if markerManager.isDestroyed { return }
        MCLog.marker("AbstractMarkerController.add count=\(data.count)")
        let entitiesToAnimate: [MarkerEntity<ActualMarker>] = await semaphore.withPermit {
            if markerManager.isDestroyed { return [] }
            var modifiedEntities: [MarkerEntity<ActualMarker>] = []
            var previous = Set(markerManager.allEntities().map { $0.state.id })

            var added: [MarkerOverlayAddParams] = []
            var updated: [MarkerOverlayChangeParams<ActualMarker>] = []
            var removed: [MarkerEntity<ActualMarker>] = []

            for state in data {
                if previous.contains(state.id), let prevEntity = markerManager.getEntity(state.id) {
                    previous.remove(state.id)

                    // 描画結果が変わらないマーカーは renderer を往復させない。
                    // 同じ一覧が再送されただけでも以前は全件を onChange に積んでいたため、
                    // 数千件のマップで毎回フルの往復が走っていた。
                    // react-sdk の MarkerIngestionEngine が持つ同名の最適化の移植。
                    // fingerPrint は animation を含むので、アニメーション要求は素通りしない。
                    if prevEntity.fingerPrint == state.fingerPrint() { continue }

                    let markerIcon = state.icon?.toBitmapIcon() ?? defaultMarkerIcon
                    updated.append(
                        MarkerOverlayChangeParams(
                            current: MarkerEntity(
                                marker: prevEntity.marker,
                                state: state,
                                isRendered: true
                            ),
                            bitmapIcon: markerIcon,
                            prev: prevEntity
                        )
                    )
                } else {
                    added.append(
                        MarkerOverlayAddParams(
                            state: state,
                            bitmapIcon: state.icon?.toBitmapIcon() ?? defaultMarkerIcon
                        )
                    )
                    previous.remove(state.id)
                }
            }

            for remainId in previous {
                if let removedEntity = markerManager.removeEntity(remainId) {
                    removed.append(removedEntity)
                }
            }

            // Remove markers
            if !removed.isEmpty {
                await renderer.onRemove(data: removed)
                // Give the UI thread a chance to breathe when removing many markers.
                if removed.count >= markerRenderBatchSize {
                    await Task.yield()
                }
            }

            // Add new markers
            if !added.isEmpty {
                for batch in added.chunked(into: markerRenderBatchSize) {
                    let actualMarkers = await renderer.onAdd(data: batch)
                    for (index, actualMarker) in actualMarkers.enumerated() {
                        guard let actualMarker, index < batch.count else { continue }
                        let entity = MarkerEntity(
                            marker: actualMarker,
                            state: batch[index].state,
                            isRendered: true
                        )
                        markerManager.registerEntity(entity)
                        modifiedEntities.append(entity)
                    }
                    await Task.yield()
                }
            }

            // Update changed markers
            if !updated.isEmpty {
                for batch in updated.chunked(into: markerRenderBatchSize) {
                    let actualMarkers = await renderer.onChange(data: batch)
                    for (index, actualMarker) in actualMarkers.enumerated() {
                        guard let actualMarker, index < batch.count else { continue }
                        let params = batch[index]
                        let entity = MarkerEntity(
                            marker: actualMarker,
                            state: params.current.state,
                            isRendered: true
                        )
                        markerManager.registerEntity(entity)
                    }
                    await Task.yield()
                }
            }

            await renderer.onPostProcess()
            return modifiedEntities.filter { $0.state.getAnimation() != nil }
        }

        // アニメーションはロックの外で、まとめて並行に走らせる。
        // android-sdk の `onAnimate` は `coroutine.launch` / `host.start` で即座に返るため、
        // ロック内で逐次呼んでも実際のアニメーションは同時進行し、ロックもすぐ解放される。
        // iOS の `onAnimate` はフォールバック経路（ジオ補間）が完了まで await するので、
        // ロック内で呼ぶとマーカー操作全体が数秒ブロックされ、アニメーション同士も直列化する。
        // 同じ観測挙動にするため、ここで解放後に並行実行する（react-sdk が Promise.all に
        // しているのと同じ理由）。
        await animate(entities: entitiesToAnimate, reason: "add")
    }

    /// 与えられたエンティティのアニメーションを並行に実行する。呼び出し側は
    /// セマフォを解放済みであること。
    private func animate(entities: [MarkerEntity<ActualMarker>], reason: String) async {
        guard !entities.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for entity in entities {
                group.addTask { [self] in
                    MCLog.marker("AbstractMarkerController.\(reason) -> onAnimate id=\(entity.state.id)")
                    await renderer.onAnimate(entity: entity)
                }
            }
        }
    }

    open func update(state: MarkerState) async {
        if markerManager.isDestroyed { return }
        MCLog.marker("AbstractMarkerController.update start id=\(state.id) anim=\(String(describing: state.getAnimation()))")

        // エンティティの解決はロックを取ってから行う（react-sdk と同じ）。
        // android-sdk はロック前に `hasEntity` で早期 return するため、初回 `add(data:)` の
        // 進行中に飛んできた update を取りこぼす。iOS では以前これを「セマフォを 1 回
        // 空取りして再確認する」回避策で埋めていたが、ロック内で解決すれば回避策なしで
        // 同じ保証が得られるうえ、待機中に remove→再生成された場合も古い
        // プロバイダマーカーを書き戻さずに済む。
        let entityToAnimate: MarkerEntity<ActualMarker>? = await semaphore.withPermit {
            if markerManager.isDestroyed { return nil }
            guard let prevEntity = markerManager.getEntity(state.id) else { return nil }

            let currentFinger = state.fingerPrint()
            let prevFinger = prevEntity.fingerPrint
            if currentFinger == prevFinger {
                MCLog.marker("AbstractMarkerController.update id=\(state.id) fingerprintSame anim=\(String(describing: state.getAnimation()))")
                // If an animation was requested but the manager fingerprint already matches (e.g. the
                // change got "consumed" by a list-sync add()), still run the animation once.
                if state.getAnimation() != nil, !animatingMarkerIds.contains(state.id) {
                    MCLog.marker("AbstractMarkerController.update id=\(state.id) -> onAnimate fallback")
                    await renderer.onPostProcess()
                    return prevEntity
                }
                return nil
            }

            // tiling は prevEntity から引き継ぐ。ここは「担当替え」をする場所ではない
            // （タイル ⇄ ネイティブの昇格・降格は各プロバイダの update / ingest が行う）。
            // 落とすと、タイル担当のマーカーが 1 回更新されただけで
            // `MarkerTileRenderer` の絞り込みから外れ、ネイティブマーカーも持たないため
            // 地図から消える。
            markerManager.updateEntity(
                MarkerEntity(
                    marker: prevEntity.marker,
                    state: state,
                    visible: prevEntity.visible,
                    isRendered: prevEntity.isRendered,
                    tiling: prevEntity.tiling
                )
            )

            guard let marker = prevEntity.marker else { return nil }

            let markerIcon = (state.icon ?? DefaultMarkerIcon()).toBitmapIcon()
            let renderEntity = MarkerEntity(
                marker: marker,
                state: state,
                isRendered: true
            )
            let markerParams = MarkerOverlayChangeParams(
                current: renderEntity,
                bitmapIcon: markerIcon,
                prev: prevEntity
            )

            var pendingAnimation: MarkerEntity<ActualMarker>?
            let markers = await renderer.onChange(data: [markerParams])
            if markers.count == 1, let actualMarker = markers[0] {
                let finalEntity = MarkerEntity(
                    marker: actualMarker,
                    state: state,
                    isRendered: true
                )
                markerManager.updateEntity(finalEntity)

                if prevFinger.animation != currentFinger.animation {
                    if state.getAnimation() != nil {
                        MCLog.marker("AbstractMarkerController.update id=\(state.id) animationChanged -> onAnimate")
                        pendingAnimation = finalEntity
                    }
                }
            }

            await renderer.onPostProcess()
            return pendingAnimation
        }

        // add() と同じ理由でロックの外に出す。ここを await したままロック内で回すと、
        // バウンス中に別のマーカーをタップした場合に最初のアニメーション完了まで待たされる。
        if let entityToAnimate {
            await animate(entities: [entityToAnimate], reason: "update")
        }
    }

    open func clear() async {
        if markerManager.isDestroyed { return }
        await semaphore.withPermit {
            if markerManager.isDestroyed { return }
            let entities = markerManager.allEntities()
            await renderer.onRemove(data: entities)
            markerManager.clear()
            draggingMarkerIds.removeAll()
        }
    }

    open func onCameraChanged(mapCameraPosition: MapCameraPosition) async {
        // No-op for default marker flow.
    }

    open func find(position: GeoPointProtocol) -> MarkerEntity<ActualMarker>? {
        fatalError("find(position:) must be overridden by a concrete controller")
    }

    open func destroy() {
        draggingMarkerIds.removeAll()
        markerManager.destroy()
    }
}

/// android-sdk の `MARKER_RENDER_BATCH_SIZE` と同値。
/// レンダラ呼び出しをこの件数ごとに区切り、バッチの合間に `Task.yield()` を挟むことで、
/// 数万件のマーカー投入中でも UI 更新やキャンセルが割り込めるようにする。
let markerRenderBatchSize = 500

private extension Array {
    /// Kotlin の `List.chunked(size)` 相当。空配列は空、`size <= 0` は全体を 1 チャンクとして返す。
    func chunked(into size: Int) -> [[Element]] {
        if isEmpty { return [] }
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
