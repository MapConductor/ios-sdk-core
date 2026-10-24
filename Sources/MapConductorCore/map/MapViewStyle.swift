import Foundation

/**
 How a map looks, as a property of the map rather than a layer inside it.

 A vector style *is* the basemap, so passing one to
 `XxxMapView(state:style:)` says what it is rather than mounting something
 over it. What happens underneath depends on the backend and the app does not
 have to know: MapLibre, Mapbox and MapTiler are told the style and draw it
 themselves; Google Maps, MapKit, HERE, ArcGIS and the rest are handed raster
 tiles rendered from the same style on the device. Either way the same
 adjustments produce the same map.

 A protocol rather than a type, for two reasons. Core must not depend on the
 style compiler or the rasteriser -- both are optional modules, and one of
 them is a megabyte of native code -- so what core holds is the seam and the
 modules bring the implementation. And a provider's own styling, which is
 nothing like a MapLibre style, can be added later as another conformance
 without this changing.

 The concrete types live in the vector style module
 (`MapConductorVectorStyle`); an app does not conform to this.

 android-sdk-core and js-sdk-core carry the same seam.
 */
public protocol MapViewStyle {
    /**
     What identifies this style's content.

     The map re-installs a style whose key changed and leaves alone one whose
     key did not. Two values describing the same thing must have the same
     key: a style built inline in a `body` is a new value on every
     evaluation -- which is exactly what a colour picker produces -- and
     keying off identity would reinstall the whole style on every unrelated
     state change.
     */
    var key: String { get }

    /**
     Puts the style on the map. Called once the map has a style loaded, and
     again if it loads another one.

     - Returns: the ticket that takes it off again. Disposing must leave the
       map as it was found: a style that cannot be fully undone has no
       business being installed, because the app will switch away from it.
     */
    func install(host: MapStyleHost) -> MapStyleInstallation
}

/**
 A ticket to undo, and a chance to take a change without tearing down.

 Returned by anything that sets something up on a map. A value holding
 closures rather than a protocol: everything that hands one out would
 otherwise need a type whose only job is to remember how to undo one thing.
 */
public struct MapStyleInstallation {
    private let onDispose: () -> Void
    private let onUpdate: (MapViewStyle) -> Bool

    /**
     - Parameter update: takes `next` in place, when it is near enough to
       what is installed, and answers whether it did.

       Without this the whole point is lost. A style whose key changed is
       installed again, and installing a style means handing the map a
       document -- which is the reload this design exists to avoid. Moving a
       colour slider changes the adjustments and nothing else, so the
       installed style answers true, applies the difference, and the map
       never reloads anything. False is always correct, only slower: the
       caller then disposes and installs from scratch.
     */
    public init(
        dispose: @escaping () -> Void,
        update: @escaping (MapViewStyle) -> Bool = { _ in false }
    ) {
        onDispose = dispose
        onUpdate = update
    }

    public func dispose() {
        onDispose()
    }

    public func update(_ next: MapViewStyle) -> Bool {
        onUpdate(next)
    }

    /// For a style that set nothing up.
    public static let none = MapStyleInstallation(dispose: {})
}

/**
 What a map offers to the style installed on it.

 The provider implements this; a ``MapViewStyle`` uses it and never touches a
 provider type. That is what keeps one style implementation working on every
 backend.
 */
public protocol MapStyleHost: AnyObject {
    /**
     Where to look for what this map can do:
     ``VectorStyleSupportKey`` to hand over a style document,
     ``VectorStyleMutationSupportKey`` to change a loaded one in place,
     ``RasterTilePreferenceKey`` for the tile size it would rather have.
     */
    var serviceRegistry: MapServiceRegistry { get }

    /// For serving a style document, or tiles rendered from one, to the map.
    var tileServer: LocalTileServer { get }

    /**
     The vector style the map is drawing now, when it is drawing one.

     Nil on every backend that has no such thing, which is most of them. It
     is how a rule set that adjusts "whatever is showing" finds something to
     adjust: the style has to be read before a rule can be matched against
     its layers, and only the map knows where it came from.
     */
    var vectorStyleUrl: String? { get }

    /**
     Runs `block` whenever the map finishes loading a style, including the
     one it has now if it already has one.

     Everything a style installs on a live renderer is lost when that
     renderer loads a document again, for any reason. This is how it gets put
     back.
     */
    func onStyleLoaded(_ block: @escaping () -> Void) -> MapStyleInstallation

    /**
     Adds or updates a raster layer the app did not declare.

     The raster path needs somewhere to put its tiles, and that cannot be the
     view's content: the style is a property of the view, so it is installed
     from outside. Marker tiling already mounts its layer the same way.
     */
    func upsertRaster(_ state: RasterLayerState)

    func removeRaster(id: String)

    /**
     Says what the app should know: a rule that matched nothing, an
     adjustment this backend cannot make, a style that could not be read.

     Routed to whatever the host gave the style, so a module can report
     without knowing how the app logs.
     */
    func report(_ diagnostics: [String])
}

public extension MapStyleHost {
    var vectorStyleUrl: String? { nil }
}
