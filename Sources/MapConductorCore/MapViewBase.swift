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
