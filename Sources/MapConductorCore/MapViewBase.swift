import SwiftUI
import UIKit

// MARK: - MapViewHandlers

/// Bundles the event handlers every provider map view accepts, so provider
/// views, representables and coordinators pass one value around instead of
/// seven individual closures.
public struct MapViewHandlers<State: MapViewStateProtocol> {
    public let onMapLoaded: OnMapLoadedHandler<State>?
    public let onMapClick: OnMapEventHandler?
    public let onMapLongClick: OnMapEventHandler?
    public let onCameraMoveStart: OnCameraMoveHandler?
    public let onCameraMove: OnCameraMoveHandler?
    public let onCameraMoveEnd: OnCameraMoveHandler?
    public let sdkInitialize: (() -> Void)?

    public init(
        onMapLoaded: OnMapLoadedHandler<State>? = nil,
        onMapClick: OnMapEventHandler? = nil,
        onMapLongClick: OnMapEventHandler? = nil,
        onCameraMoveStart: OnCameraMoveHandler? = nil,
        onCameraMove: OnCameraMoveHandler? = nil,
        onCameraMoveEnd: OnCameraMoveHandler? = nil,
        sdkInitialize: (() -> Void)? = nil
    ) {
        self.onMapLoaded = onMapLoaded
        self.onMapClick = onMapClick
        self.onMapLongClick = onMapLongClick
        self.onCameraMoveStart = onCameraMoveStart
        self.onCameraMove = onCameraMove
        self.onCameraMoveEnd = onCameraMoveEnd
        self.sdkInitialize = sdkInitialize
    }
}

// MARK: - MapViewBase

/// Shared SwiftUI host for the provider map views. It layers, in the same
/// order on every provider:
///
/// 1. the provider's native map view (`mapContent`)
/// 2. the view-based overlays declared through the content DSL (`content.views`)
/// 3. the map attribution overlay
/// 4. optional provider-specific top layers (`topContent`)
public struct MapViewBase<MapContent: View, TopContent: View>: View {
    private let attributionRules: [AttributionRule]
    private let camera: MapCameraPositionProtocol
    private let content: MapViewContent
    private let mapContent: () -> MapContent
    private let topContent: () -> TopContent

    public init(
        attributionRules: [AttributionRule],
        camera: MapCameraPositionProtocol,
        content: MapViewContent,
        @ViewBuilder mapContent: @escaping () -> MapContent,
        @ViewBuilder topContent: @escaping () -> TopContent
    ) {
        self.attributionRules = attributionRules
        self.camera = camera
        self.content = content
        self.mapContent = mapContent
        self.topContent = topContent
    }

    public var body: some View {
        ZStack {
            mapContent()
            ForEach(0..<content.views.count, id: \.self) { index in
                content.views[index]
            }
            MapAttributionOverlay(
                designRules: attributionRules,
                rasterLayers: content.rasterLayers,
                camera: camera
            )
            topContent()
        }
    }
}

public extension MapViewBase where TopContent == EmptyView {
    init(
        attributionRules: [AttributionRule],
        camera: MapCameraPositionProtocol,
        content: MapViewContent,
        @ViewBuilder mapContent: @escaping () -> MapContent
    ) {
        self.init(
            attributionRules: attributionRules,
            camera: camera,
            content: content,
            mapContent: mapContent,
            topContent: { EmptyView() }
        )
    }
}

// MARK: - MapViewCoordinatorBase

/// Tracks which concrete coordinator classes already ran their one-time SDK
/// initialization. Stored outside the class because generic classes cannot
/// have stored static properties.
@MainActor private var sdkInitializedCoordinatorTypes: Set<ObjectIdentifier> = []

/// Common base class for the provider map view coordinators. Holds the map
/// state and event handlers, the shared info-bubble container, the once-only
/// map-loaded dispatch and the per-provider once-only SDK initialization.
@MainActor
open class MapViewCoordinatorBase<State: MapViewStateProtocol>: NSObject {
    public let state: State
    public let handlers: MapViewHandlers<State>
    public let infoBubbleContainer = PassthroughContainerView()
    public private(set) var didCallMapLoaded = false

