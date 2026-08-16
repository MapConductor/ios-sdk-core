import CoreGraphics

public final class StrategyMarkerController<ActualMarker, Strategy: MarkerRenderingStrategyProtocol, Renderer: MarkerOverlayRendererProtocol>: OverlayControllerProtocol, SlottedOverlayController
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

    /// 下の 3 つを守る。**このクラスは actor でも @MainActor でもない**ので、
    /// 同期はこれだけが頼り。
    ///
    /// ## ★ 3 つのフィールドを permit の外で触らないこと
    ///
    /// プロバイダのホストは `regionIsChanging` ごとに
    /// `Task { await strategyManager.onCameraChanged(camera) }` を投げる。
    /// カメラアニメーション中は CADisplayLink で **60Hz** なので、
    /// 独立したタスクが数十本、協調スレッド上で同時に走る。
    ///
    /// `mapCameraPosition` / `lastKnownBounds` / `pendingStates` の中身は
    /// **すべて class**（`MapCameraPosition` / `GeoRectBounds` / `MarkerState`）。
    /// 無同期に代入すると retain/release が競り、**過剰解放**になる。実機では
    ///   - `swift_deallocClassInstance` の fatalError、または
    ///   - `BUG IN CLIENT OF LIBMALLOC: memory corruption of free block`
    /// として落ちた（reactnative-for-maptiler のクラスタータップ、iPad 実機）。
    /// **間欠**で、しかも ASan を有効にすると再現しなくなる（配置とタイミングが変わる）。
    /// 落ちる場所（malloc / dealloc）と原因の場所は一致しないので、
    /// クラッシュログの最上段を読んでも辿り着けない。
    ///
    /// 症状が出たのは MapTiler だが、原因はここなので**全プロバイダが同じ穴**を持つ。
    private let semaphore = AsyncSemaphore(1)
    /// 以下 3 つは [semaphore] の permit を持っている間だけ読み書きしてよい。
    private var mapCameraPosition: MapCameraPosition?
    private var lastKnownBounds: GeoRectBounds?
    private var pendingStates: [MarkerState]?

    /// 最新のカメラだけを残す箱。``onCameraChanged(mapCameraPosition:)`` を参照。
    ///
    /// **[semaphore] では守れない。** permit を**取る前**に触る必要があるため、
    /// 独立した actor にしてある。
    private let latestCamera = LatestCameraBox()

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
        await semaphore.withPermit { await addLocked(data: data) }
    }

    /// ``add(data:)`` の中身。**呼び出し側が permit を持っていること。**
    /// ``onCameraChanged(mapCameraPosition:)`` が保留分を流すときに、
    /// permit を持ったまま呼ぶ（``AsyncSemaphore`` は再入できないので
    /// `add(data:)` をそのまま呼ぶとデッドロックする）。
    private func addLocked(data: [MarkerState]) async {
        guard let bounds = mapCameraPosition?.visibleRegion?.bounds ?? lastKnownBounds else {
            pendingStates = data
            return
        }
        _ = await strategy.onAdd(
            data: data,
            viewport: bounds,
            renderer: renderer
        )
    }

    public func update(state: MarkerState) async {
        await semaphore.withPermit {
            guard let bounds = mapCameraPosition?.visibleRegion?.bounds ?? lastKnownBounds else { return }
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

    /// カメラ変更を受けて再クラスタリングする。
    ///
    /// ## ★ 中間フレームは畳む（coalescing）
    ///
    /// プロバイダのホストは `regionIsChanging` ごとに
    /// `Task { await strategyManager.onCameraChanged(camera) }` を投げる。
    /// CADisplayLink は 60Hz なので **600ms のアニメーションで約 36 本**積み上がり、
    /// 以前はその**一本ずつが全件の再クラスタリングを走らせていた**
    /// （Post Office Cluster は 24,526 件）。permit で直列化してあるので
    /// 落ちはしないが、アニメーションが終わってからも積み残しを消化し続ける。
    ///
    /// ここでは「最新のカメラだけ」を [latestCamera] に置き、permit を取れた側が
    /// それを**取り出して**処理する。待っている間に後発が来ていれば、
    /// 箱の中身は後発の値に置き換わっているので、**中間のフレームは捨てられる**。
    /// 箱が空なら（＝自分より後に permit を取った誰かが既に最新を処理した）
    /// 再クラスタリングは省く。
    ///
    /// **最後のカメラは必ず処理される。** 箱に置いてから permit を待つので、
    /// 最後に置かれた値を誰かが必ず取り出す。
    ///
    /// 挙動の変化: アニメーション中のクラスタ更新の**頻度**が下がる（毎フレーム
    /// ではなくなる）。終了時の見た目は変わらない。
    public func onCameraChanged(mapCameraPosition: MapCameraPosition) async {
        await latestCamera.store(mapCameraPosition)
        await semaphore.withPermit {
            if let camera = await latestCamera.take() {
                self.mapCameraPosition = camera
                if let bounds = camera.visibleRegion?.bounds {
                    lastKnownBounds = bounds
                }
                await strategy.onCameraChanged(
                    mapCameraPosition: camera,
                    renderer: renderer
                )
            }

            // 保留分は再クラスタリングを省いた側でも流す。bounds が分かった時点で
            // 流したいのであって、どのタスクが流すかは問わない。
            if let pending = pendingStates {
                pendingStates = nil
                await addLocked(data: pending)
            }
        }
    }

    public func destroy() {
        strategy.clear()
    }
    // ── SlottedOverlayController ────────────────────────────────────────
    //
    // kind は**必須メンバ**。既定値を持たせると、宣言忘れがコンパイルを通ってしまい
    // カスケードとスロットから黙って漏れる（android-sdk で実際に踏んだ）。

    public var kind: OverlayKind { .marker }

    public func hasId(_ id: String) -> Bool {
        markerManager.hasEntity(id)
    }

    /// マーカーは別経路。ここでは当たらない。
    public func resolveTap(position _: GeoPointProtocol) -> OverlayHit? { nil }

}

/// ``StrategyMarkerController/onCameraChanged(mapCameraPosition:)`` が
/// 最新のカメラだけを残すための箱。
///
/// **なぜ `AsyncSemaphore` ではなく actor なのか。** この箱は
/// `StrategyMarkerController` の permit を**取る前**に触る必要がある。
/// permit の中に入れてしまうと畳む意味がなくなり（結局全タスクが待つ）、
/// かといって素の可変フィールドにすると、まさにこのファイルが避けている
/// 「無同期の代入による過剰解放」（`MapCameraPosition` は class）を作り込む。
/// actor なら permit と独立に、かつ安全に読み書きできる。
private actor LatestCameraBox {
    private var camera: MapCameraPosition?

    /// 置き換える。直前の値は捨てる（＝中間フレームを畳む）。
    func store(_ camera: MapCameraPosition) {
        self.camera = camera
    }

    /// 取り出して空にする。空なら nil。
    func take() -> MapCameraPosition? {
        defer { camera = nil }
        return camera
    }
}
