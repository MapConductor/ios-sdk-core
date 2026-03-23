import UIKit

/// A container view that only intercepts touches on its subviews (e.g. InfoBubbles),
/// allowing touches elsewhere to pass through to the view below (the map view).
public final class PassthroughContainerView: UIView {
    public var onLayout: (() -> Void)?
    private var lastBounds: CGRect = .zero

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != lastBounds else { return }
        lastBounds = bounds
        onLayout?()
    }

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView == self ? nil : hitView
    }
}
