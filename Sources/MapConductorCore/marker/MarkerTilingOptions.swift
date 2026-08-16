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

    /// タイル方式で描くか。**この判定を各所で書き直さないこと。**
    ///
    /// 以前は `enabled` を見ずに件数だけで判定している箇所があり、
    /// `Disabled` を渡したページでもタイル扱いになって、マーカー追従が
    /// 理由も出ずに止まっていた（React Native のブリッジ層で実際に起きた）。
    /// android-sdk-core の `MarkerTilingOptions.shouldUseTiles` と同じ規則。
    public func shouldUseTiles(markerCount: Int) -> Bool {
        enabled && markerCount >= minMarkerCount
    }
}
