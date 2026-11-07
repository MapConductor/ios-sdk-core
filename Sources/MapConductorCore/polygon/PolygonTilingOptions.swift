import Foundation

/// Options for polygon tiling.
///
/// When enabled and a map holds enough polygons, they are drawn into raster
/// tiles by the SDK's local tile server instead of being handed to the map SDK
/// one by one. Taps are still resolved against the original shapes in
/// `PolygonManager`, so tiling changes how polygons look, never what a tap hits.
///
/// The counterpart of ``MarkerTilingOptions``. js-sdk-core's and android-sdk's
/// `PolygonTilingOptions` carry the same fields and the same defaults.
public struct PolygonTilingOptions: Equatable {
    public let enabled: Bool
    /// Tile once a map holds at least this many polygons…
    public let minPolygonCount: Int
    /// …or at least this many vertices across them, whichever comes first.
    public let minVertexCount: Int

    public static let Default = PolygonTilingOptions()
    public static let Disabled = PolygonTilingOptions(enabled: false)

    public init(
        enabled: Bool = true,
        minPolygonCount: Int = 2000,
        minVertexCount: Int = 50_000
    ) {
        self.enabled = enabled
        self.minPolygonCount = minPolygonCount
        self.minVertexCount = minVertexCount
    }

    /// The one place the threshold is decided; callers must not restate it.
    public func shouldUseTiles(polygonCount: Int, vertexCount: Int) -> Bool {
        enabled && (polygonCount >= minPolygonCount || vertexCount >= minVertexCount)
    }
}
