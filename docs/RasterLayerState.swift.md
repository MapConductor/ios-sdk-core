# RasterLayerState

State object controlling a raster tile layer overlay on the map. Conforms to `ObservableObject`,
`Identifiable`, `Equatable`, and `Hashable`.

## Signature

```swift
public final class RasterLayerState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String

    @Published public var source: RasterLayerSource
    @Published public var opacity: Double
    @Published public var visible: Bool
    @Published public var userAgent: String?
    @Published public var extraHeaders: [String: String]?
    public var onAdded: OnRasterLayerAddedHandler?
    @Published public var extra: Any?

    public init(
        source: RasterLayerSource,
        opacity: Double = 1.0,
        visible: Bool = true,
        userAgent: String? = nil,
        extraHeaders: [String: String]? = nil,
        id: String? = nil,
        extra: Any? = nil,
        onAdded: OnRasterLayerAddedHandler? = nil
    )
}
```

## Constructor Parameters

- `source`
    - Type: `RasterLayerSource`
    - Description: The tile source (URL template, TileJSON, or ArcGIS service).
- `opacity`
    - Type: `Double`
    - Default: `1.0`
    - Description: Opacity from `0.0` (transparent) to `1.0` (opaque).
- `visible`
    - Type: `Bool`
    - Default: `true`
    - Description: Whether the layer is shown on the map.
- `userAgent`
    - Type: `String?`
    - Default: `nil`
    - Description: Custom `User-Agent` header sent with tile requests.
- `extraHeaders`
    - Type: `[String: String]?`
    - Default: `nil`
    - Description: Additional HTTP headers sent with tile requests.
- `id`
    - Type: `String?`
    - Default: `nil`
    - Description: Stable identifier. Auto-generated from content hash if `nil`.
- `extra`
    - Type: `Any?`
    - Default: `nil`
    - Description: Arbitrary user data attached to the layer.
- `onAdded`
    - Type: `OnRasterLayerAddedHandler?`
    - Default: `nil`
    - Description: Called with this state each time the raster layer goes from not being on the map to being on it: for a natively drawn raster layer, right after the provider has created its native object. It does not wait for tile images to load or for pixels to show. Not called for in-place changes, on clear, or when the map goes away; called again when the raster layer is removed and later added again. Always on the main actor. Not part of the id, fingerprint, `==` or hash; replacing it does not redraw anything.

## Methods

### `copy(...)`

Returns a new `RasterLayerState` with any of the given values overriding the current ones.

```swift
public func copy(
    source: RasterLayerSource? = nil,
    opacity: Double? = nil,
    visible: Bool? = nil,
    userAgent: String? = nil,
    extraHeaders: [String: String]? = nil,
    id: String? = nil,
    extra: Any? = nil
) -> RasterLayerState
```

## Example

```swift
let layer = RasterLayerState(
    source: .urlTemplate(
        template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    ),
    opacity: 0.7,
    userAgent: "MyApp/1.0"
)
```
