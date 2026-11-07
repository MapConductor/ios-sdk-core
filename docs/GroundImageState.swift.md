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
    @Published public var imageUrl: URL?
    @Published public var opacity: Double
    @Published public var tileSize: Int
    @Published public var extra: Any?
    @Published public var onClick: OnGroundImageEventHandler?
    public var onAdded: OnGroundImageAddedHandler?

    public init(
        bounds: GeoRectBounds,
        image: UIImage,
        opacity: Double = 1.0,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil,
        onAdded: OnGroundImageAddedHandler? = nil
    )

    public convenience init(
        bounds: GeoRectBounds,
        imageUrl: URL,
        opacity: Double = 1.0,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil,
        onAdded: OnGroundImageAddedHandler? = nil
    )
}
```

### Loading from a URL

`GroundImageState(bounds:imageUrl:)` loads the image itself, with the same loader as
`ImageIcon(imageUrl:)`. `https:` and `file:` URLs work.

- Until the image arrives, `image` is a 1×1 transparent image. When it arrives, it is assigned to
  `image` and the overlay is redrawn.
- Setting `imageUrl` to another URL keeps the current image until the new one arrives. If it
  changes again before then, the older result is dropped.
- Assigning `image` yourself sets `imageUrl` back to `nil`.
- If loading fails, `image` is left as it is and the failure is logged once per URL.
- `copy()` keeps `imageUrl` unless you pass `image`.
- The generated `id` comes from the URL, so it does not change when the image arrives.

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
- `onAdded`
    - Type: `OnGroundImageAddedHandler?`
    - Default: `nil`
    - Description: Called with this state each time the ground image goes from not being on the map to being on it: for a natively drawn ground image, right after the provider has created its native object. It does not wait for tile images to load or for pixels to show. Not called for in-place changes, on clear, or when the map goes away; called again when the ground image is removed and later added again. Always on the main actor. Not part of the id, fingerprint, `==` or hash; replacing it does not redraw anything.

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
