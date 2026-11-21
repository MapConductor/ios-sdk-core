import Foundation

/// Where an overlay state reports that one of its own fields was written.
///
/// The collector used to learn this by subscribing to each state's Combine
/// publisher. That is one `map`, one `eraseToAnyPublisher`, one `receive(on:)`
/// and one `sink` per state, plus the `AnyCancellable` holding them, and it
/// does not stay linear: syncing markers into a collector measured 47 ms at
/// 1,000, 236 ms at 10,000 and 2,175 ms at 50,000 on a simulator, on the main
/// actor. Tokyo's street trees are 144,183.
///
/// A closure per state costs an allocation and nothing else. `objectWillChange`
/// instead of the fingerprint chain was measured too and came out worse (2,898
/// ms at 50,000): the cost is the subscription machinery, not the chain fed
/// into it.
///
/// android-sdk carries the same type for the same reason, though it arrived
/// there from the opposite direction — one observer reading every state, rather
/// than one subscription per state.
public final class StateMutationSignal {
    /// An object rather than a closure: ``OverlayCollector`` keeps what it
    /// knows of the state on it, and finds it again on the next sync.
    private(set) var target: StateMutationListener?

    public init() {}

    /// Sets who hears about writes, or clears it with nil.
    ///
    /// A state belongs to at most one collector, so there is one listener
    /// rather than a list.
    public func listen(_ listener: (() -> Void)?) {
        target = listener.map(ClosureListener.init)
    }

    func listen(target: StateMutationListener?) {
        self.target = target
    }

    /// Reports a write.
    public func notifyMutated() {
        target?.stateMutated()
    }
}

/// Hears the writes to one state (``StateMutationSignal``).
protocol StateMutationListener: AnyObject {
    /// The collector this listener belongs to, so that it can find its own
    /// listeners without a cast; nil for a plain closure.
    var owner: ObjectIdentifier? { get }
    func stateMutated()
}

private final class ClosureListener: StateMutationListener {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    var owner: ObjectIdentifier? { nil }
    func stateMutated() { body() }
}
