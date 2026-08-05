import CoreGraphics

public final class StrategyMarkerController<ActualMarker, Strategy: MarkerRenderingStrategyProtocol, Renderer: MarkerOverlayRendererProtocol>: OverlayControllerProtocol
where Strategy.ActualMarker == ActualMarker, Renderer.ActualMarker == ActualMarker {
    public typealias StateType = MarkerState
    public typealias EntityType = MarkerEntity<ActualMarker>
    public typealias EventType = MarkerState

    public let markerManager: MarkerManager<ActualMarker>
    public let strategy: Strategy
    public var renderer: Renderer
    public var clickListener: ((MarkerState) -> Void)?

    /// タップのヒットテスト用に地理座標をビューのスクリーン座標（ポイント）へ投影する。
    /// プロバイダが @MainActor の MapView を捕捉した closure を注入する。未設定のとき
    /// find() は距離判定なしで最近傍を返す（投影不可プロバイダ向けの従来動作）。
    public var markerProjector: ((GeoPointProtocol) -> CGPoint?)?

    public var dragStartListener: OnMarkerEventHandler?
    public var dragListener: OnMarkerEventHandler?
    public var dragEndListener: OnMarkerEventHandler?
    public var animateStartListener: OnMarkerEventHandler?
    public var animateEndListener: OnMarkerEventHandler?

    public let zIndex: Int = 10
    private let semaphore = AsyncSemaphore(1)
    private var mapCameraPosition: MapCameraPosition?
    private var lastKnownBounds: GeoRectBounds?
    private var pendingStates: [MarkerState]?

    public init(
        strategy: Strategy,
        renderer: Renderer,
        clickListener: ((MarkerState) -> Void)? = nil
    ) {
        self.strategy = strategy
        self.renderer = renderer
        self.markerManager = strategy.markerManager
        self.clickListener = clickListener

        Task { @MainActor in
            self.renderer.animateStartListener = { [weak self] state in
                self?.dispatchAnimateStart(state)
            }
            self.renderer.animateEndListener = { [weak self] state in
                self?.dispatchAnimateEnd(state)
            }
        }
    }

    public func dispatchClick(_ state: MarkerState) {
        state.onClick?(state)
        clickListener?(state)
    }

    public func dispatchDragStart(_ state: MarkerState) {
        state.onDragStart?(state)
        dragStartListener?(state)
    }

    public func dispatchDrag(_ state: MarkerState) {
        state.onDrag?(state)
        dragListener?(state)
    }

    public func dispatchDragEnd(_ state: MarkerState) {
        state.onDragEnd?(state)
        dragEndListener?(state)
    }

    public func dispatchAnimateStart(_ state: MarkerState) {
        state.onAnimateStart?(state)
        animateStartListener?(state)
    }

    public func dispatchAnimateEnd(_ state: MarkerState) {
        state.onAnimateEnd?(state)
        animateEndListener?(state)
    }

    public func add(data: [MarkerState]) async {
        guard let bounds = mapCameraPosition?.visibleRegion?.bounds ?? lastKnownBounds else {
            pendingStates = data
            return
        }
        await semaphore.withPermit {
            _ = await strategy.onAdd(
                data: data,
                viewport: bounds,
                renderer: renderer
            )
        }
    }

    public func update(state: MarkerState) async {
        guard let bounds = mapCameraPosition?.visibleRegion?.bounds ?? lastKnownBounds else { return }
        await semaphore.withPermit {
            _ = await strategy.onUpdate(
                state: state,
                viewport: bounds,
                renderer: renderer
            )
        }
    }

    public func clear() async {
        strategy.clear()
    }

    public func find(position: GeoPointProtocol) -> MarkerEntity<ActualMarker>? {
        guard let nearest = markerManager.findNearest(position: position) else { return nil }
        // android-sdk の StrategyMarkerController.find() と同じスクリーン空間の
        // 「アイコン境界 + tapTolerance」矩形判定。投影 closure 未設定のときは従来どおり
        // 最近傍をそのまま返す（geo→screen 投影ができないプロバイダ向けフォールバック）。
        guard let projector = markerProjector,
              let touchScreen = projector(position),
              let markerScreen = projector(nearest.state.position) else {
            return nearest
        }
        return MarkerHitTest.hitsIcon(
            touchScreen: touchScreen,
            markerScreen: markerScreen,
            state: nearest.state
        ) ? nearest : nil
    }

    public func onCameraChanged(mapCameraPosition: MapCameraPosition) async {
        self.mapCameraPosition = mapCameraPosition
        if let bounds = mapCameraPosition.visibleRegion?.bounds {
            lastKnownBounds = bounds
        }
        await semaphore.withPermit {
            await strategy.onCameraChanged(
                mapCameraPosition: mapCameraPosition,
                renderer: renderer
            )
        }

        if let pending = pendingStates {
            pendingStates = nil
            await add(data: pending)
        }
    }

    public func destroy() {
        strategy.clear()
    }
}
