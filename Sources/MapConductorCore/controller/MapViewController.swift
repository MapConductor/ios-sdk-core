public typealias OnMapInitializedHandler = (InitState) -> Void

public protocol MapViewControllerProtocol {
    // ┌──────────────────────────────────────────────────────────────────────┐
    // │ getCameraPosition() / getBounds() をここに足さないこと。              │
    // │ DO NOT add a camera getter to this protocol.                         │
    // └──────────────────────────────────────────────────────────────────────┘
    //
    // 解説ページ: /docs/reading-camera
    //
    // 1. 宣言的 UI（SwiftUI）では状態の出どころを 1 つにする。カメラは状態なので
    //    置き場所は MapViewState。ここに getter を足すと state と SDK 直読みの
    //    2 系統になり、ズレる余地だけが増える。
    //
    // 2. push 型で設計されている。地図 SDK のカメライベント → プロバイダが生値を
    //    統一ズームへ変換し visibleRegion を載せる → MapViewState へ反映 →
    //    mapViewState.cameraPosition / onCameraMove / onCameraMoveEnd /
    //    登録済みオーバーレイの onCameraChanged。取りに行く必要がない。
    //
    // 3. pull は安くない。1 回の呼び出しで画面 4 隅の逆投影をして visibleRegion を
    //    組み立てる。単なるゲッターではない。
    //
    // 4. react-sdk には一時期これがあり、2026-08-06 に外した。実測では
    //    1 ドラッグあたり 86 回 → 30 回（約 65% 減）。減った分はすべて
    //    「直前に push したのと同じ値の作り直し」で、操作中だけ効くコストだった。
    //
    // 5. state は「最後に push された値」なので理屈のうえでは 1 フレーム古いが、
    //    onCameraMove は移動中も発火するため体感差はない。
    //
    // 生値がどうしても要る場合は `holder` からネイティブの地図を取ること。
    // 各プロバイダは private な currentCameraPosition(from:) を持っているが、それは
    // カメライベントに載せる値を組み立てるための実装であり、公開しない。
    var holder: AnyMapViewHolder { get }
    var coroutine: CoroutineScope { get }

    func clearOverlays() async

    func setCameraMoveStartListener(listener: OnCameraMoveHandler?)
    func setCameraMoveListener(listener: OnCameraMoveHandler?)
    func setCameraMoveEndListener(listener: OnCameraMoveHandler?)

    func setMapClickListener(listener: OnMapEventHandler?)
    func setMapLongClickListener(listener: OnMapEventHandler?)

    func setMapInitializedListener(listener: OnMapInitializedHandler?)

    func moveCamera(position: MapCameraPosition)

    func animateCamera(position: MapCameraPosition, duration: Long)

    func fitBounds(bounds: GeoRectBounds, padding: Int)

    /// この地図に紐づくオーバーレイコントローラの登録簿。
    ///
    /// 各プロバイダのコントローラが 1 つ保持する。
    /// android-sdk では `BaseMapViewController` がこの状態を持ち、
    /// `registerOverlayController` を提供している。
    var overlayControllers: OverlayControllerRegistry { get }

    /// 地図を破棄する／プロバイダを差し替えるときに呼ぶ後始末。
    ///
    /// android-sdk の `MapViewControllerInterface.destroy()`、
    /// react-sdk の `destroy()` に対応する。
    /// 既定実装は登録済みオーバーレイコントローラをすべて破棄する。
    /// ネイティブ資源を持つプロバイダは override して、`super` 相当として
    /// `overlayControllers.destroyAll()` を必ず呼ぶこと。
    func destroy()

    /// ジェスチャ等の UI 設定を地図へ適用する。
    ///
    /// android-sdk の `fun applyUISettings(settings: MapUISettings) {}` に対応する。
    /// 自分の SDK でジェスチャを切り替えられるプロバイダだけが実装し、既定は何もしない。
    func applyUISettings(_ settings: MapUISettings)

    /// カメラの可動範囲（パン範囲・ズーム上下限）を制限する。
    ///
    /// android-sdk の `MapViewControllerInterface.setCameraRestriction` の移植。
    ///
    /// - Google / Mapbox : ネイティブの範囲制限 API（`cameraTargetBounds` /
    ///   `CameraBoundsOptions`）で制限する。
    /// - MapLibre / MapTiler : ズームはネイティブ、パン範囲はジェスチャー拒否
    ///   （`MLNMapViewDelegate.mapView(_:shouldChangeFrom:to:reason:)`）＋
    ///   プログラム移動のクランプで制限する。
    /// - HERE / ArcGIS / TomTom / MapKit / Longdo : ネイティブに範囲制限の手段が無いため、
    ///   カメラ停止時に中心座標・ズームを矩形内へクランプして再適用する
    ///   （``CameraRestrictionClamp``）。
    ///
    /// ズームは統一ズーム（Google 準拠）で指定し、各プロバイダが自身の体系へ変換する。
    /// `nil` または空の ``CameraRestriction`` で制限解除。既定実装は何もしない。
    func setCameraRestriction(_ restriction: CameraRestriction?)
}

public extension MapViewControllerProtocol {
    /// android-sdk の `fun setCameraRestriction(restriction: CameraRestriction?) {}` と同じく、
    /// 未対応プロバイダでは何もしない既定実装。
    func setCameraRestriction(_ restriction: CameraRestriction?) {}

    /// オーバーレイコントローラを登録し、カメラ変更を受け取れるようにする。
    ///
    /// android-sdk の `MapViewControllerInterface.registerOverlayController`、
    /// react-sdk の `registerOverlayController?` に対応する。
    /// 拡張モジュールはこれを使うこと。地図コントローラのリスナー
    /// （`setCameraMoveEndListener` など）は単一スロットなので、拡張が 2 つ載ると
    /// 互いに上書きしてしまう。
    func registerOverlayController(_ controller: any AnyOverlayController) {
        overlayControllers.register(controller)
    }

    /// 登録を取り消す。登録した側は破棄時に必ず呼ぶこと。
    /// 地図を破棄せずプロバイダだけ差し替える利用者がいるため、
    /// 解除漏れは前のプロバイダのレンダラを掴んだままになる。
    func unregisterOverlayController(_ controller: any AnyOverlayController) {
        overlayControllers.unregister(controller)
    }

    /// 既定の後始末。登録済みオーバーレイコントローラをすべて破棄する。
    func destroy() {
        overlayControllers.destroyAll()
    }

    /// android-sdk と同じく、未対応プロバイダでは何もしない既定実装。
    func applyUISettings(_ settings: MapUISettings) {}
}
