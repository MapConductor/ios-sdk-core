# PolylineState

State object controlling a single polyline overlay on the map. Conforms to `ObservableObject`,
`Identifiable`, `Equatable`, and `Hashable`.

## Signature

```swift
public final class PolylineState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String

    @Published public var strokeColor: UIColor
    @Published public var strokeWidth: Double
    @Published public var geodesic: Bool
    @Published public var points: [GeoPointProtocol]
    @Published public var extra: Any?
    @Published public var onClick: OnPolylineEventHandler?
    public var onAdded: OnPolylineAddedHandler?

    public init(
        points: [GeoPointProtocol],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        geodesic: Bool = false,
        extra: Any? = nil,
        onClick: OnPolylineEventHandler? = nil,
        onAdded: OnPolylineAddedHandler? = nil
    )
}
```

## Constructor Parameters

- `points`
    - Type: `[GeoPointProtocol]`
    - Description: Ordered list of geographic coordinates forming the line.
- `id`
    - Type: `String?`
    - Default: `nil`
    - Description: Stable identifier. Auto-generated from content hash if `nil`.
- `strokeColor`
    - Type: `UIColor`
    - Default: `.black`
    - Description: Color of the polyline.
- `strokeWidth`
    - Type: `Double`
    - Default: `1.0`
    - Description: Line width in points.
- `geodesic`
    - Type: `Bool`
    - Default: `false`
    - Description: If `true`, segments follow the curvature of the Earth.
- `extra`
    - Type: `Any?`
    - Default: `nil`
    - Description: Arbitrary user data attached to the polyline.
- `onClick`
    - Type: `OnPolylineEventHandler?`
    - Default: `nil`
    - Description: Called when the polyline is tapped. Receives a `PolylineEvent`.
- `onAdded`
    - Type: `OnPolylineAddedHandler?`
    - Default: `nil`
    - Description: Called with this state each time the polyline goes from not being on the map to being on it: for a natively drawn polyline, right after the provider has created its native object. It does not wait for tile images to load or for pixels to show. Not called for in-place changes, on clear, or when the map goes away; called again when the polyline is removed and later added again. Always on the main actor. Not part of the id, fingerprint, `==` or hash; replacing it does not redraw anything.

## Methods

### `copy(...)`

Returns a new `PolylineState` with any of the given values overriding the current ones.

```swift
public func copy(
    points: [GeoPointProtocol]? = nil,
    id: String? = nil,
    strokeColor: UIColor? = nil,
    strokeWidth: Double? = nil,
    geodesic: Bool? = nil,
    extra: Any? = nil,
    onClick: OnPolylineEventHandler? = nil
) -> PolylineState
```

## Example

```swift
let route = PolylineState(
    points: [
        GeoPoint(latitude: 35.6812, longitude: 139.7671),
        GeoPoint(latitude: 35.7100, longitude: 139.8107)
    ],
    strokeColor: UIColor.red,
    strokeWidth: 4.0,
    geodesic: true
)
```
