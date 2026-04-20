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

    public init(
        points: [GeoPointProtocol],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        geodesic: Bool = false,
        extra: Any? = nil,
        onClick: OnPolylineEventHandler? = nil
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
