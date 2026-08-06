import SwiftUI
import UIKit

public typealias OnMapLoadedHandler<State: MapViewStateProtocol> = (State) -> Void
public typealias OnMapEventHandler = (GeoPoint) -> Void
public typealias OnCameraMoveHandler = (MapCameraPosition) -> Void

public protocol MapOverlayItemProtocol {
    func append(to content: inout MapViewContent)
}

/// A marker protocol for map overlay items that are also SwiftUI Views.
/// These overlays need to be rendered in the view hierarchy in addition to
/// being added to the map content.
public protocol ViewBasedMapOverlay: MapOverlayItemProtocol, View {
}

public struct MapViewContent {
    public var markers: [Marker] = []
    public var infoBubbles: [InfoBubble] = []
    public var polylines: [Polyline] = []
    public var polygons: [Polygon] = []
    public var circles: [Circle] = []
    public var groundImages: [GroundImage] = []
    public var rasterLayers: [RasterLayer] = []
    public var views: [AnyView] = []
    public var markerTilingOptions: MarkerTilingOptions = .Default
    /// Handlers that manage a subset of polygons imperatively (e.g. cluster hull polygons).
    /// Map view coordinators call ``PolygonSyncHandler/bindPolygonSync(_:)`` on each handler
    /// to provide a direct polygon sync function, ensuring those polygons are committed before
    /// marker animations start rather than through SwiftUI's deferred recomposition path.
    public var polygonSyncHandlers: [any PolygonSyncHandler] = []

    public init() {}

    mutating func append(_ item: MapOverlayItemProtocol) {
        item.append(to: &self)
    }

    mutating func merge(_ other: MapViewContent) {
        markers.append(contentsOf: other.markers)
        infoBubbles.append(contentsOf: other.infoBubbles)
        polylines.append(contentsOf: other.polylines)
        polygons.append(contentsOf: other.polygons)
        circles.append(contentsOf: other.circles)
        groundImages.append(contentsOf: other.groundImages)
        rasterLayers.append(contentsOf: other.rasterLayers)
        views.append(contentsOf: other.views)
        polygonSyncHandlers.append(contentsOf: other.polygonSyncHandlers)
        if other.markerTilingOptions.enabled {
            markerTilingOptions = other.markerTilingOptions
        }
    }
}

@resultBuilder
public enum MapViewContentBuilder {
    public static func buildBlock() -> MapViewContent {
        MapViewContent()
    }

    public static func buildBlock(_ components: MapViewContent...) -> MapViewContent {
        var content = MapViewContent()
        for component in components {
            content.merge(component)
        }
        return content
    }

    public static func buildOptional(_ component: MapViewContent?) -> MapViewContent {
        component ?? MapViewContent()
    }

    public static func buildEither(first component: MapViewContent) -> MapViewContent {
        component
    }

    public static func buildEither(second component: MapViewContent) -> MapViewContent {
        component
    }

    public static func buildArray(_ components: [MapViewContent]) -> MapViewContent {
        var content = MapViewContent()
        for component in components {
            content.merge(component)
        }
        return content
    }

    public static func buildExpression<T: ViewBasedMapOverlay>(_ expression: T) -> MapViewContent {
        var content = MapViewContent()
        content.append(expression)
        content.views.append(AnyView(expression))
        return content
    }

    @_disfavoredOverload
    public static func buildExpression(_ expression: MapOverlayItemProtocol) -> MapViewContent {
        var content = MapViewContent()
        content.append(expression)
        return content
    }

    public static func buildExpression(_ expression: MapViewContent) -> MapViewContent {
        expression
    }
}

