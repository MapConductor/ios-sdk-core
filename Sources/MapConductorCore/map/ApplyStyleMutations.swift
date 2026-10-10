import Foundation

/**
 The seven things a renderer has to be able to do for a style to be adjusted
 in place.

 A provider implements these against its own SDK and gets
 ``applyStyleMutations(_:_:)`` for everything above them — what each mutation
 means, which ones can be skipped, and keeping one bad property from costing
 the rest. MapLibre and Mapbox name their style APIs differently, so the
 adapter has to be per-provider; the decisions do not.

 Values arrive as JSON text, which is what crossed the FFI boundary: the
 provider turns it into whatever its SDK wants — an `NSExpression` for
 MapLibre here, a `Value` for Mapbox.

 android-sdk-core carries the same protocol, and js-sdk-core does the same
 work structurally — there, MapLibre GL JS, Mapbox GL JS and the MapTiler SDK
 happen to share their method names, so one applier serves all three.
 */
public protocol StyleMutationTarget {
    /**
     Whether the renderer has a style up to be changed.

     **False is not failure, and must not be reported as one.** A renderer
     with no style loaded yet cannot be asked about layers, so without this
     every mutation came back as one the map "cannot" make — which is how an
     app got told "N adjustments were not applied" about a map that was
     merely still loading, and, under ``VectorStyleMutationSupport``'s
     reloading policy, had the adjusted document handed to it for no reason.
     Nothing is lost by waiting: the store puts the whole set back when the
     style loads.

     Implement it. The default is for a target that is always ready; a
     provider whose style arrives asynchronously — which is both of them —
     answers whether it has one.
     */
    var isReady: Bool { get }

    /**
     False for a layer the loaded style does not have.

     Asked only when ``isReady``, so it is about the style's contents and
     never about whether there is a style: answering false for "not loaded
     yet" is what ``isReady`` exists to stop.

     Only the four property changes ask. ``addLayer(_:_:_:)`` and
     ``removeLayer(_:)`` guard themselves, because "is it already there" is a
     question only the renderer can answer about a layer it owns.
     */
    func hasLayer(_ layerId: String) -> Bool

    func setPaint(_ layerId: String, _ key: String, _ valueJson: String) throws

    func setLayout(_ layerId: String, _ key: String, _ valueJson: String) throws

    /// `"null"` removes the filter.
    func setFilter(_ layerId: String, _ filterJson: String) throws

    func setZoomRange(_ layerId: String, _ minZoom: Double, _ maxZoom: Double) throws

    /**
     Adds a layer, or does nothing if the renderer already has one with this
     id — which is the usual case, because a style reload puts the whole set
     back.
     */
    func addLayer(_ layerId: String, _ layerJson: String, _ beforeId: String?) throws

    /// A layer the renderer does not have is not an error.
    func removeLayer(_ layerId: String) throws
}

extension StyleMutationTarget {
    /// For a target with nothing to wait for. Every real provider overrides it.
    public var isReady: Bool { true }
}

/**
 Applies style mutations to a live renderer through `target`.

 The body of a provider's ``VectorStyleMutationSupport``: a provider wires
 this into a ``StyleMutationStore`` and registers that, and every provider
 then behaves identically by construction.

 - Returns: the mutations it could not apply. A layer the loaded style does
   not have, or a property the renderer rejected: the caller is told rather
   than left to assume the map looks the way the rules asked. Nothing is
   thrown — one bad property must not cost the other three hundred. Empty
   while the renderer has no style up, because then there is nothing it
   could not do — only something it has not done yet.
 */
public func applyStyleMutations(
    _ target: StyleMutationTarget,
    _ mutations: [StyleMutation]
) -> [StyleMutation] {
    // Not ready is not a refusal. See ``StyleMutationTarget/isReady``.
    guard target.isReady else { return [] }
    return mutations.filter { mutation in
        do {
            return try !applyOne(target, mutation)
        } catch {
            return true
        }
    }
}

private func applyOne(_ target: StyleMutationTarget, _ mutation: StyleMutation) throws -> Bool {
    switch mutation {
    case let .setPaint(layerId, key, value, _):
        guard target.hasLayer(layerId) else { return false }
        try target.setPaint(layerId, key, value)
    case let .setLayout(layerId, key, value, _):
        guard target.hasLayer(layerId) else { return false }
        try target.setLayout(layerId, key, value)
    case let .setFilter(layerId, value, _):
        guard target.hasLayer(layerId) else { return false }
        try target.setFilter(layerId, value)
    case let .setZoomRange(layerId, minZoom, maxZoom, _, _):
        guard target.hasLayer(layerId) else { return false }
        // The spec's own defaults, for a layer that named neither. Every
        // renderer takes both ends at once, so a mutation that changes one
        // has to restate the other.
        try target.setZoomRange(layerId, minZoom ?? 0, maxZoom ?? 24)
    case let .addLayer(layerId, layer, beforeId):
        try target.addLayer(layerId, layer, beforeId)
    case let .removeLayer(layerId):
        try target.removeLayer(layerId)
    }
    return true
}

/// For a message naming what would not apply.
public func describeStyleMutations(_ mutations: [StyleMutation]) -> String {
    mutations.map(\.target).joined(separator: ", ")
}
