# ImageIcon

A `MarkerIconProtocol` implementation that renders a `UIImage` as-is (scaled to the requested
size) without applying the default marker/pin shape. Unlike `BitmapIcon`, the default anchor is
centered `(0.5, 0.5)`.

## Signature

```swift
public final class ImageIcon: MarkerIconProtocol {
    public static let defaultIconSize: CGFloat = DefaultMarkerIcon.defaultIconSize  // 48.0
    public static let defaultAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    public static let defaultInfoAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)

    public let iconSize: CGFloat
    public let scale: CGFloat
    public let anchor: CGPoint
    public let infoAnchor: CGPoint
    public let debug: Bool

    public init(
        image: UIImage,
        iconSize: CGFloat = defaultIconSize,
        scale: CGFloat = 1.0,
        anchor: CGPoint = defaultAnchor,
        infoAnchor: CGPoint = defaultInfoAnchor,
        debug: Bool = false
    )
}
```

## Constructor Parameters

- `image`
    - Type: `UIImage`
    - Description: The image to display as the marker icon.
- `iconSize`
    - Type: `CGFloat`
    - Default: `48.0`
    - Description: Logical icon size in points. The image is scaled to this size.
- `scale`
    - Type: `CGFloat`
    - Default: `1.0`
    - Description: Scale multiplier applied to the icon.
- `anchor`
    - Type: `CGPoint`
    - Default: `CGPoint(x: 0.5, y: 0.5)`
    - Description: Anchor point as a fraction of icon size. Default is center.
- `infoAnchor`
    - Type: `CGPoint`
    - Default: `CGPoint(x: 0.5, y: 0.5)`
    - Description: Attachment point for info bubbles.
- `debug`
    - Type: `Bool`
    - Default: `false`
    - Description: When `true`, draws a debug border around the icon.

## Methods

### `copy(...)`

Returns a new `ImageIcon` with any of the given values overriding the current ones.

```swift
public func copy(
    image: UIImage? = nil,
    iconSize: CGFloat? = nil,
    scale: CGFloat? = nil,
    anchor: CGPoint? = nil,
    infoAnchor: CGPoint? = nil,
    debug: Bool? = nil
) -> ImageIcon
```

## Notes

- `ImageIcon.defaultAnchor` is `(0.5, 0.5)` (center), whereas `DefaultMarkerIcon` and
  `BitmapIcon` default to `(0.5, 1.0)` (bottom-center).

## Example

```swift
let icon = ImageIcon(image: UIImage(named: "shop_icon")!)
let marker = MarkerState(
    position: GeoPoint(latitude: 35.6812, longitude: 139.7671),
    icon: icon
)
```
