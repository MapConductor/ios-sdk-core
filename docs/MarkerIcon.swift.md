# MarkerIcon

Marker icon types used to customize the appearance of map markers.

---

# MarkerIconProtocol

A protocol that all marker icon types must implement.

## Signature

```swift
public protocol MarkerIconProtocol {
    var scale: CGFloat { get }
    var anchor: CGPoint { get }
    var iconSize: CGFloat { get }
    var infoAnchor: CGPoint { get }
    var debug: Bool { get }

    func toBitmapIcon() -> BitmapIcon
    func hashCode() -> Int
}
```

## Properties

- `scale` — Type: `CGFloat` — Scale multiplier applied to the icon.
- `anchor` — Type: `CGPoint` — Anchor point as a fraction of icon size. `(0.5, 1.0)` = bottom-center.
- `iconSize` — Type: `CGFloat` — Logical size of the icon in points (used for clustering/tiling).
- `infoAnchor` — Type: `CGPoint` — Attachment point for info bubbles (fraction of icon size).
- `debug` — Type: `Bool` — When `true`, draws a debug border around the icon.

---

# BitmapIcon

A marker icon backed by a `UIImage`.

## Signature

```swift
public struct BitmapIcon: MarkerIconProtocol, Equatable, Hashable {
    public let bitmap: UIImage
    public let anchor: CGPoint
    public let size: CGSize
    public let scale: CGFloat
    public let iconSize: CGFloat
    public let infoAnchor: CGPoint
    public let debug: Bool

    public init(
        bitmap: UIImage,
        anchor: CGPoint = CGPoint(x: 0.5, y: 1.0),
        size: CGSize? = nil,
        scale: CGFloat = 1.0,
        iconSize: CGFloat? = nil,
        infoAnchor: CGPoint = CGPoint(x: 0.5, y: 0.0),
        debug: Bool = false
    )
}
```

## Constructor Parameters

- `bitmap`
    - Type: `UIImage`
    - Description: The image to use as the marker icon.
- `anchor`
    - Type: `CGPoint`
    - Default: `CGPoint(x: 0.5, y: 1.0)`
    - Description: Anchor point as a fraction of image size. Default is bottom-center.
- `size`
    - Type: `CGSize?`
    - Default: `nil` (uses `bitmap.size`)
    - Description: Explicit size override. If `nil`, the bitmap's natural size is used.
- `scale`
    - Type: `CGFloat`
    - Default: `1.0`
    - Description: Scale multiplier applied to the icon.
- `iconSize`
    - Type: `CGFloat?`
    - Default: `nil` (uses `max(size.width, size.height)`)
    - Description: Logical size used for clustering/tiling layout.
- `infoAnchor`
    - Type: `CGPoint`
    - Default: `CGPoint(x: 0.5, y: 0.0)`
    - Description: Attachment point for info bubbles (fraction of icon size, top-center by default).
- `debug`
    - Type: `Bool`
    - Default: `false`
    - Description: When `true`, draws a debug border around the icon.

## Example

```swift
let icon = BitmapIcon(bitmap: UIImage(named: "custom_pin")!)
let marker = MarkerState(
    position: GeoPoint(latitude: 35.6812, longitude: 139.7671),
    icon: icon
)
```
