import Combine
import Foundation

/// Android の MarkerRenderingSupport パターンに対応する iOS 側の統合レイヤー。
/// updateStrategyRendering / syncStrategyMarkers のグルーコードを共通化し、
/// 各プロバイダーは makeRenderer ファクトリーのみ実装すればよい。
@MainActor
public final class StrategyMarkerManager<ActualMarker, Renderer: MarkerOverlayRendererProtocol>
where Renderer.ActualMarker == ActualMarker {
    public typealias RendererFactory = (AnyMarkerRenderingStrategy<ActualMarker>) -> Renderer

    public private(set) var controller: StrategyMarkerController<ActualMarker, AnyMarkerRenderingStrategy<ActualMarker>, Renderer>?
    public private(set) var renderer: Renderer?

    private var subscriptions: [String: AnyCancellable] = [:]
    private var statesById: [String: MarkerState] = [:]
    private var latestMarkers: [MarkerState] = []

    private let makeRenderer: RendererFactory
    private let shouldAddMarkers: () -> Bool

    /// - Parameters:
    ///   - makeRenderer: プロバイダー固有のレンダラーを生成するファクトリー。
    ///   - shouldAddMarkers: マーカーを今すぐ追加してよいか（Mapbox/MapLibre の style ロード確認など）。
    public init(
        makeRenderer: @escaping RendererFactory,
        shouldAddMarkers: @escaping () -> Bool = { true }
    ) {
        self.makeRenderer = makeRenderer
        self.shouldAddMarkers = shouldAddMarkers
    }

    /// MapViewContent が変化したときに呼ぶ。strategy がある場合は接続し、ない場合はクリア。
    public func update(content: MapViewContent, initialCamera: MapCameraPosition) {
        guard let strategy = content.markerRenderingStrategy as? AnyMarkerRenderingStrategy<ActualMarker> else {
            clear()
            return
        }
        if controller == nil || controller?.markerManager !== strategy.markerManager {
            renderer?.unbind()
            let r = makeRenderer(strategy)
            renderer = r
            controller = StrategyMarkerController(strategy: strategy, renderer: r)
            Task { [weak self] in
                await self?.controller?.onCameraChanged(mapCameraPosition: initialCamera)
            }
        }
        syncMarkers(content.markerRenderingMarkers)
    }

    /// カメラが変化したときに呼ぶ（visibleRegion 付きの position を渡すこと）。
    public func onCameraChanged(_ position: MapCameraPosition) async {
        await controller?.onCameraChanged(mapCameraPosition: position)
    }

    /// style ロード後など、shouldAddMarkers が true になったタイミングで未送信マーカーを再送する。
    public func flush() {
        guard !latestMarkers.isEmpty, let controller, shouldAddMarkers() else { return }
        let markers = latestMarkers
        Task { await controller.add(data: markers) }
    }

    /// strategy を解除してリソースを解放する。
    public func clear() {
        subscriptions.values.forEach { $0.cancel() }
        subscriptions.removeAll()
        statesById.removeAll()
        latestMarkers = []
        renderer?.unbind()
        renderer = nil
        controller?.destroy()
        controller = nil
    }

    private func syncMarkers(_ markers: [MarkerState]) {
        guard let controller else { return }
        let newIds = Set(markers.map { $0.id })
        let oldIds = Set(statesById.keys)
        var shouldSyncList = newIds != oldIds

        var newStatesById: [String: MarkerState] = [:]
        for state in markers {
            if let existing = statesById[state.id], existing !== state {
                subscriptions[state.id]?.cancel()
                subscriptions.removeValue(forKey: state.id)
                shouldSyncList = true
            }
            newStatesById[state.id] = state
        }
        statesById = newStatesById
        latestMarkers = markers

        for id in oldIds.subtracting(newIds) {
            subscriptions[id]?.cancel()
            subscriptions.removeValue(forKey: id)
        }

        if shouldSyncList && shouldAddMarkers() {
            Task { await controller.add(data: markers) }
        }

        for state in markers {
            guard subscriptions[state.id] == nil else { continue }
            subscriptions[state.id] = state.asFlow()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.statesById[state.id] != nil else { return }
                    Task { [weak self] in
                        await self?.controller?.update(state: state)
                    }
                }
        }
    }
}
