import CoreGraphics
import SwiftUI
import UIKit

public struct MarkerIconMetrics {
    public let size: CGSize
    public let anchor: CGPoint
    public let infoAnchor: CGPoint

    public init(size: CGSize, anchor: CGPoint, infoAnchor: CGPoint) {
        self.size = size
        self.anchor = anchor
        self.infoAnchor = infoAnchor
    }
}

@MainActor
public final class InfoBubbleOverlayCoordinator {
    public typealias Projection = (GeoPointProtocol) -> CGPoint?
    public typealias MarkerStateResolver = (_ markerId: String, _ bubbleMarker: MarkerState) -> MarkerState
    public typealias IconMetricsProvider = (_ markerState: MarkerState) -> MarkerIconMetrics

    private weak var container: UIView?
    private let project: Projection
    private let resolveMarkerStateForIcon: MarkerStateResolver
    private let iconMetrics: IconMetricsProvider

    private var infoBubblesById: [String: InfoBubble] = [:]
    private var infoBubbleHosts: [String: UIHostingController<AnyView>] = [:]

    public init(
        container: UIView,
        project: @escaping Projection,
        resolveMarkerStateForIcon: @escaping MarkerStateResolver = { _, bubbleMarker in bubbleMarker },
        iconMetrics: @escaping IconMetricsProvider
    ) {
        self.container = container
        self.project = project
        self.resolveMarkerStateForIcon = resolveMarkerStateForIcon
        self.iconMetrics = iconMetrics

        if let passthrough = container as? PassthroughContainerView {
            passthrough.onLayout = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.updateAllLayouts()
                }
            }
        }
    }

    public func syncInfoBubbles(_ bubbles: [InfoBubble]) {
        var newBubbles: [String: InfoBubble] = [:]
        for bubble in bubbles {
            newBubbles[bubble.marker.id] = bubble
        }
        infoBubblesById = newBubbles
        syncInfoBubbleViews()
        // Layout can be requested while the host view is still zero-sized (e.g. during makeUIView).
        // Do a second pass on the next runloop to avoid bubbles being placed at (0, 0)-derived positions.
        DispatchQueue.main.async { [weak self] in
            self?.updateAllLayouts()
        }
    }

    private func syncInfoBubbleViews() {
        guard let container else { return }
        for (id, bubble) in infoBubblesById {
            let host = infoBubbleHosts[id] ?? UIHostingController(rootView: bubble.content)
            host.rootView = bubble.content
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = true
            if host.view.superview == nil {
                container.addSubview(host.view)
            }
            infoBubbleHosts[id] = host
        }

        let activeIds = Set(infoBubblesById.keys)
        let existingIds = Set(infoBubbleHosts.keys)
        for id in existingIds.subtracting(activeIds) {
            removeInfoBubbleView(for: id)
        }
    }

    public func removeInfoBubbleView(for id: String) {
        if let host = infoBubbleHosts.removeValue(forKey: id) {
            host.view.removeFromSuperview()
        }
    }

    public func updateAllLayouts() {
        guard let container, !container.bounds.isEmpty else { return }
        for id in infoBubblesById.keys {
            updateInfoBubblePosition(for: id)
        }
    }

    public func updateInfoBubblePosition(for id: String) {
        guard let container, !container.bounds.isEmpty else { return }
        guard let bubble = infoBubblesById[id],
              let host = infoBubbleHosts[id],
              let screenPoint = project(bubble.marker.position) else { return }
        updateInfoBubblePosition(for: id, bubble: bubble, host: host, screenPoint: screenPoint)
    }

    public func updateInfoBubblePosition(for id: String, screenPoint: CGPoint) {
        guard let container, !container.bounds.isEmpty else { return }
        guard let bubble = infoBubblesById[id],
              let host = infoBubbleHosts[id] else { return }
        updateInfoBubblePosition(for: id, bubble: bubble, host: host, screenPoint: screenPoint)
    }

    private func updateInfoBubblePosition(
        for id: String,
        bubble: InfoBubble,
        host: UIHostingController<AnyView>,
        screenPoint: CGPoint
    ) {
        let markerStateForIcon = resolveMarkerStateForIcon(id, bubble.marker)
        let metrics = iconMetrics(markerStateForIcon)

        let targetSize = host.sizeThatFits(in: CGSize(width: 260, height: 1000))
        host.view.bounds = CGRect(origin: .zero, size: targetSize)

        let x = screenPoint.x +
            (-bubble.tailOffset.x * targetSize.width) +
            ((0.5 - metrics.anchor.x) * metrics.size.width) +
            ((metrics.infoAnchor.x - 0.5) * metrics.size.width)
        let y = screenPoint.y +
            (-bubble.tailOffset.y * targetSize.height) +
            ((0.5 - metrics.anchor.y) * metrics.size.height) +
            ((metrics.infoAnchor.y - 0.5) * metrics.size.height)

        host.view.frame = CGRect(
            origin: alignToPixel(CGPoint(x: x, y: y), scale: UIScreen.main.scale),
            size: targetSize
        )
    }

    private func alignToPixel(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(
            x: (point.x * scale).rounded() / scale,
            y: (point.y * scale).rounded() / scale
        )
    }

    public func unbind() {
        if let passthrough = container as? PassthroughContainerView {
            passthrough.onLayout = nil
        }
        infoBubbleHosts.values.forEach { $0.view.removeFromSuperview() }
        infoBubbleHosts.removeAll()
        infoBubblesById.removeAll()
    }
}
