import Combine

/// Wire an ``OverlayCollector`` to the provider's overlay controller so the
/// collector becomes the source of truth the renderer subscribes to.
///
/// Membership changes drive `add(data:)` (idempotent — the controller diffs
/// against its own manager and adds/updates/removes), and per-state mutations
/// drive `update(state:)` (deduped by fingerprint inside the controller). This
/// replaces the bespoke `sync<Overlay>s` id-diff + Combine code that each
/// provider used to duplicate.
@MainActor
public func bindOverlayCollector<S, C: OverlayControllerProtocol>(
    _ collector: OverlayCollector<S>,
    to controller: C
) where C.StateType == S {
    collector.onMembershipChange { states in
        Task { await controller.add(data: states) }
    }
    collector.onStateChange { state in
        Task { await controller.update(state: state) }
    }
}
