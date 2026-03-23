import Foundation

/// Options for marker tiling optimization.
///
/// When enabled, large sets of static markers can be rendered as tile overlays
/// to avoid per-marker add/update cost in native map SDKs.
public struct MarkerTilingOptions {
    public let enabled: Bool
    /// When enabled, draws a debug overlay onto marker tiles: top/left border lines and a label.
    public let debugTileOverlay: Bool
    /// Minimum marker count to activate tiling. Below this threshold markers are rendered natively.
    public let minMarkerCount: Int
    /// Maximum tile cache size in bytes.
    public let cacheSize: Int
    /// Extra scale multiplier applied per marker per zoom level during tile rendering.
    public let iconScaleCallback: ((MarkerState, Int) -> Double)?

    public static let Disabled = MarkerTilingOptions(enabled: false)
    public static let Default = MarkerTilingOptions()

    public init(
        enabled: Bool = true,
        debugTileOverlay: Bool = false,
        minMarkerCount: Int = 2000,
        cacheSize: Int = 8 * 1024 * 1024,
        iconScaleCallback: ((MarkerState, Int) -> Double)? = nil
    ) {
        self.enabled = enabled
        self.debugTileOverlay = debugTileOverlay
        self.minMarkerCount = minMarkerCount
        self.cacheSize = cacheSize
        self.iconScaleCallback = iconScaleCallback
    }
}
