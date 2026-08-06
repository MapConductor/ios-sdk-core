import Combine
import Foundation

public enum InitState {
    case NotStarted
    case Initializing
    case SdkInitialized
    case MapViewCreated
    case MapCreating
    case MapCreated
    case MapLoaded
    case Failed
}

public protocol MapViewStateProtocol: ObservableObject {
    associatedtype ActualMapDesignType

    var id: String { get }
    /// 現在のカメラ。**カメラを読む正規の経路はここ**で、表示範囲は
    /// `cameraPosition.visibleRegion?.bounds` から取る。
    ///
    /// プロバイダが地図 SDK のカメライベントごとに push する。変化を追いたい場合は
    /// `onCameraMove` / `onCameraMoveEnd`、拡張モジュールは登録した
    /// オーバーレイコントローラの `onCameraChanged` を使う。
    ///
    /// コントローラ側に `getCameraPosition()` / `getBounds()` を足さないこと。
    /// 理由は ``MapViewControllerProtocol`` のコメントと /docs/reading-camera を参照。
    var cameraPosition: MapCameraPosition { get }
    var mapDesignType: ActualMapDesignType { get set }
    var uiSettings: MapUISettings { get set }

    /// Map-scoped registry the provider populates with its capabilities and add-on
    /// modules resolve from. See ``MapServiceRegistry``.
    var serviceRegistry: MutableMapServiceRegistry { get }

    func moveCameraTo(cameraPosition: MapCameraPosition, durationMillis: Long?)
    func moveCameraTo(position: GeoPoint, durationMillis: Long?)

    func fitBounds(bounds: GeoRectBounds, padding: Int)

    func getMapViewHolder() -> AnyMapViewHolder?
}

public extension MapViewStateProtocol {
    func moveCameraTo(cameraPosition: MapCameraPosition) {
        moveCameraTo(cameraPosition: cameraPosition, durationMillis: 0)
    }

    func moveCameraTo(position: GeoPoint) {
        moveCameraTo(position: position, durationMillis: 0)
    }
}

open class MapViewState<ActualMapDesignType>: ObservableObject, MapViewStateProtocol {
    /// One registry per map, with the same lifetime as the state object.
    ///
    /// This is where Android uses `remember { MutableMapServiceRegistry() }` inside the
    /// provider's `MapView` composable: the object identity has to survive re-composition
    /// (here, re-evaluation of `body`) so a capability registered once when the map loads
    /// is still resolvable on every later content build.
    public let serviceRegistry = MutableMapServiceRegistry()

    public init() {}

    open var id: String {
        fatalError("Override in subclass")
    }

    open var cameraPosition: MapCameraPosition {
        fatalError("Override in subclass")
    }

    open var mapDesignType: ActualMapDesignType {
        get { fatalError("Override in subclass") }
        set { fatalError("Override in subclass") }
    }

    open var uiSettings: MapUISettings {
        get { fatalError("Override in subclass") }
        set { fatalError("Override in subclass") }
    }

    open func moveCameraTo(cameraPosition: MapCameraPosition, durationMillis: Long?) {
        fatalError("Override in subclass")
    }

    open func moveCameraTo(position: GeoPoint, durationMillis: Long?) {
        let updated = cameraPosition.copy(position: position)
        moveCameraTo(cameraPosition: updated, durationMillis: durationMillis)
    }

    open func fitBounds(bounds: GeoRectBounds, padding: Int) {
        fatalError("Override in subclass")
    }

    open func getMapViewHolder() -> AnyMapViewHolder? {
        fatalError("Override in subclass")
    }
}

public protocol MapOverlayProtocol: AnyObject {
    associatedtype DataType

    var flow: CurrentValueSubject<[String: DataType], Never> { get }

    func render(
        data: [String: DataType],
        controller: MapViewControllerProtocol
    ) async
}

public final class MapOverlayRegistry {
    private var overlays: [any MapOverlayProtocol] = []

    public init() {}

    public func register(overlay: any MapOverlayProtocol) {
        if overlays.contains(where: { $0 === overlay }) { return }
        overlays.append(overlay)
    }

    public func getAll() -> [any MapOverlayProtocol] {
        overlays
    }
}
