import Foundation

/// Options for circle tiling.
///
/// When enabled and a map holds enough circles, they are drawn into raster
/// tiles by the SDK's local tile server instead of being handed to the map SDK
/// one by one. Taps are still resolved against the original circles in
/// `CircleManager`, so tiling changes how circles look, never what a tap hits.
///
/// Set it per map with ``MapViewContent/circleTilingOptions`` (or the
/// ``CircleTiling`` element). The counterpart of ``PolylineTilingOptions``;
/// a circle has no vertices, so there is only the count. js-sdk-core's and
/// android-sdk's `CircleTilingOptions` carry the same fields and the same defaults.
public struct CircleTilingOptions: Equatable {
    public let enabled: Bool
    /// Tile once a map holds at least this many circles that can be tiled.
    public let minCircleCount: Int

    public static let Default = CircleTilingOptions()
    public static let Disabled = CircleTilingOptions(enabled: false)

    public init(
        enabled: Bool = true,
        minCircleCount: Int = 2001
    ) {
        self.enabled = enabled
        self.minCircleCount = minCircleCount
    }

    /// The one place the threshold is decided; callers must not restate it.
    public func shouldUseTiles(circleCount: Int) -> Bool {
        enabled && circleCount >= minCircleCount
    }
}
