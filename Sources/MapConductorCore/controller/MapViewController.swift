public typealias OnMapInitializedHandler = (InitState) -> Void

public protocol MapViewControllerProtocol {
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
}
