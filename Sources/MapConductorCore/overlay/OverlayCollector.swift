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
    /// One state's place in this collector: the listener its signal calls,
    /// holding the pass of ``sync(_:)`` the state was last listed in. Telling
    /// who joined and who left is then a read per state, not sets and
    /// dictionaries of ids: those cost 1.4 s on the main thread for a filter
    /// over 723,800 circles on an iPad Pro.
    /// Read and written on the main thread only (a write from elsewhere hops there).
    private final class Member: StateMutationListener, @unchecked Sendable {
        // Unowned, not weak: a weak reference would give every state a side
        // table, and its retains and releases would all take the slow path.
        unowned let state: S
        weak var collector: OverlayCollector<S>?
        let owner: ObjectIdentifier?
        var pass: UInt32

        init(state: S, collector: OverlayCollector<S>, pass: UInt32) {
            self.state = state
            self.collector = collector
            owner = ObjectIdentifier(collector)
            self.pass = pass
        }

        func stateMutated() {
            if Thread.isMainThread {
                MainActor.assumeIsolated { collector?.memberMutated(self) }
            } else {
                DispatchQueue.main.async { [self] in collector?.memberMutated(self) }
            }
        }
    }

    /// The current pass of ``sync(_:)``; 0 is none.
    private var pass: UInt32 = 0
    /// How many states the current pass holds.
    private var memberCount = 0
    private var latest: [S] = []
    /// The latest list by id, for ``get(_:)`` and ``values()``; built when asked for.
    private var byId: [String: S]?

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
        // SwiftUI re-evaluates the map's content on every camera frame and hands
        // back the very same list. Diffing it costs a set, a dictionary and a
        // listener per state: 260 ms a frame for 100,000 parcels on an iPad Pro,
        // which made every pan run at 5 fps. The same instances in the same order
        // cannot have changed membership, and their listeners are already in place.
        if isSameList(states) { return }
        let previous = pass
        pass = pass == .max ? 1 : pass + 1
        var stayed = 0
        var joined = false
        var count = 0
        for state in states {
            if let member = member(of: state) {
                if member.pass == pass { continue } // listed twice
                if member.pass == previous { stayed += 1 } else { joined = true }
                member.pass = pass
            } else {
                // A new state, or a new instance of an id (the old one leaves
                // below): either way the renderer has to add it.
                joined = true
                state.mutations.listen(target: Member(state: state, collector: self, pass: pass))
            }
            count += 1
        }
        // A state reports to at most one collector, so leaving a stale listener
        // on a dropped state would send its writes to a collector that no longer
        // holds it.
        for state in latest {
            if let member = member(of: state), member.pass == previous { state.mutations.listen(target: nil) }
        }
        let membershipChanged = joined || stayed != memberCount
        memberCount = count
        latest = states
        byId = nil

        if membershipChanged {
            scheduleMembership()
        }
    }

    /// The state's membership here, if it listens to this collector.
    private func member(of state: S) -> Member? {
        guard let target = state.mutations.target, target.owner == ObjectIdentifier(self) else { return nil }
        return unsafeDowncast(target, to: Member.self)
    }

    /// In the latest list.
    private func holds(_ state: S) -> Bool {
        member(of: state)?.pass == pass
    }

    private func memberMutated(_ member: Member) {
        guard member.pass == pass else { return }
        scheduleUpdate(member.state)
    }

    private func statesById() -> [String: S] {
        if let byId { return byId }
        var map: [String: S] = [:]
        map.reserveCapacity(latest.count)
        for state in latest { map[state.id] = state }
        byId = map
        return map
    }

    /// The same instances in the same order. `S` is a class, so each element is
    /// one reference and the two buffers can be compared as bytes: element by
    /// element, through the generic, it cost 14 ms for 100,000 states on the iPad.
    private func isSameList(_ states: [S]) -> Bool {
        guard states.count == latest.count, !states.isEmpty else { return false }
        return states.withUnsafeBytes { a in
            latest.withUnsafeBytes { b in
                a.count == b.count && memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
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
            for state in batch.values where self.holds(state) {
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
        let byId = statesById()
        return latest.compactMap { byId[$0.id] }
    }

    public func get(_ id: String) -> S? {
        statesById()[id]
    }

    deinit {
        // A listener of ours left on a state would keep this collector's
        // identity, which a new collector could be given.
        for state in latest {
            if let target = state.mutations.target, target.owner == ObjectIdentifier(self) {
                state.mutations.listen(target: nil)
            }
        }
    }

    public func clear() {
        for state in latest where holds(state) { state.mutations.listen(target: nil) }
        pass = pass == .max ? 1 : pass + 1
        memberCount = 0
        byId = nil
        latest.removeAll()
        updateFlushTask?.cancel()
        updateFlushTask = nil
        pendingUpdates.removeAll()
        cancelMembershipTimer()
        membershipDirty = false
    }
}
