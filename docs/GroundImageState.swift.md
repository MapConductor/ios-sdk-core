# GroundImageState

State object controlling a ground-anchored image overlay on the map. The image is stretched to
cover the specified geographic bounds. Conforms to `ObservableObject`, `Identifiable`, `Equatable`,
and `Hashable`.

## Signature

```swift
public final class GroundImageState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String

    @Published public var bounds: GeoRectBounds
    @Published public var image: UIImage
    @Published public var opacity: Double
    @Published public var tileSize: Int
    @Published public var extra: Any?
    @Published public var onClick: OnGroundImageEventHandler?

    public init(
        bounds: GeoRectBounds,
        image: UIImage,
        opacity: Double = 1.0,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil
    )
}
```

## Constructor Parameters

- `bounds`
    - Type: `GeoRectBounds`
    - Description: The geographic bounding rectangle the image is stretched to cover.
- `image`
    - Type: `UIImage`
    - Description: The image to display as the ground overlay.
- `opacity`
    - Type: `Double`
    - Default: `1.0`
    - Description: Opacity from `0.0` (transparent) to `1.0` (opaque).
- `tileSize`
    - Type: `Int`
    - Default: `512`
    - Description: Tile size in pixels used when rendering the image as tiles.
- `id`
    - Type: `String?`
    - Default: `nil`
    - Description: Stable identifier. Auto-generated from content hash if `nil`.
- `extra`
    - Type: `Any?`
    - Default: `nil`
    - Description: Arbitrary user data attached to the overlay.
- `onClick`
    - Type: `OnGroundImageEventHandler?`
    - Default: `nil`
    - Description: Called when the overlay is tapped. Receives a `GroundImageEvent`.

## Methods

### `copy(...)`

Returns a new `GroundImageState` with any of the given values overriding the current ones.

```swift
public func copy(
    bounds: GeoRectBounds? = nil,
    image: UIImage? = nil,
    opacity: Double? = nil,
    tileSize: Int? = nil,
    id: String? = nil,
    extra: Any? = nil,
    onClick: OnGroundImageEventHandler? = nil
) -> GroundImageState
```

## Example

```swift
let groundImage = GroundImageState(
    bounds: GeoRectBounds(
        southWest: GeoPoint(latitude: 35.65, longitude: 139.75),
        northEast: GeoPoint(latitude: 35.70, longitude: 139.80)
    ),
    image: UIImage(named: "overlay_map")!,
    opacity: 0.8
)
```
