import Foundation

/// Shared ingestion logic for marker controllers.
///
/// Diffs incoming `MarkerState` lists against the current `MarkerManager` state,
/// drives the renderer for native markers, and tracks which markers should be
/// rendered as tiles instead.
///
/// - Note: Mirrors Android's `MarkerIngestionEngine` object.
public enum MarkerIngestionEngine {
    public struct Result {
        public let tiledDataChanged: Bool
        public let hasTiledMarkers: Bool
        /// Markers new to this controller that went into the tiles. They are not on
        /// the map until the provider has handed it the tile layer: once it has, it
        /// passes these to `addedTracker.admitAndNotify(_:)` for their `onAdded`.
        /// Natively drawn markers were already notified by `ingest`.
        public let tiledAdded: [MarkerState]

        public init(tiledDataChanged: Bool, hasTiledMarkers: Bool, tiledAdded: [MarkerState] = []) {
            self.tiledDataChanged = tiledDataChanged
            self.hasTiledMarkers = hasTiledMarkers
            self.tiledAdded = tiledAdded
        }
    }

    @MainActor
    public static func ingest<ActualMarker, Renderer: MarkerOverlayRendererProtocol>(
        data: [MarkerState],
        markerManager: MarkerManager<ActualMarker>,
        renderer: Renderer,
        defaultMarkerIcon: BitmapIcon,
        tilingEnabled: Bool,
        tiledMarkerIds: inout Set<String>,
        shouldTile: (MarkerState) -> Bool
    ) async -> Result where Renderer.ActualMarker == ActualMarker {
        await ingestImpl(
            data: data, markerManager: markerManager, renderer: renderer,
            defaultMarkerIcon: defaultMarkerIcon, tilingEnabled: tilingEnabled,
            tiledMarkerIds: &tiledMarkerIds, addedTracker: nil, shouldTile: shouldTile
        )
    }

    /// ``ingest(data:markerManager:renderer:defaultMarkerIcon:tilingEnabled:tiledMarkerIds:shouldTile:)``
    /// that also calls `onAdded` of the natively drawn markers it added, and
    /// returns the tiled ones in ``Result/tiledAdded`` for the provider to admit
    /// once its tile layer is on the map.
    @_spi(MapConductorDriver)
    @MainActor
    public static func ingest<ActualMarker, Renderer: MarkerOverlayRendererProtocol>(
        data: [MarkerState],
        markerManager: MarkerManager<ActualMarker>,
        renderer: Renderer,
        defaultMarkerIcon: BitmapIcon,
        tilingEnabled: Bool,
        tiledMarkerIds: inout Set<String>,
        addedTracker: OverlayAddedTracker,
        shouldTile: (MarkerState) -> Bool
    ) async -> Result where Renderer.ActualMarker == ActualMarker {
        await ingestImpl(
            data: data, markerManager: markerManager, renderer: renderer,
            defaultMarkerIcon: defaultMarkerIcon, tilingEnabled: tilingEnabled,
            tiledMarkerIds: &tiledMarkerIds, addedTracker: addedTracker, shouldTile: shouldTile
        )
    }

