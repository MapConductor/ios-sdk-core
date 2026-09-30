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

    private var installed: State.ActualMapDesignType?
    private var installedUrl: String?
    private var previous: State.ActualMapDesignType?
    private var pendingClear: DispatchWorkItem?

    public init(
        state: State,
        designId: @escaping (State.ActualMapDesignType) -> String,
        designFor: @escaping (_ url: String, _ attributionRules: [AttributionRule]) -> State.ActualMapDesignType
    ) {
        self.state = state
        self.designId = designId
        self.designFor = designFor
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
