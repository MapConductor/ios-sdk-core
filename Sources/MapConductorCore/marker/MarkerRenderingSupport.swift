import Foundation

/// Map-scoped capability used by marker-clustering (and other marker-rendering plugins)
/// to drive per-group rendering without the map view controller having to implement
/// plugin interfaces, and without Core carrying plugin-shaped fields.
///
/// This is the iOS counterpart of Android's `MarkerRenderingSupport<ActualMarker>`.
/// It differs in one respect: Android hands the plugin *factories* and lets the plugin own
/// the renderer and controller, because Kotlin's `MarkerOverlayRendererInterface<ActualMarker>`
/// is an interface the plugin can name. Swift's `StrategyMarkerController` takes the renderer
/// as a **concrete** generic parameter, which a plugin cannot name, so ownership stays on the
/// provider side and the plugin drives it through ``connect(strategy:markers:initialCamera:)``.
/// The direction of the *lookup* is the same as Android's: the plugin resolves the capability
/// from ``MapServiceRegistry``; the provider never learns that clustering exists.
///
/// `strategy` is passed as `Any` for the same reason Android stores `MarkerRenderingSupport<*>`
/// and casts on the way out: the plugin's `ActualMarker` and the provider's are only known to
/// match at runtime. Implementations cast to `AnyMarkerRenderingStrategy<ActualMarker>` and
/// report the mismatch by returning `false`.
@MainActor
public protocol MarkerRenderingSupport: AnyObject {
    /// Binds a strategy (e.g. a cluster strategy) to this provider's marker rendering.
    /// - Returns: `false` when `strategy` is not this provider's marker type.
    @discardableResult
    func connect(strategy: Any, markers: [MarkerState]) -> Bool

    /// Pushes the current marker list for an already-connected strategy.
    func syncMarkers(_ markers: [MarkerState])

    /// Releases the renderer and controller built for the connected strategy.
    func disconnect()

    /// Removes every marker the connected strategy has drawn, keeping the strategy connected.
    ///
    /// Called from each provider's `clearOverlays()` (through
    /// ``MapServiceRegistry/clearMarkerRendering()``) so markers drawn by a strategy, such as
    /// clustering, are cleared together with the provider's own overlays. Implementations call
    /// the strategy controller's `clear()` (onRemove → strategy.clear() → onPostProcess) and
    /// forget what they last sent, so the next ``syncMarkers(_:)`` sends the markers again,
    /// the same way the overlay collectors re-add content after a clear.
    ///
    /// Required, with no default: a default no-op would compile and silently leave the
    /// strategy's markers on the map for a provider that keeps its own strategy controller
    /// (HERE, ArcGIS 3D).
    func clearMarkers() async

    /// Called by the provider immediately before it evaluates its content closure.
    func beginContentPass()

    /// Called by the provider immediately after its content closure returns; disconnects
    /// when no plugin claimed marker rendering during the pass.
    ///
    /// A pull model needs this where the old push model did not: the provider used to see
    /// `markerRenderingStrategy == nil` and clear itself, but now nothing reports the
    /// *absence* of a plugin. Bracketing the content build makes removal observable.
    func endContentPass()
}

/// Registry key used to resolve ``MarkerRenderingSupport`` from ``MapServiceRegistryScope/current``.
///
/// Counterpart of Android's `MarkerRenderingSupportKey`.
public enum MarkerRenderingSupportKey: MapServiceKey {
    public typealias Value = any MarkerRenderingSupport
}

public extension MapServiceRegistry {
    /// Clears the markers drawn through ``MarkerRenderingSupport`` (strategy-driven markers such
    /// as clusters). Every provider's `clearOverlays()` calls this once, after clearing its own
    /// overlay controllers. Does nothing when no marker rendering support is registered.
    @MainActor
    func clearMarkerRendering() async {
        await get(MarkerRenderingSupportKey.self)?.clearMarkers()
    }
}
