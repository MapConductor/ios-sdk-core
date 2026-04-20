# DefaultMarkerIcon

A `MarkerIconProtocol` implementation that renders the SDK's built-in teardrop/pin shape.
Customize color, size, label, and stroke via constructor parameters or `copy()`.

## Signature

```swift
public final class DefaultMarkerIcon: MarkerIconProtocol {
    public static let defaultIconSize: CGFloat = 48.0
    public static let defaultStrokeWidth: CGFloat = 1.0
    public static let defaultFillColor: UIColor = .red
    public static let defaultStrokeColor: UIColor = .white
    public static let defaultLabelTextSize: CGFloat = 18.0
    public static let defaultLabelTextColor: UIColor = .black
    public static let defaultLabelStrokeColor: UIColor = .white
    public static let defaultLabelTypeFace: UIFont = .systemFont(ofSize: 18.0)
    public static let defaultInfoAnchor: CGPoint = CGPoint(x: 0.5, y: 0.0)

    public let scale: CGFloat
    public let anchor: CGPoint  // always CGPoint(x: 0.5, y: 1.0) — bottom-center
    public let iconSize: CGFloat
    public let infoAnchor: CGPoint
    public let debug: Bool

    public init(
        fillColor: UIColor = defaultFillColor,
        strokeColor: UIColor = defaultStrokeColor,
        strokeWidth: CGFloat = defaultStrokeWidth,
        scale: CGFloat = 1.0,
        label: String? = nil,
        labelTextColor: UIColor? = defaultLabelTextColor,
        labelTextSize: CGFloat = defaultLabelTextSize,
        labelTypeFace: UIFont = defaultLabelTypeFace,
        labelStrokeColor: UIColor = defaultLabelStrokeColor,
        infoAnchor: CGPoint = defaultInfoAnchor,
        iconSize: CGFloat = defaultIconSize,
        debug: Bool = false
    )
}
```

## Constructor Parameters

- `fillColor` — Type: `UIColor` — Default: `.red`. Fill color of the pin shape.
- `strokeColor` — Type: `UIColor` — Default: `.white`. Outline color of the pin shape.
- `strokeWidth` — Type: `CGFloat` — Default: `1.0`. Outline width in points.
- `scale` — Type: `CGFloat` — Default: `1.0`. Scale multiplier applied to the icon.
- `label` — Type: `String?` — Default: `nil`. Optional text rendered inside the pin.
- `labelTextColor` — Type: `UIColor?` — Default: `.black`. Color of the label text.
- `labelTextSize` — Type: `CGFloat` — Default: `18.0`. Font size of the label.
- `labelTypeFace` — Type: `UIFont` — Default: `.systemFont(ofSize: 18.0)`. Font for the label.
- `labelStrokeColor` — Type: `UIColor` — Default: `.white`. Outline color around label text.
- `infoAnchor` — Type: `CGPoint` — Default: `(0.5, 0.0)`. Info bubble attachment point.
- `iconSize` — Type: `CGFloat` — Default: `48.0`. Logical icon size in points.
- `debug` — Type: `Bool` — Default: `false`. Draws a debug border when `true`.

## Methods

### `copy(...)`

Returns a new `DefaultMarkerIcon` with any of the given values overriding the current ones.

```swift
public func copy(
    fillColor: UIColor? = nil,
    strokeColor: UIColor? = nil,
    strokeWidth: CGFloat? = nil,
    scale: CGFloat? = nil,
    label: String? = nil,
    labelTextColor: UIColor? = nil,
    labelTextSize: CGFloat? = nil,
    labelTypeFace: UIFont? = nil,
    labelStrokeColor: UIColor? = nil,
    iconSize: CGFloat? = nil,
    debug: Bool? = nil
) -> DefaultMarkerIcon
```

## Notes

- `anchor` is always `CGPoint(x: 0.5, y: 1.0)` (bottom-center), unlike `ImageIcon` which
  defaults to `(0.5, 0.5)`.

## Example

```swift
let redPin = DefaultMarkerIcon()
let bluePin = DefaultMarkerIcon(fillColor: .blue, strokeColor: .white)
let labelledPin = DefaultMarkerIcon(fillColor: .green, label: "42")

let marker = MarkerState(
    position: GeoPoint(latitude: 35.6812, longitude: 139.7671),
    icon: bluePin
)
```
