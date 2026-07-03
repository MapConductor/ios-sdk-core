import CoreGraphics
import QuartzCore
import UIKit

/// A marker animation delegated to the screen-space overlay layer.
///
/// Instead of interpolating geographic coordinates (which produces wrong
/// directions when the map is tilted, rotated, or rendered as a globe), the
/// overlay animates the marker's image in screen space above the map view and
/// calls `onFinished` when done so the native marker can be shown at its
/// final position.
public struct MarkerAnimationOverlayEntry {
    public let id: String
    public let state: MarkerState
    public let icon: BitmapIcon
    public let animation: MarkerAnimation
    public let duration: CFTimeInterval
    public let onFinished: () -> Void

    public init(
        id: String,
        state: MarkerState,
        icon: BitmapIcon,
        animation: MarkerAnimation,
        duration: CFTimeInterval,
        onFinished: @escaping () -> Void
    ) {
        self.id = id
        self.state = state
        self.icon = icon
        self.animation = animation
        self.duration = duration
        self.onFinished = onFinished
    }
}

/// Screen-space marker animation layer (UIKit counterpart of the Compose
/// `MarkerAnimationOverlayLayer` on Android).
///
/// Drop/Bounce animations move the marker's image vertically on screen from
/// above the container's top edge down to the marker's projected position.
/// Because the motion happens in screen coordinates it is independent of the
/// map projection — tilted, rotated, or globe views all get a straight drop
/// from the top of the map view. The projected target is re-resolved every
/// frame, so the animation tracks a moving camera.
///
/// The layer shares the InfoBubble overlay container; animation views are
/// inserted at the bottom so info bubbles stay on top.
@MainActor
public final class MarkerAnimationOverlayCoordinator {
    public typealias Projection = (GeoPointProtocol) -> CGPoint?

    private weak var container: UIView?
    private let project: Projection

    private final class ActiveAnimation {
        let entry: MarkerAnimationOverlayEntry
        let view: UIImageView
        let startTime: CFTimeInterval

        init(entry: MarkerAnimationOverlayEntry, view: UIImageView, startTime: CFTimeInterval) {
            self.entry = entry
            self.view = view
            self.startTime = startTime
        }
    }

    private var active: [String: ActiveAnimation] = [:]
    private var displayLink: CADisplayLink?

    public init(container: UIView, project: @escaping Projection) {
        self.container = container
        self.project = project
    }

    public func start(_ entry: MarkerAnimationOverlayEntry) {
        guard let container else {
            entry.onFinished()
            return
        }

        // Replace a running animation for the same marker, completing its
        // side effects (e.g. re-showing the native marker) first.
        if let existing = active.removeValue(forKey: entry.id) {
            existing.view.removeFromSuperview()
            existing.entry.onFinished()
        }

        let view = UIImageView(image: entry.icon.bitmap)
        view.isUserInteractionEnabled = false
        view.frame = CGRect(origin: .zero, size: entry.icon.size)
        // Keep animations below info bubbles sharing the same container.
        container.insertSubview(view, at: 0)

        let animation = ActiveAnimation(entry: entry, view: view, startTime: CACurrentMediaTime())
        active[entry.id] = animation
        position(animation, easedProgress: 0)
        ensureDisplayLink()
    }

    /// Finishes all running animations immediately (invoking their
    /// completions) and releases the display link.
    public func unbind() {
        let entries = active.values.map { $0 }
        active.removeAll()
        stopDisplayLinkIfIdle()
        for animation in entries {
            animation.view.removeFromSuperview()
            animation.entry.onFinished()
        }
    }

    // MARK: - Private

    private final class DisplayLinkTarget: NSObject {
        weak var coordinator: MarkerAnimationOverlayCoordinator?

        @objc func step() {
            MainActor.assumeIsolated {
                coordinator?.tick()
            }
        }
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget()
        target.coordinator = self
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLinkIfIdle() {
        guard active.isEmpty else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var finished: [ActiveAnimation] = []

        for animation in active.values {
            let elapsed = now - animation.startTime
            let progress = min(CGFloat(elapsed / max(animation.entry.duration, 0.001)), 1.0)
            let eased = ease(progress, animation: animation.entry.animation)
            position(animation, easedProgress: eased)
            if progress >= 1.0 {
                finished.append(animation)
            }
        }

        for animation in finished {
            active.removeValue(forKey: animation.entry.id)
            animation.view.removeFromSuperview()
            animation.entry.onFinished()
        }
        stopDisplayLinkIfIdle()
    }

    private func position(_ animation: ActiveAnimation, easedProgress: CGFloat) {
        // Re-project every frame so the drop tracks a moving camera. When the
        // position is not projectable (e.g. rotated behind the globe), hide
        // the image but keep the clock running so the native marker is still
        // revealed at the end.
        guard let target = project(animation.entry.state.position) else {
            animation.view.isHidden = true
            return
        }
        animation.view.isHidden = false

        let size = animation.entry.icon.size
        let anchor = animation.entry.icon.anchor
        // Top-left of the icon when it has landed on its anchor.
        let endX = target.x - anchor.x * size.width
        let endY = target.y - anchor.y * size.height
        // Start fully above the container's top edge.
        let startY = -size.height
        animation.view.frame = CGRect(
            x: endX,
            y: startY + (endY - startY) * easedProgress,
            width: size.width,
            height: size.height
        )
    }

    private func ease(_ t: CGFloat, animation: MarkerAnimation) -> CGFloat {
        switch animation {
        case .Drop:
            return t
        case .Bounce:
            return Self.easeOutBounce(t)
        }
    }

    private static func easeOutBounce(_ t: CGFloat) -> CGFloat {
        let n1: CGFloat = 7.5625
        let d1: CGFloat = 2.75
        var value = t
        if value < 1 / d1 {
            return n1 * value * value
        } else if value < 2 / d1 {
            value -= 1.5 / d1
            return n1 * value * value + 0.75
        } else if value < 2.5 / d1 {
            value -= 2.25 / d1
            return n1 * value * value + 0.9375
        } else {
            value -= 2.625 / d1
            return n1 * value * value + 0.984375
        }
    }
}
