import Combine

/// A map-overlay state that can live in an ``OverlayCollector``.
///
/// Mirrors the `ComponentState { id }` contract of the React/Android SDKs
/// (`js-sdk-core/src/overlay/OverlayCollector.ts`,
/// `android-sdk-core/.../ChildCollector.kt`). Every overlay state is a reference
/// type (`AnyObject`) so the collector can hold it by identity, diff instances
/// with `!==`, and subscribe to it weakly.
///
/// `overlayChangePublisher()` emits whenever a rendered property changes. It is
/// backed by each state's `asFlow()` — the exact publisher the per-provider
/// controllers used before the collector existed — so routing an overlay through
/// the collector reproduces the old in-place-update behavior (e.g. dragging a
/// polygon vertex re-renders the polygon). The collector forwards each emission
/// to the bound controller's `update(state:)`, which dedupes by `fingerPrint()`.
public protocol OverlayCollectableState: AnyObject {
    var id: String { get }
    func overlayChangePublisher() -> AnyPublisher<Void, Never>
}

extension MarkerState: OverlayCollectableState {
    public func overlayChangePublisher() -> AnyPublisher<Void, Never> {
        asFlow().map { _ in () }.eraseToAnyPublisher()
    }
}

extension CircleState: OverlayCollectableState {
    public func overlayChangePublisher() -> AnyPublisher<Void, Never> {
        asFlow().map { _ in () }.eraseToAnyPublisher()
    }
}

extension PolylineState: OverlayCollectableState {
    public func overlayChangePublisher() -> AnyPublisher<Void, Never> {
        asFlow().map { _ in () }.eraseToAnyPublisher()
    }
}

extension PolygonState: OverlayCollectableState {
    public func overlayChangePublisher() -> AnyPublisher<Void, Never> {
        asFlow().map { _ in () }.eraseToAnyPublisher()
    }
}

extension GroundImageState: OverlayCollectableState {
    public func overlayChangePublisher() -> AnyPublisher<Void, Never> {
        asFlow().map { _ in () }.eraseToAnyPublisher()
    }
}

extension RasterLayerState: OverlayCollectableState {
    public func overlayChangePublisher() -> AnyPublisher<Void, Never> {
        asFlow().map { _ in () }.eraseToAnyPublisher()
    }
}