public struct Marker: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: MarkerState

    public init(state: MarkerState) {
        self.state = state
        self.id = state.id
    }

    public init(
        position: GeoPoint,
        id: String? = nil,
        extra: Any? = nil,
        icon: (any MarkerIconProtocol)? = nil,
        animation: MarkerAnimation? = nil,
        clickable: Bool = true,
        draggable: Bool = false,
        zIndex: Int? = nil,
        onClick: OnMarkerEventHandler? = nil,
        onDragStart: OnMarkerEventHandler? = nil,
        onDrag: OnMarkerEventHandler? = nil,
        onDragEnd: OnMarkerEventHandler? = nil,
        onAnimateStart: OnMarkerEventHandler? = nil,
        onAnimateEnd: OnMarkerEventHandler? = nil
    ) {
        let state = MarkerState(
            position: position,
            id: id,
            extra: extra,
            icon: icon,
            animation: animation,
            clickable: clickable,
            draggable: draggable,
            zIndex: zIndex,
            onClick: onClick,
            onDragStart: onDragStart,
            onDrag: onDrag,
            onDragEnd: onDragEnd,
            onAnimateStart: onAnimateStart,
            onAnimateEnd: onAnimateEnd
        )
        self.state = state
        self.id = state.id
    }

    public init(
        position: GeoPoint,
        id: String? = nil,
        extra: Any? = nil,
        icon: DefaultMarkerIcon,
        animation: MarkerAnimation? = nil,
        clickable: Bool = true,
        draggable: Bool = false,
        zIndex: Int? = nil,
        onClick: OnMarkerEventHandler? = nil,
        onDragStart: OnMarkerEventHandler? = nil,
        onDrag: OnMarkerEventHandler? = nil,
        onDragEnd: OnMarkerEventHandler? = nil,
        onAnimateStart: OnMarkerEventHandler? = nil,
        onAnimateEnd: OnMarkerEventHandler? = nil
    ) {
        let state = MarkerState(
            position: position,
            id: id,
            extra: extra,
            icon: icon,
            animation: animation,
            clickable: clickable,
            draggable: draggable,
            zIndex: zIndex,
            onClick: onClick,
            onDragStart: onDragStart,
            onDrag: onDrag,
            onDragEnd: onDragEnd,
            onAnimateStart: onAnimateStart,
            onAnimateEnd: onAnimateEnd
        )
        self.state = state
        self.id = state.id
    }

    public func append(to content: inout MapViewContent) {
        content.markers.append(self)
    }
}

public struct InfoBubble: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let marker: MarkerState
    public let tailOffset: CGPoint
    /// Holds either an AnyView (SwiftUI path) or a UIView (React Native / UIKit path).
    internal let _content: Any
    /// When false the bubble is anchored directly at the GeoPoint with no icon-size compensation.
    public let useIconMetrics: Bool

    public var swiftUIContent: AnyView? { _content as? AnyView }
    public var uiViewContent: UIView? { _content as? UIView }

    /// The style parameters mirror `InfoBubble` in `android-sdk-compose` one for one.
    /// To draw the bubble — tail included — entirely yourself, use ``InfoBubbleCustom``.
    public init<Content: View>(
        marker: MarkerState,
        bubbleColor: Color = .white,
        borderColor: Color = .black,
        contentPadding: CGFloat = 8.0,
        cornerRadius: CGFloat = 4.0,
        tailSize: CGFloat = 8.0,
        @ViewBuilder content: () -> Content
    ) {
        self.id = marker.id
        self.marker = marker
        self.tailOffset = CGPoint(x: 0.5, y: 1.0)
        self.useIconMetrics = true
        self._content = AnyView(DefaultInfoBubbleView(
            bubbleColor: bubbleColor,
            borderColor: borderColor,
            contentPadding: contentPadding,
            cornerRadius: cornerRadius,
            tailSize: tailSize,
            content: AnyView(content())
        ))
    }

    /// Places an InfoBubble directly at [position] without requiring a MarkerState.
    ///
    /// The bubble tail points exactly at the given coordinate.
    /// A stable id is generated from the position coordinates when [id] is not provided.
    ///
    /// Usage:
    /// ```swift
    /// InfoBubble(position: GeoPoint(latitude: 35.68, longitude: 139.77)) {
    ///     Text("Hello!")
    /// }
    /// ```
    public init<Content: View>(
        position: GeoPoint,
        id: String? = nil,
        bubbleColor: Color = .white,
        borderColor: Color = .black,
        contentPadding: CGFloat = 8.0,
        cornerRadius: CGFloat = 4.0,
        tailSize: CGFloat = 8.0,
        @ViewBuilder content: () -> Content
    ) {
        let syntheticMarker = MarkerState(position: position, id: id)
        self.id = syntheticMarker.id
        self.marker = syntheticMarker
        self.tailOffset = CGPoint(x: 0.5, y: 1.0)
        self.useIconMetrics = false
        self._content = AnyView(DefaultInfoBubbleView(
            bubbleColor: bubbleColor,
            borderColor: borderColor,
            contentPadding: contentPadding,
            cornerRadius: cornerRadius,
            tailSize: tailSize,
            content: AnyView(content())
        ))
    }

    /// Unstyled bubble: the caller draws everything, tail included.
    /// Backs ``InfoBubbleCustom``, which is the public spelling.
    internal init<Content: View>(
        marker: MarkerState,
        tailOffset: CGPoint,
        @ViewBuilder unstyledContent content: () -> Content
    ) {
        self.id = marker.id
        self.marker = marker
        self.tailOffset = tailOffset
        self.useIconMetrics = true
        self._content = AnyView(content())
    }

    /// UIKit / React Native initializer: provide a UIView directly as bubble content.
    public init(
        marker: MarkerState,
        tailOffset: CGPoint = CGPoint(x: 0.5, y: 1.0),
        uiViewContent: UIView
    ) {
        self.id = marker.id
        self.marker = marker
        self.tailOffset = tailOffset
        self.useIconMetrics = true
        self._content = uiViewContent
    }

    /// UIKit / React Native initializer anchored at a position without a MarkerState.
    public init(
        position: GeoPoint,
        id: String? = nil,
        tailOffset: CGPoint = CGPoint(x: 0.5, y: 1.0),
        uiViewContent: UIView
    ) {
        let syntheticMarker = MarkerState(position: position, id: id)
        self.id = syntheticMarker.id
        self.marker = syntheticMarker
        self.tailOffset = tailOffset
        self.useIconMetrics = false
        self._content = uiViewContent
    }

    public func append(to content: inout MapViewContent) {
        content.infoBubbles.append(self)
    }
}

