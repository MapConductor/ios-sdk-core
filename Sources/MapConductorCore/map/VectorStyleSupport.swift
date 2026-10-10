import Foundation

/**
 A map that can draw a MapLibre style itself.

 MapLibre, Mapbox and MapTiler are vector renderers already: handing them a
 style document is cheaper than rasterising it on the device and feeding the
 result back as PNG tiles, which is what a backend that only takes raster
 (Google Maps, MapKit, ArcGIS, HERE...) has to be given. A provider that can
 take the style directly registers this under ``VectorStyleSupportKey``; a
 layer that has a style to show looks the key up and, if it is there, skips
 the rasteriser altogether.

 The style *becomes the basemap*: on every provider that can do this, the
 style is the map, so showing one replaces the design the state names and
 clearing it puts that design back. A style drawn this way is not an overlay
 -- it has no opacity, and nothing of the previous basemap shows through it.
 Anything that needs the style on top of another basemap goes through the
 raster path.

 android-sdk-core and js-sdk-core carry the same capability.
 */
public protocol VectorStyleSupport: AnyObject {
    /**
     Draws the style at `url` as the map's basemap.

     `attributionRules` are the credits the style's sources ask for, carried
     by the design so the map's attribution overlay shows them for as long as
     the style is up.
     */
    func showStyle(url: String, attributionRules: [AttributionRule])

    /**
     Restores the design that was showing before ``showStyle(url:attributionRules:)``,
     unless the app has since chosen another one, in which case that choice
     is left alone.
     */
    func clearStyle()

    /**
     Where the style the map is drawing came from, when that is knowable.

     This is what lets a rule set adjust *whatever is showing* rather than a
     style the app had to name: the document has to be read before a rule can
     be matched against its layers, and only the provider knows where it came
     from.

     Nil when it is not a URL anything can fetch -- a provider's own named
     design (`mapbox://styles/mapbox/standard`), a style that needs a key
     this does not have. A caller that wanted it says so and leaves the map
     alone rather than showing something unstyled.
     */
    var currentStyleUrl: String? { get }
}

public extension VectorStyleSupport {
    var currentStyleUrl: String? { nil }
}

/// ``VectorStyleSupport`` の登録キー。
///
/// 宣言しないプロバイダは「スタイルは受け取れない」。ベクタータイル層はその場合
/// ラスタータイルに描いて渡す。
public enum VectorStyleSupportKey: MapServiceKey {
    public typealias Value = VectorStyleSupport
}

/**
 ``VectorStyleSupport`` for a provider whose design type can name a style URL.

 The three MapLibre-based providers differ only in how a URL is wrapped into
 their design type, which is what `designFor` supplies; the remember-and-
 restore dance is the same for all of them and lives here once. The "still
 ours" check on ``clearStyle()`` is what keeps this from fighting an app that
 switched designs while the style was up: a layer unmounting must not undo a
 choice the app made after it.

 ``clearStyle()`` takes effect a moment later rather than at once, and a
 ``showStyle(url:attributionRules:)`` of the same URL in between cancels it.
 A host that rebuilds its overlay content on a design change remounts the
 layer that asked for the style *by the change it caused*; clearing on that
 unmount would restore the old design, which would rebuild again, and so on
 without end. Waiting one frame lets the remount cancel the clear.
 */
public final class VectorStyleAsDesign<State: MapViewStateProtocol>: VectorStyleSupport {
    private weak var state: State?
    private let designId: (State.ActualMapDesignType) -> String
    private let designFor: (String, [AttributionRule]) -> State.ActualMapDesignType
    private let urlOf: ((State.ActualMapDesignType) -> String?)?

    private var installed: State.ActualMapDesignType?
    private var installedUrl: String?
    private var previous: State.ActualMapDesignType?
    private var pendingClear: DispatchWorkItem?

    public init(
        state: State,
        designId: @escaping (State.ActualMapDesignType) -> String,
        urlOf: ((State.ActualMapDesignType) -> String?)? = nil,
        designFor: @escaping (_ url: String, _ attributionRules: [AttributionRule]) -> State.ActualMapDesignType
    ) {
        self.state = state
        self.designId = designId
        self.urlOf = urlOf
        self.designFor = designFor
    }

    /**
     Where the design **the app chose** points, when it points anywhere
     fetchable.

     Deliberately not the URL this capability installed. That one is the
     document the style module served a moment ago, and it is unregistered
     from the tile server the instant the style comes off -- so answering
     with it turns "adjust whatever is showing" into a 404 against our own
     corpse. When one of ours is up, the honest answer is the design it
     replaced.

     Nil unless the provider supplied `urlOf`, and nil from that for a design
     that is not a plain style document -- a provider's own named basemap, or
     one that needs a key this does not have.
     */
    public var currentStyleUrl: String? {
        guard let urlOf else { return nil }
        if installed != nil { return previous.flatMap(urlOf) }
        guard let state else { return nil }
        return urlOf(state.mapDesignType)
    }

    public func showStyle(url: String, attributionRules: [AttributionRule]) {
        pendingClear?.cancel()
        pendingClear = nil
        guard let state else { return }
        // Same style, still up: nothing to do, and writing the design again
        // would reload it for nothing.
        if let current = installed, installedUrl == url, designId(state.mapDesignType) == designId(current) {
            return
        }
        let design = designFor(url, attributionRules)
        // Showing a second style over the first keeps the *original* design
        // as the one to go back to; the intermediate style was never the
        // app's basemap.
        if installed == nil { previous = state.mapDesignType }
        installed = design
        installedUrl = url
        state.mapDesignType = design
    }

    public func clearStyle() {
        guard installed != nil else { return }
        pendingClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClear = nil
            guard let current = self.installed else { return }
            let restore = self.previous
            self.installed = nil
            self.installedUrl = nil
            self.previous = nil
            guard let state = self.state, let restore else { return }
            if self.designId(state.mapDesignType) == self.designId(current) {
                state.mapDesignType = restore
            }
        }
        pendingClear = clear
        // Longer than a frame, shorter than anyone notices.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: clear)
    }
}
