# RasterSource

Types describing the source of raster tile data for a `RasterLayerState`.

---

# TileScheme

An enum describing the tile coordinate scheme.

## Signature

```swift
public enum TileScheme: String, Hashable {
    case XYZ
    case TMS
}
```

- `XYZ` — Standard slippy map tiles. Y increases downward.
- `TMS` — Tile Map Service. Y increases upward (origin at bottom-left).

---

# RasterSource

An enum representing the kind of tile source.

## Signature

```swift
public enum RasterSource: Hashable {
    case urlTemplate(
        template: String,
        tileSize: Int = RasterSource.defaultTileSize,
        minZoom: Int? = nil,
        maxZoom: Int? = nil,
        attribution: String? = nil,
        scheme: TileScheme = .XYZ
    )
    case tileJson(url: String)
    case arcGisService(serviceUrl: String)

    public static let defaultTileSize: Int = 512
}
```

## Cases

- `urlTemplate(template:tileSize:minZoom:maxZoom:attribution:scheme:)`
    - `template` — Type: `String` — A tile URL template with `{x}`, `{y}`, `{z}` placeholders.
    - `tileSize` — Type: `Int` — Default: `512`.
    - `minZoom` — Type: `Int?` — Default: `nil`. Minimum zoom level.
    - `maxZoom` — Type: `Int?` — Default: `nil`. Maximum zoom level.
    - `attribution` — Type: `String?` — Default: `nil`. Attribution text.
    - `scheme` — Type: `TileScheme` — Default: `.XYZ`.
- `tileJson(url:)`
    - `url` — Type: `String` — URL pointing to a TileJSON metadata document.
- `arcGisService(serviceUrl:)`
    - `serviceUrl` — Type: `String` — ArcGIS REST map service endpoint URL.

## Static Properties

- `defaultTileSize` — `Int` — Default tile size in pixels: `512`.

## Example

```swift
let source = RasterSource.urlTemplate(
    template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    scheme: .XYZ
)
```
