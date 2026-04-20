# MapPaddings

Padding values applied to the visible map area, used to inset UI controls and overlays from the
edges of the map view.

---

# MapPaddingsProtocol

A protocol that all padding types must implement.

## Signature

```swift
public protocol MapPaddingsProtocol {
    var top: Double { get }
    var left: Double { get }
    var bottom: Double { get }
    var right: Double { get }
}
```

---

# MapPaddings

An open class providing concrete padding values. Subclass to extend if needed.

## Signature

```swift
open class MapPaddings: MapPaddingsProtocol {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(
        top: Double = 0.0,
        left: Double = 0.0,
        bottom: Double = 0.0,
        right: Double = 0.0
    )
}
```

## Constructor Parameters

- `top` — Type: `Double` — Top inset in points.
- `left` — Type: `Double` — Left inset in points.
- `bottom` — Type: `Double` — Bottom inset in points.
- `right` — Type: `Double` — Right inset in points.

## Static Properties

- `.Zeros` — A `MapPaddings` instance with all values set to `0.0`.

## Example

```swift
let padding = MapPaddings(top: 60.0, left: 0.0, bottom: 80.0, right: 0.0)
mapView.setPadding(padding)
```
