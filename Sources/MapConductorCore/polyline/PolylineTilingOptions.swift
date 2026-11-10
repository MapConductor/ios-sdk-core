import Foundation

/// Options for polyline tiling.
///
/// When enabled and a map holds enough polylines, they are drawn into raster
/// tiles by the SDK's local tile server instead of being handed to the map SDK
/// one by one. Taps are still resolved against the original lines in
/// `PolylineManager`, so tiling changes how polylines look, never what a tap hits.
///
/// Set it per map with ``MapViewContent/polylineTilingOptions`` (or the
/// ``PolylineTiling`` element). The counterpart of ``PolygonTilingOptions``;
/// js-sdk-core's and android-sdk's `PolylineTilingOptions` carry the same
/// fields and the same defaults.
public struct PolylineTilingOptions: Equatable {
    public let enabled: Bool
    /// Tile once a map holds at least this many polylines…
    public let minPolylineCount: Int
    /// …or at least this many vertices across them, whichever comes first.
    public let minVertexCount: Int

    public static let Default = PolylineTilingOptions()
    public static let Disabled = PolylineTilingOptions(enabled: false)

    public init(
        enabled: Bool = true,
        minPolylineCount: Int = 2000,
        minVertexCount: Int = 50_000
    ) {
        self.enabled = enabled
        self.minPolylineCount = minPolylineCount
        self.minVertexCount = minVertexCount
    }

    /// The one place the threshold is decided; callers must not restate it.
    public func shouldUseTiles(polylineCount: Int, vertexCount: Int) -> Bool {
        enabled && (polylineCount >= minPolylineCount || vertexCount >= minVertexCount)
    }
}
