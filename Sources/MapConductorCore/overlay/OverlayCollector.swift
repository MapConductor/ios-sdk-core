import Combine
import Foundation

/// Per-map, per-overlay-type source of truth for overlay states.
///
/// This is the iOS analog of the React `OverlayCollector`
/// (`js-sdk-core/src/overlay/OverlayCollector.ts`) and the Android
/// `OverlayCollector` (`android-sdk-core/.../OverlayCollector.kt`): one collector
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
///
/// 変更の届け方は 3 プラットフォームで揃えてある。
///
/// - **membership（追加・削除）は debounce**。5ms の無入力窓で、イベントが来るたびに窓を
///   延長する。android-sdk の `OverlayCollector` が `debounceBatch(5ms, ...)` で行うのと同じ。
/// - **in-place 変更は sample**。1 つの state につき 1 窓 1 回、最新の値だけを配る。
///   android-sdk の `sample(updateDebounce)` と同じ。
@MainActor
public final class OverlayCollector<S: OverlayCollectableState> {
    private var statesById: [String: S] = [:]
    private var order: [String] = []
    private var subscriptions: [String: AnyCancellable] = [:]
    private var latest: [S] = []

    private var membershipHandler: (([S]) -> Void)?
    private var updateHandler: ((S) -> Void)?
    private var shouldApply: () -> Bool

    /// membership 配信を `Settings.Default.composeEventDebounce`（5ms）の無入力窓でまとめる。
    ///
    /// SwiftUI は 1 フレームの間に `updateUIView` を何度も呼ぶ（`@Published` が複数更新された、
    /// アニメーション中、親が再評価された、など）。そのたびに `membershipHandler` を叩くと
    /// コントローラの `add(data:)` が全件差分を取り直すので、オーバーレイが多いほど無駄が効く。
    ///
    /// android-sdk の `debounceBatch(5ms, maxSize)` と同じく、窓が閉じるのを待たない
    /// 打ち切り弁も持つ。android では「窓の中で溜まった add イベント数」だが、iOS の
    /// `sync(_:)` は 1 回で全件を運ぶので「窓の中で合流した sync 回数」を数える。
    private static var membershipMaxBatch: Int { 100 }
    private var membershipDirty = false
    private var coalescedSyncs = 0
    private var membershipFlushTask: Task<Void, Never>?

    /// In-place 変更の配信を `Settings.Default.composeEventDebounce`（5ms）でまとめる。
    /// android-sdk の `OverlayCollector.watchStateChanges` が `sample(updateDebounce)` で
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

        if membershipChanged {
            scheduleMembership()
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

    /// membership 配信を 5ms の無入力窓にためる。窓の中で `sync(_:)` が続く限り窓を延長し、
    /// 合流した回数が打ち切り弁に達したら待たずに出す。
    private func scheduleMembership() {
        membershipDirty = true
        coalescedSyncs += 1
        if coalescedSyncs >= Self.membershipMaxBatch {
            emitMembershipIfPending()
            return
        }

        membershipFlushTask?.cancel()
        let delay = UInt64(max(0, Settings.Default.composeEventDebounce)) * 1_000_000
        membershipFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.membershipFlushTask = nil
            self.emitMembershipIfPending()
        }
    }

    /// 保留中の membership を今すぐ配信する。
    ///
    /// `shouldApply()` が false のときは **dirty を残したまま何もしない**。レンダラの準備が
    /// できていないだけなので、準備完了時に呼ばれる ``flush()`` が改めて配る。
    private func emitMembershipIfPending() {
        cancelMembershipTimer()
        guard membershipDirty, shouldApply() else { return }
        membershipDirty = false
        membershipHandler?(latest)
    }

    private func cancelMembershipTimer() {
        membershipFlushTask?.cancel()
        membershipFlushTask = nil
        coalescedSyncs = 0
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
            // membership が保留なら先に出す。debounce 窓は延長されうるので、待っていると
            // コントローラがまだ知らない state に対して `update(state:)` が先着しかねない。
            // 同期配信だった頃は add が必ず先だったので、その順序をここで保つ。
            self.emitMembershipIfPending()
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
        cancelMembershipTimer()
        membershipDirty = false
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
        cancelMembershipTimer()
        membershipDirty = false
    }
}
