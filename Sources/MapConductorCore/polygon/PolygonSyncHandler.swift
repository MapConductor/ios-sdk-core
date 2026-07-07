import Foundation

/// Adopted by overlay managers that need to commit polygon updates synchronously before
/// marker animations start. Map view coordinators call ``bindPolygonSync(_:)`` to provide
/// a polygon sync function; the handler wires it to the strategy's `onBeforeAnimation`
/// callback so polygon changes always precede animation.
public protocol PolygonSyncHandler: AnyObject {
    /// Called by the map view coordinator to wire up imperative hull polygon management.
    ///
    /// The map view calls this on every `updateContent` pass, providing a function that
    /// replaces the handler's managed polygon set. The handler stores the function and
    /// invokes it from the strategy's `onBeforeAnimation` callback before animation starts.
    func bindPolygonSync(_ polygonSync: @escaping @MainActor ([PolygonState]) async -> Void)
}
