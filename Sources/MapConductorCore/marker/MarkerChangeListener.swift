import Combine
import Foundation

@_spi(MapConductorDriver)
extension MarkerState {
    /// Calls `body` on the main queue after each write to this marker, until the
    /// returned token is cancelled or released. Not for the current values: the
    /// first call comes with the first write.
    ///
    /// For a marker controller, in place of a subscription to ``asFlow()``.
    /// Switching the provider on Tokyo's 144,183 street trees spent 3.5 s
    /// subscribing the new map's controller and 2 s cancelling the old one's, on
    /// the main thread, on an iPad Pro. See ``StateMutationSignal`` for the cost.
    ///
    /// The marker has one listener, as a state in an ``OverlayCollector`` does:
    /// the newest one hears the writes. Cancelling a token whose listener has
    /// been replaced leaves the newer one alone, so the map being taken down
    /// after a provider switch does not take the writes from the new map.
    public func onChange(_ body: @escaping () -> Void) -> AnyCancellable {
        let listener = MarkerChangeListener(body)
        mutations.listen(target: listener)
        return AnyCancellable { [weak self, weak listener] in
            guard let self, let listener, self.mutations.target === listener else { return }
            self.mutations.listen(target: nil)
        }
    }
}

private final class MarkerChangeListener: StateMutationListener {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    var owner: ObjectIdentifier? { nil }
    func stateMutated() { DispatchQueue.main.async(execute: body) }
}