/// An info bubble whose content is drawn entirely by the caller — including its tail.
///
/// Mirrors `InfoBubbleCustom` in `android-sdk-compose` and `@mapconductor/js-sdk-react`.
/// The bubble is positioned by the same overlay engine as `InfoBubble`; only the default
/// chrome (background, border, corner radius, tail) is omitted.
///
/// `tailOffset` says where, inside your content box, the connection point sits, in
/// normalized (0...1) coordinates: `(0.5, 1)` is bottom-center — the default for a bubble
/// sitting above its marker — and `(0, 0.5)` is center-left, for a bubble whose tail points
/// left from the right-hand side of the marker.
///
/// Usage:
/// ```swift
/// InfoBubbleCustom(marker: markerState, tailOffset: CGPoint(x: 0, y: 0.5)) {
///     RightTailBubble { Text(label) }
/// }
/// ```
///
public struct InfoBubbleCustom: MapOverlayItemProtocol, Identifiable {
    public let id: String
    private let bubble: InfoBubble

    public init<Content: View>(
        marker: MarkerState,
        tailOffset: CGPoint,
        @ViewBuilder content: () -> Content
    ) {
        self.bubble = InfoBubble(
            marker: marker,
            tailOffset: tailOffset,
            unstyledContent: content
        )
        self.id = bubble.id
    }

    /// UIKit / React Native variant: provide a `UIView` directly as bubble content.
    public init(
        marker: MarkerState,
        tailOffset: CGPoint,
        uiViewContent: UIView
    ) {
        self.bubble = InfoBubble(
            marker: marker,
            tailOffset: tailOffset,
            uiViewContent: uiViewContent
        )
        self.id = bubble.id
    }

    public func append(to content: inout MapViewContent) {
        bubble.append(to: &content)
    }
}