    @MainActor
    private static func ingestImpl<ActualMarker, Renderer: MarkerOverlayRendererProtocol>(
        data: [MarkerState],
        markerManager: MarkerManager<ActualMarker>,
        renderer: Renderer,
        defaultMarkerIcon: BitmapIcon,
        tilingEnabled: Bool,
        tiledMarkerIds: inout Set<String>,
        addedTracker: OverlayAddedTracker?,
        shouldTile: (MarkerState) -> Bool
    ) async -> Result where Renderer.ActualMarker == ActualMarker {
        addedTracker?.retain(Set(data.map(\.id)))
        var previousIds = Set(markerManager.allEntities().map { $0.state.id })
        var nativeAdded: [MarkerState] = []
        var tiledAdded: [MarkerState] = []
        var animatedEntities: [MarkerEntity<ActualMarker>] = []

        var added: [MarkerOverlayAddParams] = []
        var updated: [MarkerOverlayChangeParams<ActualMarker>] = []
        var removedEntities: [MarkerEntity<ActualMarker>] = []
        var tiledDataChanged = false

        for state in data {
            let wantsTiled = tilingEnabled && shouldTile(state)
            let markerIcon = state.icon?.toBitmapIcon() ?? defaultMarkerIcon

            if previousIds.contains(state.id) {
                let prevEntity = markerManager.getEntity(state.id)!
                let wasTiled = tiledMarkerIds.contains(state.id)

                if wantsTiled {
                    if !wasTiled {
                        if prevEntity.marker != nil {
                            removedEntities.append(prevEntity)
                        }
                        tiledMarkerIds.insert(state.id)
                    }
                    markerManager.updateEntity(MarkerEntity(
                        marker: nil,
                        state: state,
                        visible: prevEntity.visible,
                        isRendered: true,
                        tiling: true
                    ))
                    tiledDataChanged = true
                } else {
                    if wasTiled {
                        tiledMarkerIds.remove(state.id)
                        tiledDataChanged = true
                    }
                    updated.append(MarkerOverlayChangeParams(
                        current: MarkerEntity(
                            marker: prevEntity.marker,
                            state: state,
                            visible: prevEntity.visible,
                            isRendered: true,
                            // タイル担当から降ろす途中なので、レンダラには「直前まで
                            // タイルだった」ことを伝える。マネージャへ書き戻す最終 entity
                            // （下の onChange 後）は tiling = false になる。
                            tiling: wasTiled
                        ),
                        bitmapIcon: markerIcon,
                        prev: prevEntity
                    ))
                }
                previousIds.remove(state.id)
            } else {
                if wantsTiled {
                    tiledMarkerIds.insert(state.id)
                    tiledAdded.append(state)
                    markerManager.registerEntity(MarkerEntity(
                        marker: nil,
                        state: state,
                        visible: true,
                        isRendered: true,
                        tiling: true
                    ))
                    tiledDataChanged = true
                } else {
                    added.append(MarkerOverlayAddParams(state: state, bitmapIcon: markerIcon))
                }
            }
        }

        for remainId in previousIds {
            if let removedEntity = markerManager.removeEntity(remainId) {
                if tiledMarkerIds.remove(remainId) != nil {
                    tiledDataChanged = true
                } else if removedEntity.marker != nil {
                    removedEntities.append(removedEntity)
                }
            }
        }

        if !removedEntities.isEmpty {
            await renderer.onRemove(data: removedEntities)
        }

        if !added.isEmpty {
            let actualMarkers = await renderer.onAdd(data: added)
            for (index, actualMarker) in actualMarkers.enumerated() {
                guard let actualMarker else { continue }
                let state = added[index].state
                let entity = MarkerEntity(
                    marker: actualMarker,
                    state: state,
                    visible: true,
                    isRendered: true
                )
                markerManager.registerEntity(entity)
                nativeAdded.append(state)
                if state.getAnimation() != nil {
                    animatedEntities.append(entity)
                }
            }
        }

        if !updated.isEmpty {
            let actualMarkers = await renderer.onChange(data: updated)
            for (index, actualMarker) in actualMarkers.enumerated() {
                guard let actualMarker else { continue }
                let params = updated[index]
                let entity = MarkerEntity(
                    marker: actualMarker,
                    state: params.current.state,
                    visible: params.current.visible,
                    isRendered: true
                )
                markerManager.updateEntity(entity)
                if params.current.state.getAnimation() != nil {
                    animatedEntities.append(entity)
                }
            }
        }

        for entity in animatedEntities {
            await renderer.onAnimate(entity: entity)
        }

        await renderer.onPostProcess()

        if let addedTracker {
            await addedTracker.admitAndNotify(nativeAdded)
        }

        return Result(
            tiledDataChanged: tiledDataChanged,
            hasTiledMarkers: !tiledMarkerIds.isEmpty,
            tiledAdded: tiledAdded
        )
    }
}
