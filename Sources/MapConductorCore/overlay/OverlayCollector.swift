import Combine
import Foundation

/// Per-map, per-overlay-type source of truth for overlay states.
///
/// This is the iOS analog of the React `OverlayCollector`
/// (`js-sdk-core/src/overlay/OverlayCollector.ts`) and the Android
/// `ChildCollector` (`android-sdk-core/.../ChildCollector.kt`): one collector
/// per overlay type per map, holding an `id -> state` map, that provider
/// renderers subscribe to. It generalizes the existing hand-rolled collector in
/// `StrategyMarkerManager` so every overlay type and provider shares one
/// implementation instead of re-implementing the id-diff + per-state Combine
/// subscription in each `sync<Overlay>s`.
///
/// The map host calls ``sync(_:)`` every render with the **full union list**
/// already aggregated by the content builder (so, unlike React/Android where a
/// component merges its own ids, iOS pushes the complete set once). The
/// collector diffs that against its current contents, emits a membership change
/// (→ controller `add(data:)`) when the id set or an instance changes, and
/// subscribes each state so in-place mutations reach the controller's
/// `update(state:)`.
@MainActor
public final class OverlayCollector<S: OverlayCollectableState> {
    private var statesById: [String: S] = [:]
    private var order: [String] = []
    private var subscriptions: [String: AnyCancellable] = [:]
    private var latest: [S] = []

    private var membershipHandler: (([S]) -> Void)?
    private var updateHandler: ((S) -> Void)?
    private var shouldApply: () -> Bool

    /// In-place 変更の配信を `Settings.Default.composeEventDebounce`（5ms）でまとめる。
    /// android-sdk の `ChildCollectorImpl.watchStateChanges` が `sample(updateDebounce)` で
    /// 行っているのと同じ間引き。ドラッグのように毎フレーム発火する変更でも、1 つの state に
    /// つき 1 窓 1 回しかコントローラの `update(state:)` を呼ばない。
    private var pendingUpdates: [String: S] = [:]
    private var updateFlushTask: Task<Void, Never>?

    /// - Parameter shouldApply: Gate that defers membership emission until the
    ///   renderer is ready (e.g. Mapbox/MapLibre style load). Call ``flush()``
    ///   once it becomes `true` to emit any pending set.
    public init(shouldApply: @escaping () -> Bool = { true }) {
        self.shouldApply = shouldApply
    }

    public func setShouldApply(_ gate: @escaping () -> Bool) {
        shouldApply = gate
    }

    /// Register the callback invoked with the full list when membership changes.
    public func onMembershipChange(_ handler: @escaping ([S]) -> Void) {
        membershipHandler = handler
    }

    /// Register the callback invoked when a single state mutates in place.
    public func onStateChange(_ handler: @escaping (S) -> Void) {
        updateHandler = handler
    }

    /// Diff the full union list against the current contents and apply changes.
    public func sync(_ states: [S]) {
        let newIds = Set(states.map { $0.id })
        let oldIds = Set(statesById.keys)
        var membershipChanged = newIds != oldIds

        var next: [String: S] = [:]
        for state in states {
            if let existing = statesById[state.id], existing !== state {
                // Same id, new instance → drop the stale subscription and treat
                // it as a membership change so the renderer re-adds it.
                subscriptions[state.id]?.cancel()
                subscriptions.removeValue(forKey: state.id)
                membershipChanged = true
            }
            next[state.id] = state
        }
        statesById = next
        order = states.map { $0.id }
        latest = states

        for id in oldIds.subtracting(newIds) {
            subscriptions[id]?.cancel()
            subscriptions.removeValue(forKey: id)
        }

        if membershipChanged && shouldApply() {
            membershipHandler?(states)
        }

        for state in states where subscriptions[state.id] == nil {
            subscriptions[state.id] = state.overlayChangePublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak state] _ in
                    guard let self, let state, self.statesById[state.id] != nil else { return }
                    self.scheduleUpdate(state)
                }
        }
    }

    /// 変更を 5ms 窓にためて、窓の終わりに id ごと最新の 1 件だけ配信する。
    private func scheduleUpdate(_ state: S) {
        pendingUpdates[state.id] = state
        guard updateFlushTask == nil else { return }

        let delay = UInt64(max(0, Settings.Default.composeEventDebounce)) * 1_000_000
        updateFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            self.updateFlushTask = nil
            let batch = self.pendingUpdates
            self.pendingUpdates.removeAll()
            for (id, state) in batch where self.statesById[id] === state {
                self.updateHandler?(state)
            }
        }
    }

    /// Re-emit the current set (used once ``shouldApply`` flips to `true`).
    public func flush() {
        guard shouldApply(), !latest.isEmpty else { return }
        membershipHandler?(latest)
    }

    /// Current states in declaration order.
    public func values() -> [S] {
        order.compactMap { statesById[$0] }
    }

    public func get(_ id: String) -> S? {
        statesById[id]
    }

    public func clear() {
        subscriptions.values.forEach { $0.cancel() }
        subscriptions.removeAll()
        statesById.removeAll()
        order.removeAll()
        latest.removeAll()
        updateFlushTask?.cancel()
        updateFlushTask = nil
        pendingUpdates.removeAll()
    }
}
