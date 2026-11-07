# CircleState

State object controlling a single circle overlay on the map. Conforms to `ObservableObject`,
`Identifiable`, `Equatable`, and `Hashable`.

## Signature

```swift
public final class CircleState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String

    @Published public var center: GeoPointProtocol
    @Published public var radiusMeters: Double
    @Published public var geodesic: Bool
    @Published public var clickable: Bool
    @Published public var strokeColor: UIColor
    @Published public var strokeWidth: Double
    @Published public var fillColor: UIColor
    @Published public var zIndex: Int?
    @Published public var extra: Any?
    @Published public var onClick: OnCircleEventHandler?
    public var onAdded: OnCircleAddedHandler?

    public init(
        center: GeoPointProtocol,
        radiusMeters: Double,
        geodesic: Bool = true,
        clickable: Bool = true,
        strokeColor: UIColor = .red,
        strokeWidth: Double = 1.0,
        fillColor: UIColor = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.5),
        id: String? = nil,
        zIndex: Int? = nil,
        extra: Any? = nil,
        onClick: OnCircleEventHandler? = nil,
        onAdded: OnCircleAddedHandler? = nil
    )
}
```

## Constructor Parameters

- `center`
    - Type: `GeoPointProtocol`
    - Description: The geographic center of the circle.
- `radiusMeters`
    - Type: `Double`
    - Description: Radius in meters.
- `geodesic`
    - Type: `Bool`
    - Default: `true`
    - Description: If `true`, the circle follows the curvature of the Earth.
- `clickable`
    - Type: `Bool`
    - Default: `true`
    - Description: Whether tapping the circle fires `onClick`.
- `strokeColor`
    - Type: `UIColor`
    - Default: `.red`
    - Description: Color of the circle border.
- `strokeWidth`
    - Type: `Double`
    - Default: `1.0`
    - Description: Border width in points.
- `fillColor`
    - Type: `UIColor`
    - Default: `UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.5)` (semi-transparent white)
    - Description: Fill color of the circle interior.
- `id`
    - Type: `String?`
    - Default: `nil`
    - Description: Stable identifier. Auto-generated from content hash if `nil`.
- `zIndex`
    - Type: `Int?`
    - Default: `nil`
    - Description: Draw order relative to other overlays.
- `extra`
    - Type: `Any?`
    - Default: `nil`
    - Description: Arbitrary user data attached to the circle.
- `onClick`
    - Type: `OnCircleEventHandler?`
    - Default: `nil`
    - Description: Called when the circle is tapped. Receives a `CircleEvent`.
- `onAdded`
    - Type: `OnCircleAddedHandler?`
    - Default: `nil`
    - Description: Called with this state each time the circle goes from not being on the map to being on it: for a natively drawn circle, right after the provider has created its native object. It does not wait for tile images to load or for pixels to show. Not called for in-place changes, on clear, or when the map goes away; called again when the circle is removed and later added again. Always on the main actor. Not part of the id, fingerprint, `==` or hash; replacing it does not redraw anything.

## Methods

### `copy(...)`

Returns a new `CircleState` with any of the given values overriding the current ones.

```swift
public func copy(
    center: GeoPointProtocol? = nil,
    radiusMeters: Double? = nil,
    geodesic: Bool? = nil,
    clickable: Bool? = nil,
    strokeColor: UIColor? = nil,
    strokeWidth: Double? = nil,
    fillColor: UIColor? = nil,
    id: String? = nil,
    zIndex: Int? = nil,
    extra: Any? = nil,
    onClick: OnCircleEventHandler? = nil
) -> CircleState
```

## Example

```swift
let circle = CircleState(
    center: GeoPoint(latitude: 35.6812, longitude: 139.7671),
    radiusMeters: 500.0,
    strokeColor: UIColor.red,
    fillColor: UIColor.red.withAlphaComponent(0.2),
    strokeWidth: 2.0
)
```
