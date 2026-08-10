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

/// 全プロバイダ共通の state 実装。
///
/// カメラの保持と、コントローラへの委譲（``moveCameraTo(cameraPosition:durationMillis:)`` /
/// ``fitBounds(bounds:padding:)``）はどのプロバイダでも同じなのでここに置く。
/// プロバイダ固有なのは `mapDesignType` の型と、`getMapViewHolder()` の戻り型を絞る
/// オーバーライドだけ。android-sdk の `MapViewState` と同じ形。
///
/// - Parameters:
///   - id: state の識別子。省略すると UUID。
///   - initialCameraPosition: コントローラが繋がるまでの間、保持しておくカメラ。
///     ``attachController(_:moveToInitialCamera:)`` の時点でこの位置へ移動する。
///   - uiSettings: 初期のジェスチャ設定。
///   - optimisticCameraUpdate: ``moveCameraTo(cameraPosition:durationMillis:)`` で、
///     コントローラへ委譲する**前に**要求されたカメラを ``cameraPosition`` へ反映するか。
///
///     既定は `false`。地図のカメライベントが返ってきてから
///     ``setCameraPositionInternal(_:)`` で反映する（ネイティブ SDK は確実に
///     イベントを返すので、実際に適用された値だけが state に入る）。
///
///     `true` にするのは WebView ブリッジ越しのプロバイダ（MapTiler / Longdo）。
///     イベントの往復が遅く、要求直後に ``cameraPosition`` を読むと古い値が返ってしまうため。
open class MapViewState<ActualMapDesignType>: ObservableObject, MapViewStateProtocol {
    /// One registry per map, with the same lifetime as the state object.
    ///
    /// This is where Android uses `remember { MutableMapServiceRegistry() }` inside the
    /// provider's `MapView` composable: the object identity has to survive re-composition
    /// (here, re-evaluation of `body`) so a capability registered once when the map loads
    /// is still resolvable on every later content build.
    public let serviceRegistry = MutableMapServiceRegistry()

    private let stateId: String
    private let optimisticCameraUpdate: Bool

    @Published private var storedCameraPosition: MapCameraPosition
    @Published private var storedUISettings: MapUISettings

    /// 接続済みのコントローラ。まだ地図が生成されていなければ nil。
    ///
    /// 名前が `controller` でないのは、多くのプロバイダが自分のコントローラ型で
    /// `controller` フィールドを持っており、衝突させないため。プロバイダは
    /// 自前のフィールドを持ったまま ``attachController(_:moveToInitialCamera:)`` を呼べばよい。
    public private(set) var attachedMapController: (any MapViewControllerProtocol)?

    public init(
        id: String = UUID().uuidString,
        initialCameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings(),
        optimisticCameraUpdate: Bool = false
    ) {
        self.stateId = id
        self.storedCameraPosition = initialCameraPosition
        self.storedUISettings = uiSettings
        self.optimisticCameraUpdate = optimisticCameraUpdate
    }

    open var id: String { stateId }

    open var cameraPosition: MapCameraPosition { storedCameraPosition }

    open var mapDesignType: ActualMapDesignType {
        get { fatalError("Override in subclass") }
        set { fatalError("Override in subclass") }
    }

    open var uiSettings: MapUISettings {
        get { storedUISettings }
        set { storedUISettings = newValue }
    }

    /// コントローラを接続する。プロバイダの `setController` から呼ぶ。
    ///
    /// - Parameter moveToInitialCamera: 接続時に、保持していたカメラ位置へ移動するか。
    ///   既定は `true`。地図の生成直後にカメラを動かすと初期位置が上書きされてしまう
    ///   プロバイダ（ArcGIS は Scene のロード中に viewpointChanged が zoom~0 で
    ///   発火する。MapTiler / Longdo は WebView の ready 後に別経路で適用する）は
    ///   `false` を渡す。
    public func attachController(
        _ controller: (any MapViewControllerProtocol)?,
        moveToInitialCamera: Bool = true
    ) {
        attachedMapController = controller
        if let controller, moveToInitialCamera {
            controller.moveCamera(position: storedCameraPosition)
        }
    }

    /// コントローラを切り離す（地図の破棄時など）。
    public func detachController() {
        attachedMapController = nil
    }

    /// 地図から通知された現在のカメラを保持する（地図を動かさない）。
    ///
    /// プロバイダの `updateCameraPosition` から呼ぶ。カメラを**動かしたい**ときは
    /// ``moveCameraTo(cameraPosition:durationMillis:)`` を使うこと。
    ///
    /// `@Published` の更新はメインスレッドで行う必要があるので、必要なら hop する。
    public func setCameraPositionInternal(_ cameraPosition: MapCameraPosition) {
        if Thread.isMainThread {
            storedCameraPosition = cameraPosition
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.storedCameraPosition = cameraPosition
            }
        }
    }

    open func moveCameraTo(cameraPosition: MapCameraPosition, durationMillis: Long? = 0) {
        let resolved = resolveCameraPosition(cameraPosition)
        guard let controller = attachedMapController else {
            // まだ地図が無い。接続時に attachController がこの位置へ移動する。
            storedCameraPosition = resolved
            return
        }
        if optimisticCameraUpdate {
            storedCameraPosition = resolved
        }
        if let durationMillis, durationMillis > 0 {
            controller.animateCamera(position: resolved, duration: durationMillis)
        } else {
            controller.moveCamera(position: resolved)
        }
    }

    open func moveCameraTo(position: GeoPoint, durationMillis: Long? = 0) {
        let updated = cameraPosition.copy(position: position)
        moveCameraTo(cameraPosition: updated, durationMillis: durationMillis)
    }

    open func fitBounds(bounds: GeoRectBounds, padding: Int) {
        attachedMapController?.fitBounds(bounds: bounds, padding: padding)
    }

    /// 各プロバイダは戻り型を自分のホルダー型へ絞るオーバーライドを 1 つだけ置くこと。
    /// アプリが `state.getMapViewHolder()?.map` でネイティブの地図を取れる形を保つため、
    /// ここを継承で済ませてはいけない。
    open func getMapViewHolder() -> AnyMapViewHolder? {
        attachedMapController?.holder
    }

    /// ズーム・ベアリング・チルトがすべて 0 の「未指定」カメラは、位置だけを差し替える。
    ///
    /// アプリが `MapCameraPosition(position:)` だけを渡してきたときに、
    /// いまの縮尺を保ったまま移動するための救済。全プロバイダが同じ判定をしていた。
    private func resolveCameraPosition(_ target: MapCameraPosition) -> MapCameraPosition {
        let isUnspecified = target.zoom == 0.0 && target.bearing == 0.0 && target.tilt == 0.0
        if isUnspecified {
            return storedCameraPosition.copy(position: target.position)
        }
        return target
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
