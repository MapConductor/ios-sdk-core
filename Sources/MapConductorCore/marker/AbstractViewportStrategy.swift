import Foundation

/// ビューポート内のマーカーだけを描くマーカーレンダリングストラテジの基底。
///
/// android-sdk の `AbstractViewportStrategy.kt` / react-sdk の `AbstractViewportStrategy.ts`
/// と同じ役割・同じ名前。マーカー集合が変わったとき（``onAdd(data:viewport:renderer:)``）と
/// 1 件更新されたとき（``onUpdate(state:viewport:renderer:)``）に、ビューポート内のものだけを
/// レンダラへ渡し、外のものは ``MarkerManager`` に持つだけで描かない。
///
/// **``onCameraChanged(mapCameraPosition:renderer:)`` は実装していない。** ここが担当するのは
/// 「マーカー集合が変わったとき」で、カメラが動いたときに画面へ入ったものを出し／出たものを
/// 消すのはサブクラスの責任。3 者ともこの分担で、`onAdd` / `onUpdate` は
/// 「サブクラスの `onCameraChanged` から呼ばれる」前提で書かれている。
open class AbstractViewportStrategy<ActualMarker>: AbstractMarkerRenderingStrategy<ActualMarker> {
    public init(
        semaphore: AsyncSemaphore = AsyncSemaphore(1),
        geocell: HexGeocellProtocol = HexGeocell.defaultGeocell()
    ) {
        super.init(
            markerManager: MarkerManager<ActualMarker>(geocell: geocell, minMarkerCount: 0),
            semaphore: semaphore
        )
    }

    open override func onAdd<Renderer: MarkerOverlayRendererProtocol>(
        data: [MarkerState],
        viewport: GeoRectBounds,
        renderer: Renderer
    ) async -> Bool where Renderer.ActualMarker == ActualMarker {
        await semaphore.withPermit {
            await applyAdd(data: data, viewport: viewport, renderer: renderer)
        }
    }

    open override func onUpdate<Renderer: MarkerOverlayRendererProtocol>(
        state: MarkerState,
        viewport: GeoRectBounds,
        renderer: Renderer
    ) async -> Bool where Renderer.ActualMarker == ActualMarker {
        // 未登録なら何もしない。初回投入中に来る更新をここで待たせないよう、
        // semaphore を取る前に見る（android-sdk / react-sdk と同じ）。
        guard markerManager.hasEntity(state.id) else { return true }

        return await semaphore.withPermit {
            await applyUpdate(state: state, viewport: viewport, renderer: renderer)
        }
    }

    open override func clear() {
        markerManager.clear()
    }

    // MARK: - 実処理（semaphore は呼び出し側が取る）

    private func applyAdd<Renderer: MarkerOverlayRendererProtocol>(
        data: [MarkerState],
        viewport: GeoRectBounds,
        renderer: Renderer
    ) async -> Bool where Renderer.ActualMarker == ActualMarker {
        var previousIds = Set(markerManager.allEntities().map { $0.state.id })
        var added: [MarkerOverlayAddParams] = []
        var updated: [MarkerOverlayChangeParams<ActualMarker>] = []
        var removed: [MarkerEntity<ActualMarker>] = []

        for state in data {
            let isInViewport = viewport.contains(point: state.position)
            let markerIcon = state.icon?.toBitmapIcon() ?? defaultMarkerIcon

            if previousIds.contains(state.id), let prevEntity = markerManager.getEntity(state.id) {
                previousIds.remove(state.id)

                if isInViewport {
                    updated.append(
                        MarkerOverlayChangeParams(
                            current: MarkerEntity(marker: prevEntity.marker, state: state, isRendered: true),
                            bitmapIcon: markerIcon,
                            prev: prevEntity
                        )
                    )
                } else {
                    // ビューポートから出たものは、出ていたなら取り下げる。
                    // 取り下げずに entity だけ差し替えると、描画済みマーカーが画面外に残り続け、
                    // 描画数が単調増加する（ビューポート最適化にならない）。
                    if prevEntity.marker != nil {
                        removed.append(prevEntity)
                    }
                    // isRendered は実態に合わせる。marker が無いのに true を立てると、
                    // 「描画済みか」で出し入れを決めるサブクラスが未描画のものを消そうとし、
                    // 画面に入っても出てこなくなる。
                    markerManager.registerEntity(
                        MarkerEntity(marker: nil, state: state, isRendered: false)
                    )
                }
            } else {
                previousIds.remove(state.id)

                if isInViewport {
                    added.append(MarkerOverlayAddParams(state: state, bitmapIcon: markerIcon))
                } else {
                    // 未描画なので isRendered は false（上の既存分と同じ理由）。
                    markerManager.registerEntity(
                        MarkerEntity(marker: nil, state: state, isRendered: false)
                    )
                }
            }
        }

        for remainId in previousIds {
            if let removedEntity = markerManager.removeEntity(remainId) {
                removed.append(removedEntity)
            }
        }

        if !removed.isEmpty {
            await renderer.onRemove(data: removed)
        }

        if !added.isEmpty {
            let actualMarkers = await renderer.onAdd(data: added)
            for (index, actualMarker) in actualMarkers.enumerated() {
                guard let actualMarker else { continue }
                markerManager.registerEntity(
                    MarkerEntity(marker: actualMarker, state: added[index].state, isRendered: true)
                )
            }
        }

        if !updated.isEmpty {
            let actualMarkers = await renderer.onChange(data: updated)
            for (index, actualMarker) in actualMarkers.enumerated() {
                guard let actualMarker else { continue }
                markerManager.registerEntity(
                    MarkerEntity(
                        marker: actualMarker,
                        state: updated[index].current.state,
                        isRendered: true
                    )
                )
            }
        }

        await renderer.onPostProcess()
        return true
    }

    private func applyUpdate<Renderer: MarkerOverlayRendererProtocol>(
        state: MarkerState,
        viewport: GeoRectBounds,
        renderer: Renderer
    ) async -> Bool where Renderer.ActualMarker == ActualMarker {
        guard let prevEntity = markerManager.getEntity(state.id) else { return true }
        let currentFingerPrint = state.fingerPrint()
        if currentFingerPrint == prevEntity.fingerPrint { return true }

        // ビューポート外でもマネージャ上の状態は最新にしておく。
        markerManager.registerEntity(
            MarkerEntity(
                marker: prevEntity.marker,
                state: state,
                visible: prevEntity.visible,
                isRendered: prevEntity.isRendered
            )
        )

        guard viewport.contains(point: state.position) else { return true }

        let markerIcon = state.icon?.toBitmapIcon() ?? defaultMarkerIcon
        let actualMarkers = await renderer.onChange(
            data: [
                MarkerOverlayChangeParams(
                    current: MarkerEntity(marker: prevEntity.marker, state: state),
                    bitmapIcon: markerIcon,
                    prev: prevEntity
                )
            ]
        )
        if let first = actualMarkers.first, let actualMarker = first {
            markerManager.registerEntity(
                MarkerEntity(marker: actualMarker, state: state, isRendered: true)
            )
        }
        return true
    }
}
