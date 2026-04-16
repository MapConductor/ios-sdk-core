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
        var previousIds = Set(markerManager.allEntities().map { $0.state.id })
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
                        isRendered: true
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
                            isRendered: true
                        ),
                        bitmapIcon: markerIcon,
                        prev: prevEntity
                    ))
                }
                previousIds.remove(state.id)
            } else {
                if wantsTiled {
                    tiledMarkerIds.insert(state.id)
                    markerManager.registerEntity(MarkerEntity(
                        marker: nil,
                        state: state,
                        visible: true,
                        isRendered: true
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

        return Result(
            tiledDataChanged: tiledDataChanged,
            hasTiledMarkers: !tiledMarkerIds.isEmpty
        )
    }
}
