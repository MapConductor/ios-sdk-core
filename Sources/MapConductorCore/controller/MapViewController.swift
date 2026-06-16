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
}
