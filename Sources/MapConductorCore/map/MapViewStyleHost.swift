import Foundation

/**
 A controller that can mount a raster layer the view's content did not
 declare.

 ``RasterLayerController`` already does both of these; this is the name that
 lets a caller reach them without knowing which provider's controller it has.
 `compositionRasterLayers` replaces the whole set with what the content
 declared, so anything mounted from outside would be swept away on the next
 pass — `upsert` keeps its ids out of that sweep.

 Two callers need it: marker tiling, and a ``MapViewStyle`` on a backend that
 cannot draw a vector style and has to be handed tiles rendered from one.
 */
public protocol RasterLayerMounting: AnyObject {
    func upsert(state: RasterLayerState) async
    func removeById(_ id: String) async
}

/**
 What a map offers the style installed on it, and the bookkeeping that keeps
 it installed.

 One class for every provider. Everything it needs that differs per backend
 is reached through the service registry, which every provider already fills
 in — ``VectorStyleSupportKey`` for handing over a document,
 ``VectorStyleMutationSupportKey`` for changing a loaded one,
 ``OverlayControllerRegistryKey`` for mounting tiles. Adding a provider needs
 nothing here.

 Most coordinators get one from ``MapViewCoordinatorBase``; a provider whose
 coordinator is not one (ArcGIS, the template) holds its own.

 android-sdk's `MapViewStyleEffect` and js-sdk-react's `useMapViewStyle` do
 the same work; the shape differs because each framework owns its lifecycle
 differently.
 */
public final class MapViewStyleHost: MapStyleHost {
    public let serviceRegistry: MapServiceRegistry

    private var installation: MapStyleInstallation?
    private var installedKey: String?
    private var diagnosticsHandler: (([String]) -> Void)?

    /// How many updates in a row the installed style has refused. See ``apply(_:onDiagnostics:)``.
    private var refusedUpdates = 0
    private static let churnThreshold = 5

    /// Sticky, because a provider can finish loading before anything has
    /// asked to be told about it.
    private var didLoadStyle = false
    private var styleLoadedListeners: [UUID: () -> Void] = [:]

    public init(serviceRegistry: MapServiceRegistry) {
        self.serviceRegistry = serviceRegistry
    }

    deinit {
        installation?.dispose()
    }

    // MARK: - Keeping a style installed

    /**
     Keeps `style` installed on this map.

     Called from the representable's `makeUIView` and `updateUIView`, which
     is every evaluation of the app's `body` — so most calls do nothing.
     Three things have to line up and none of them is the view update:

     - **A style whose key did not change must be left alone.** A style built
       inline in a `body` is a new value on every evaluation — which is
       exactly what a colour picker produces — so comparing values would
       reinstall on every unrelated state change.
     - **A changed style is usually an adjustment, not a new style.**
       Disposing and installing again hands the map a document and reloads
       it, which is the cost this whole design exists to avoid. What is
       installed is offered the new one first and only replaced if it
       refuses.
     - **Nil means take it off.** An app that stops passing a style gets the
       map it had before, not the one the style left behind.
     */
    public func apply(_ style: MapViewStyle?, onDiagnostics: (([String]) -> Void)? = nil) {
        diagnosticsHandler = onDiagnostics
        guard let style else {
            dispose()
            return
        }
        guard let installed = installation else {
            installation = style.install(host: self)
            installedKey = style.key
            return
        }
        // Nothing changed at all. The key covers the document *and* the
        // rules, so an equal key means there is no work -- and doing it
        // anyway is not merely wasteful: recompiling re-reports the
        // diagnostics, an app that renders them sets state, that evaluates
        // the body again, and the two spin against each other.
        if installedKey == style.key { return }

        // The adjustments moved. Offer them to what is installed: taking
        // them in place is what keeps a slider from reloading the map.
        if installed.update(style) {
            installedKey = style.key
            refusedUpdates = 0
            return
        }

        // Refused -- correct, only slower. Refusing every time means the
        // style cannot recognise its own successor and the map is rebuilt
        // on each change; the usual cause is a value the style compares by
        // identity being rebuilt too, a rasteriser held in a `let` on a
        // `View` rather than `@State`.
        refusedUpdates += 1
        if refusedUpdates == Self.churnThreshold {
            MCLog.map(
                "style: the installed style has refused \(Self.churnThreshold) updates in a row, "
                    + "so the map is being torn down and rebuilt on every change. Hold the "
                    + "rasteriser (and anything else the style compares by identity) in @State "
                    + "rather than rebuilding it."
            )
        }
        installed.dispose()
        installation = style.install(host: self)
        installedKey = style.key
    }

    /// Takes the style off. The representable calls this when the view goes.
    public func dispose() {
        installation?.dispose()
        installation = nil
        installedKey = nil
    }

    /**
     Called by the provider once the map has a style up **and** the overlays
     are back on it.

     Not when the load starts, and not before the provider has put its own
     layers back: a listener that patches a style mid-rebuild patches
     something that is about to be replaced.
     */
    public func notifyStyleLoaded() {
        didLoadStyle = true
        styleLoadedListeners.values.forEach { $0() }
    }

    // MARK: - MapStyleHost

    public var tileServer: LocalTileServer { TileServerRegistry.get() }

    public var vectorStyleUrl: String? {
        serviceRegistry.get(VectorStyleSupportKey.self)?.currentStyleUrl
    }

