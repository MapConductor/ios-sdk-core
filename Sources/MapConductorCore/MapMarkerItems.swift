import SwiftUI
import UIKit

/// マーカーと吹き出しの DSL 要素。
///
/// `MapViewContentBuilder` の中に並べると、それぞれが `append(to:)` で
/// `MapViewContent` へ自分を積む。ビューではなく**値**なので、body の再評価では
/// 作り直されるだけで、実際の地図オブジェクトの出し入れは差分側が決める。
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
