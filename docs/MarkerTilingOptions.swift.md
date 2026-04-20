# MarkerTilingOptions

Configuration for the marker tiling optimization. When enabled, markers are rendered via a
tile-based system that improves performance for large marker sets.

## Signature

```swift
public struct MarkerTilingOptions {
    public let enabled: Bool
    public let debugTileOverlay: Bool
    public let minMarkerCount: Int
    public let cacheSize: Int
    public let iconScaleCallback: ((MarkerState, Int) -> Double)?

    public static let Disabled: MarkerTilingOptions
    public static let Default: MarkerTilingOptions

    public init(
        enabled: Bool = true,
        debugTileOverlay: Bool = false,
        minMarkerCount: Int = 2000,
        cacheSize: Int = 8 * 1024 * 1024,
        iconScaleCallback: ((MarkerState, Int) -> Double)? = nil
    )
}
```

## Properties

- `enabled`
    - Type: `Bool`
    - Default: `true`
    - Description: Enables tile-based marker rendering when `true`.
- `debugTileOverlay`
    - Type: `Bool`
    - Default: `false`
    - Description: Draws a debug overlay (border lines and label) on each tile.
- `minMarkerCount`
    - Type: `Int`
    - Default: `2000`
    - Description: Minimum number of markers required before tiling activates. Below this
      threshold markers are rendered natively.
- `cacheSize`
    - Type: `Int`
    - Default: `8388608` (8 MB)
    - Description: Maximum tile image cache size in bytes.
- `iconScaleCallback`
    - Type: `((MarkerState, Int) -> Double)?`
    - Default: `nil`
    - Description: Called with the `MarkerState` and zoom level; returns the icon scale factor
      to apply during tile rendering. When `nil`, icons are drawn at their natural size.

## Static Constants

- `Default` — Default tiling options with `enabled = true`.
- `Disabled` — Tiling options with `enabled = false`.

## Example

```swift
let tilingOptions = MarkerTilingOptions(
    enabled: true,
    minMarkerCount: 1000,
    iconScaleCallback: { state, zoom in zoom > 14 ? 1.5 : 1.0 }
)
```