    public init(state: State, handlers: MapViewHandlers<State>) {
        self.state = state
        self.handlers = handlers
        super.init()
    }

    // Convenience accessors so provider code reads the same as before.
    public var onMapLoaded: OnMapLoadedHandler<State>? { handlers.onMapLoaded }
    public var onMapClick: OnMapEventHandler? { handlers.onMapClick }
    public var onMapLongClick: OnMapEventHandler? { handlers.onMapLongClick }
    public var onCameraMoveStart: OnCameraMoveHandler? { handlers.onCameraMoveStart }
    public var onCameraMove: OnCameraMoveHandler? { handlers.onCameraMove }
    public var onCameraMoveEnd: OnCameraMoveHandler? { handlers.onCameraMoveEnd }

    /// Runs `initializer` once per concrete coordinator class (i.e. once per
    /// provider), no matter how many map views are created.
    public static func runOnce(_ initializer: () -> Void) {
        let key = ObjectIdentifier(self)
        if sdkInitializedCoordinatorTypes.contains(key) { return }
        sdkInitializedCoordinatorTypes.insert(key)
        initializer()
    }

    /// Dispatches the map-loaded notification exactly once per coordinator.
    public func performMapLoadedOnce(_ body: () -> Void) {
        guard !didCallMapLoaded else { return }
        didCallMapLoaded = true
        body()
    }

    /// ビューから最後に要求されたカメラ制限。二重 optional なのは「まだ一度も要求されていない」と
    /// 「`nil`（制限なし）を要求済み」を区別するため。
    private var requestedCameraRestriction: CameraRestriction??
    /// 実際にコントローラへ適用済みのカメラ制限。
    private var appliedCameraRestriction: CameraRestriction??

    /// `restriction` が前回適用時から変わっているときだけ `controller` へ適用する。
    ///
    /// android-sdk の各 `*MapView.kt` がコントローラ生成直後に
    /// `cameraRestriction?.let { controller.setCameraRestriction(it) }` を呼ぶのに対応する。
    /// iOS の `updateUIView` は SwiftUI の更新ごとに走るため、変化検知を挟んで
    /// ネイティブ API の呼び出し回数を抑える。
    ///
    /// `controller` がまだ生成されていない場合（TomTom / ArcGIS のようにマップ準備完了の
    /// コールバックで生成するプロバイダ）は要求だけを記録し、コントローラ生成側が
    /// ``reapplyCameraRestriction(to:)`` を呼んだ時点で適用される。
    public func applyCameraRestriction(
        _ restriction: CameraRestriction?,
        to controller: (any MapViewControllerProtocol)?
    ) {
        requestedCameraRestriction = .some(restriction)
        guard let controller else { return }
        if let applied = appliedCameraRestriction, applied == restriction { return }
        appliedCameraRestriction = .some(restriction)
        controller.setCameraRestriction(restriction)
    }

    /// コントローラが生成されたタイミングで、保留中の制限を適用する。
    ///
    /// マップ準備完了コールバックでコントローラを作るプロバイダは、生成直後にこれを呼ぶ。
    /// 一度も制限が要求されていなければ何もしない。
    public func reapplyCameraRestriction(to controller: (any MapViewControllerProtocol)?) {
        guard let requested = requestedCameraRestriction else { return }
        appliedCameraRestriction = nil
        applyCameraRestriction(requested, to: controller)
    }

    /// Attaches the shared info-bubble container on top of `hostView`,
    /// following the host's bounds.
    public func attachInfoBubbleContainer(to hostView: UIView) {
        guard infoBubbleContainer.superview !== hostView else { return }
        infoBubbleContainer.backgroundColor = .clear
        infoBubbleContainer.isUserInteractionEnabled = true
        infoBubbleContainer.frame = hostView.bounds
        infoBubbleContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.addSubview(infoBubbleContainer)
    }
}
