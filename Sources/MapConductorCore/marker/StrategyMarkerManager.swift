import Combine
import Foundation

/// Android の MarkerRenderingSupport パターンに対応する iOS 側の統合レイヤー。
/// updateStrategyRendering / syncStrategyMarkers のグルーコードを共通化し、
/// 各プロバイダーは makeRenderer ファクトリーのみ実装すればよい。
@MainActor
public final class StrategyMarkerManager<ActualMarker, Renderer: MarkerOverlayRendererProtocol>: MarkerRenderingSupport
where Renderer.ActualMarker == ActualMarker {
    public typealias RendererFactory = (AnyMarkerRenderingStrategy<ActualMarker>) -> Renderer

    public private(set) var controller: StrategyMarkerController<ActualMarker, AnyMarkerRenderingStrategy<ActualMarker>, Renderer>?
    public private(set) var renderer: Renderer?

    private var subscriptions: [String: AnyCancellable] = [:]
    private var statesById: [String: MarkerState] = [:]

    /// 接続中の strategy が描画するマーカーの現在値。プロバイダ側のアイコンキャッシュ等が参照する。
    public private(set) var latestMarkers: [MarkerState] = []

    /// `latestMarkers` が変化したときにプロバイダへ通知する。
    /// Android の `MarkerRenderingSupport.onMarkerRenderingReady()` に相当する戻りの口で、
    /// 以前は各プロバイダが `MapViewContent.markerRenderingMarkers` を直接読んでいた。
    public var onMarkersChanged: (([MarkerState]) -> Void)?

    /// 新しいレンダラーを生成した直後に呼ぶ。style ロード済みのプロバイダが、
    /// 生成直後のレンダラーへ style を渡すために使う（MapLibre / MapTiler）。
    /// 以前は updateContent 内で renderer の前後比較をしていたが、生成タイミングが
    /// content 構築中へ移ったため通知に置き換えた。
    public var onRendererCreated: ((Renderer) -> Void)?

    private var connectedThisPass = false

    private let makeRenderer: RendererFactory
    private let shouldAddMarkers: () -> Bool
    private let currentCamera: () -> MapCameraPosition?

    /// - Parameters:
    ///   - makeRenderer: プロバイダー固有のレンダラーを生成するファクトリー。
    ///   - shouldAddMarkers: マーカーを今すぐ追加してよいか（Mapbox/MapLibre の style ロード確認など）。
    ///   - currentCamera: 接続直後に strategy へ渡す現在のカメラ。nil を返す間は初回通知を見送る。
    public init(
        makeRenderer: @escaping RendererFactory,
        shouldAddMarkers: @escaping () -> Bool = { true },
        currentCamera: @escaping () -> MapCameraPosition? = { nil }
    ) {
        self.makeRenderer = makeRenderer
        self.shouldAddMarkers = shouldAddMarkers
        self.currentCamera = currentCamera
    }

    /// ``MarkerRenderingSupport`` の実装。クラスタリング側が
    /// ``MapServiceRegistry`` からこのマネージャを引き当てて呼ぶ。
    /// 以前は各プロバイダが `MapViewContent.markerRenderingStrategy` を毎回覗いて
    /// いたが、Core からプラグイン専用フィールドを無くすため呼ぶ側を反転した。
    @discardableResult
    public func connect(strategy: Any, markers: [MarkerState]) -> Bool {
        guard let strategy = strategy as? AnyMarkerRenderingStrategy<ActualMarker> else {
            return false
        }
        connectedThisPass = true
        if controller == nil || controller?.markerManager !== strategy.markerManager {
            renderer?.unbind()
            let r = makeRenderer(strategy)
            renderer = r
            controller = StrategyMarkerController(strategy: strategy, renderer: r)
            onRendererCreated?(r)
            // Clear cached marker state so syncMarkers re-sends all markers to the
            // new controller/strategy instance that has an empty marker registry.
            // Without this, syncMarkers sees "no change" and the new strategy starts
            // with zero markers — stale hull polygons are never cleaned up, and new
            // clusters never appear until the next content diff that changes IDs.
            subscriptions.values.forEach { $0.cancel() }
            subscriptions.removeAll()
            statesById = [:]
            if let initialCamera = currentCamera() {
                Task { [weak self] in
                    await self?.controller?.onCameraChanged(mapCameraPosition: initialCamera)
                }
            }
        }
        syncMarkers(markers)
        return true
    }

    /// 接続中の strategy を解除する。``MarkerRenderingSupport`` の実装。
    public func disconnect() {
        clear()
    }

    /// ``MarkerRenderingSupport`` の実装。プロバイダが content 評価の前後で呼ぶ。
    public func beginContentPass() {
        connectedThisPass = false
    }

    /// ``MarkerRenderingSupport`` の実装。content にプラグインが現れなかったパスでは解除する。
    public func endContentPass() {
        if !connectedThisPass, controller != nil {
            clear()
        }
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
        if !latestMarkers.isEmpty {
            latestMarkers = []
            onMarkersChanged?([])
        }
        renderer?.unbind()
        renderer = nil
        controller?.destroy()
        controller = nil
    }

    /// 接続中の strategy へ現在のマーカー一覧を反映する。``MarkerRenderingSupport`` の実装。
    public func syncMarkers(_ markers: [MarkerState]) {
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
        let markersChanged = latestMarkers.count != markers.count || shouldSyncList
        latestMarkers = markers
        if markersChanged { onMarkersChanged?(markers) }

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