public struct Polyline: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: PolylineState

    public init(state: PolylineState) {
        self.state = state
        self.id = state.id
    }

    public init(
        points: [GeoPointProtocol],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolylineEventHandler? = nil
    ) {
        let state = PolylineState(
            points: points,
            id: id,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            geodesic: geodesic,
            zIndex: zIndex,
            extra: extra,
            onClick: onClick
        )
        self.state = state
        self.id = state.id
    }

    public init(
        bounds: GeoRectBounds,
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolylineEventHandler? = nil
    ) {
        if let northEast = bounds.northEast, let southWest = bounds.southWest {
            let points: [GeoPointProtocol] = [
                northEast,
                GeoPoint(latitude: southWest.latitude, longitude: northEast.longitude),
                southWest,
                GeoPoint(latitude: northEast.latitude, longitude: southWest.longitude),
                northEast
            ]
            self.init(
                points: points,
                id: id,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                geodesic: geodesic,
                zIndex: zIndex,
                extra: extra,
                onClick: onClick
            )
        } else {
            self.init(
                points: [],
                id: id,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                geodesic: geodesic,
                zIndex: zIndex,
                extra: extra,
                onClick: onClick
            )
        }
    }

    public func append(to content: inout MapViewContent) {
        content.polylines.append(self)
    }
}

public struct Polygon: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: PolygonState

    public init(state: PolygonState) {
        // 穴のユニオンはここ（コンポーネント層）で一度だけ適用する。
        // android-sdk の `PolygonComponent.kt` が `LaunchedEffect(state)` の中で
        // `state.unionHolesInPlace()` を呼んでからコレクタへ渡すのと同じ位置づけ。
        // 以前は各プロバイダの `PolygonOverlayRenderer` が `state.unionHoles()` を
        // 呼んでおり、プロバイダごとに実装が重複していた。
        state.unionHolesInPlace()
        self.state = state
        self.id = state.id
    }

    /// 引数順は android-sdk の `Polygon` コンポーザブル
    /// （points, holes, id, strokeColor, strokeWidth, fillColor, geodesic, zIndex, extra, onClick）
    /// に合わせてある。Swift は宣言順に引数を並べる必要があるため、順序自体が API の一部になる。
    public init(
        points: [GeoPointProtocol],
        holes: [[GeoPointProtocol]] = [],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        fillColor: UIColor = .clear,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolygonEventHandler? = nil
    ) {
        // すべての初期化子は init(state:) に集約する（穴のユニオンを 1 箇所で適用するため）。
        self.init(state: PolygonState(
            points: points,
            holes: holes,
            id: id,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            fillColor: fillColor,
            geodesic: geodesic,
            zIndex: zIndex,
            extra: extra,
            onClick: onClick
        ))
    }

    public init(
        bounds: GeoRectBounds,
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        fillColor: UIColor = .clear,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolygonEventHandler? = nil
    ) {
        if let northEast = bounds.northEast, let southWest = bounds.southWest {
            let points: [GeoPointProtocol] = [
                northEast,
                GeoPoint(latitude: southWest.latitude, longitude: northEast.longitude),
                southWest,
                GeoPoint(latitude: northEast.latitude, longitude: southWest.longitude),
                northEast
            ]
            self.init(
                points: points,
                id: id,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                fillColor: fillColor,
                geodesic: geodesic,
                zIndex: zIndex,
                extra: extra,
                onClick: onClick
            )
        } else {
            self.init(
                points: [],
                id: id,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                fillColor: fillColor,
                geodesic: geodesic,
                zIndex: zIndex,
                extra: extra,
                onClick: onClick
            )
        }
    }

    public func append(to content: inout MapViewContent) {
        content.polygons.append(self)
    }
}

public struct Circle: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: CircleState

    public init(state: CircleState) {
        self.state = state
        self.id = state.id
    }

    public init(
        center: GeoPointProtocol,
        radiusMeters: Double,
        geodesic: Bool = true,
        clickable: Bool = true,
        strokeColor: UIColor = .red,
        // android-sdk の `Circle` コンポーザブル（strokeWidth = 2.dp）と同じ既定値。
        // `CircleState` 側の既定は 3 者とも 1 で、コンポーネントだけ 2 という
        // 差はプラットフォーム共通（Polygon も同じ構図）。
        strokeWidth: Double = 2.0,
        fillColor: UIColor = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.5),
        id: String? = nil,
        zIndex: Int? = nil,
        extra: Any? = nil,
        onClick: OnCircleEventHandler? = nil
    ) {
        let state = CircleState(
            center: center,
            radiusMeters: radiusMeters,
            geodesic: geodesic,
            clickable: clickable,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            fillColor: fillColor,
            id: id,
            zIndex: zIndex,
            extra: extra,
            onClick: onClick
        )
        self.state = state
        self.id = state.id
    }

    public func append(to content: inout MapViewContent) {
        content.circles.append(self)
    }
}

