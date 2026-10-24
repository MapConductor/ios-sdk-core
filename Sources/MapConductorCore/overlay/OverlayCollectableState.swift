import Combine

/// A map-overlay state that can live in an ``OverlayCollector``.
///
/// Mirrors the `ComponentState { id }` contract of the React/Android SDKs
/// (`js-sdk-core/src/overlay/OverlayCollector.ts`,
/// `android-sdk-core/.../OverlayCollector.kt`). Every overlay state is a reference
/// type (`AnyObject`) so the collector can hold it by identity, diff instances
/// with `!==`, and subscribe to it weakly.
///
/// ``StateMutationSignal`` is where a state reports a write to a rendered
/// property, and the collector forwards it to the bound controller's
/// `update(state:)`, which dedupes by `fingerPrint()`. The collector used to
/// learn the same thing by subscribing to each state's `asFlow()`; that cost
/// two seconds to sync 50,000 markers on the main actor, so the states report
/// instead. `asFlow()` itself stays — several provider controllers subscribe to
/// it directly, outside the collector.
public protocol OverlayCollectableState: AnyObject {
    var id: String { get }
    var mutations: StateMutationSignal { get }
}

extension MarkerState: OverlayCollectableState {}

extension CircleState: OverlayCollectableState {}

extension PolylineState: OverlayCollectableState {}

extension PolygonState: OverlayCollectableState {}

extension GroundImageState: OverlayCollectableState {}

extension RasterLayerState: OverlayCollectableState {}