    /**
     Runs `block` every time this map finishes loading a style, and once now
     if it already has one.

     Everything a style put on a live renderer — paint properties, a layer it
     added — is gone when that renderer loads a document again, for any
     reason: the app switching basemap, a design change, the provider
     rebuilding its view. This is how it goes back on, and it is a registry
     rather than one listener because both the mutation store and the style
     installation need to hear it.

     A provider with no such thing (Google Maps, MapKit, HERE...) never calls
     ``notifyStyleLoaded()``, and a style installed on it is one that was
     rasterised into tiles — which survives a basemap change by itself.
     */
    public func onStyleLoaded(_ block: @escaping () -> Void) -> MapStyleInstallation {
        let token = UUID()
        styleLoadedListeners[token] = block
        if didLoadStyle { block() }
        return MapStyleInstallation(dispose: { [weak self] in
            self?.styleLoadedListeners.removeValue(forKey: token)
        })
    }

    public func upsertRaster(_ state: RasterLayerState) {
        let controllers = rasterMounts()
        guard !controllers.isEmpty else {
            noRasterMount(state.id)
            return
        }
        Task { @MainActor in
            for controller in controllers { await controller.upsert(state: state) }
        }
    }

    public func removeRaster(id: String) {
        let controllers = rasterMounts()
        guard !controllers.isEmpty else { return }
        Task { @MainActor in
            for controller in controllers { await controller.removeById(id) }
        }
    }

    public func report(_ diagnostics: [String]) {
        guard !diagnostics.isEmpty else { return }
        if let diagnosticsHandler {
            diagnosticsHandler(diagnostics)
        } else {
            // Never dropped. A rule that matched nothing, or an adjustment
            // this backend could not make, is the kind of thing that
            // otherwise shows up as "the style nearly worked" with no way to
            // find out why.
            diagnostics.forEach { MCLog.map("style: \($0)") }
        }
    }

    /**
     The raster controllers this map registered.

     Reached through the overlay registry rather than a per-provider
     property, so adding a provider needs nothing here.
     */
    /**
     Says so when a provider has nowhere to mount one.

     Every provider registers its raster controller in the overlay registry
     and so gets ``upsertRaster(_:)`` for free. One that does not would
     otherwise show an empty map and say nothing, which is the failure this
     whole design is built against. android-sdk reports the same thing from
     `BaseMapViewController`.
     */
    /**
     Said out loud, not logged.

     With no raster controller there is nowhere to put the tiles, so the
     style compiles, reports its rules, and draws nothing -- the map simply
     keeps the backend's own basemap. Behind a log line that only appears
     with `MAPCONDUCTOR_DEBUG_LOG=1`, that reads as "the style silently does
     not work", which is exactly how it read for ArcGIS.
     */
    private func noRasterMount(_ id: String) {
        report([
            "raster layer \(id) was not mounted: this provider registered no raster controller "
                + "in its overlay registry, so there is nowhere to put the tiles this style "
                + "was rendered into"
        ])
    }

    private func rasterMounts() -> [any RasterLayerMounting] {
        guard let registry = serviceRegistry.get(OverlayControllerRegistryKey.self) else { return [] }
        return registry.all().compactMap { $0 as? any RasterLayerMounting }
    }
}

public extension MapViewCoordinatorBase {
    /// See ``MapViewStyleHost/apply(_:onDiagnostics:)``.
    func applyStyle(_ style: MapViewStyle?, onDiagnostics: (([String]) -> Void)? = nil) {
        styleHost.apply(style, onDiagnostics: onDiagnostics)
    }

    /// See ``MapViewStyleHost/dispose()``.
    func disposeStyle() {
        styleHost.dispose()
    }

    /// See ``MapViewStyleHost/notifyStyleLoaded()``.
    func notifyStyleLoaded() {
        styleHost.notifyStyleLoaded()
    }
}

#if canImport(UIKit)
    import SwiftUI
    import UIKit

    /**
     Keeps a ``MapViewStyle`` applied from inside a pure-SwiftUI map.

     Most providers wrap a `UIView`, so their representable's `updateUIView`
     is already the hook that runs on every evaluation of the app's `body`.
     ArcGIS and the template draw with SwiftUI views instead and have no such
     hook — and `body` itself is the wrong place, because reading a style
     there and installing it would be a side effect in a view's description
     of itself.

     So they mount this: an empty view whose only job is to have an
     `updateUIView`. Zero-sized and hidden, it draws nothing and lays nothing
     out.
     */
    public struct MapViewStyleApplier: UIViewRepresentable {
        private let host: MapViewStyleHost
        private let style: MapViewStyle?
        private let onDiagnostics: (([String]) -> Void)?

        public init(
            host: MapViewStyleHost,
            style: MapViewStyle?,
            onDiagnostics: (([String]) -> Void)? = nil
        ) {
            self.host = host
            self.style = style
            self.onDiagnostics = onDiagnostics
        }

        public func makeUIView(context _: Context) -> UIView {
            let view = UIView(frame: .zero)
            view.isHidden = true
            view.isUserInteractionEnabled = false
            return view
        }

        public func updateUIView(_: UIView, context _: Context) {
            host.apply(style, onDiagnostics: onDiagnostics)
        }
    }
#endif