public struct GroundImage: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: GroundImageState

    public init(state: GroundImageState) {
        self.state = state
        self.id = state.id
    }

    public init(
        bounds: GeoRectBounds,
        image: UIImage,
        // android-sdk の `GroundImage` コンポーザブル（opacity = 0.5f）と同じ既定値。
        // `GroundImageState` 側の既定は 3 者とも 1.0 で、コンポーネントだけ 0.5。
        opacity: Double = 0.5,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil
    ) {
        let state = GroundImageState(
            bounds: bounds,
            image: image,
            opacity: opacity,
            tileSize: tileSize,
            id: id,
            extra: extra,
            onClick: onClick
        )
        self.state = state
        self.id = state.id
    }

    public func append(to content: inout MapViewContent) {
        content.groundImages.append(self)
    }
}

public struct RasterLayer: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: RasterLayerState

    public init(state: RasterLayerState) {
        self.state = state
        self.id = state.id
    }

    /// 引数順は android-sdk の `RasterLayer` コンポーザブル
    /// （source, opacity, visible, zIndex, userAgent, id, extraHeaders）に合わせてある。
    public init(
        source: RasterSource,
        opacity: Double = 1.0,
        visible: Bool = true,
        zIndex: Int = 0,
        userAgent: String = RasterLayerState.defaultUserAgent,
        id: String? = nil,
        extraHeaders: [String: String]? = nil
    ) {
        let state = RasterLayerState(
            source: source,
            opacity: opacity,
            visible: visible,
            zIndex: zIndex,
            userAgent: userAgent,
            extraHeaders: extraHeaders,
            id: id
        )
        self.state = state
        self.id = state.id
    }

    public func append(to content: inout MapViewContent) {
        content.rasterLayers.append(self)
    }
}

public struct Markers: MapOverlayItemProtocol {
    private let states: [MarkerState]

    public init(_ states: [MarkerState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.markers.append(contentsOf: states.map { Marker(state: $0) })
    }
}

public struct Circles: MapOverlayItemProtocol {
    private let states: [CircleState]

    public init(_ states: [CircleState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.circles.append(contentsOf: states.map { Circle(state: $0) })
    }
}

public struct Polylines: MapOverlayItemProtocol {
    private let states: [PolylineState]

    public init(_ states: [PolylineState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.polylines.append(contentsOf: states.map { Polyline(state: $0) })
    }
}

public struct Polygons: MapOverlayItemProtocol {
    private let states: [PolygonState]

    public init(_ states: [PolygonState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.polygons.append(contentsOf: states.map { Polygon(state: $0) })
    }
}

public struct GroundImages: MapOverlayItemProtocol {
    private let states: [GroundImageState]

    public init(_ states: [GroundImageState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.groundImages.append(contentsOf: states.map { GroundImage(state: $0) })
    }
}

/// Analogous to SwiftUI's `ForEach`, but for `MapViewContentBuilder` closures.
///
/// Cannot be named `ForEach` because SwiftUI's `ForEach` would take precedence when
/// `Data.Element` conforms to `Identifiable`, causing a type mismatch error.
///
/// Usage:
/// ```swift
/// MapKitMapView(camera: $camera) {
///     ForArray(markers) { marker in
///         Marker(state: marker)
///     }
/// }
/// ```
public struct ForArray<Data: RandomAccessCollection>: MapOverlayItemProtocol {
    private let built: MapViewContent

    public init(
        _ data: Data,
        @MapViewContentBuilder content: (Data.Element) -> MapViewContent
    ) {
        var result = MapViewContent()
        for item in data {
            result.merge(content(item))
        }
        self.built = result
    }

    public func append(to content: inout MapViewContent) {
        content.merge(built)
    }
}
