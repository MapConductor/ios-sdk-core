# PolygonState

State object controlling a single polygon overlay on the map. Conforms to `ObservableObject`,
`Identifiable`, `Equatable`, and `Hashable`.

## Signature

```swift
public final class PolygonState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String

    @Published public var strokeColor: UIColor
    @Published public var strokeWidth: Double
    @Published public var fillColor: UIColor
    @Published public var geodesic: Bool
    @Published public var zIndex: Int
    @Published public var points: [GeoPointProtocol]
    @Published public var holes: [[GeoPointProtocol]]
    @Published public var extra: Any?
    @Published public var onClick: OnPolygonEventHandler?

    public init(
        points: [GeoPointProtocol],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 2.0,
        fillColor: UIColor = .clear,
        geodesic: Bool = false,
        zIndex: Int = 0,
        holes: [[GeoPointProtocol]] = [],
        extra: Any? = nil,
        onClick: OnPolygonEventHandler? = nil
    )
}
```

## Constructor Parameters

- `points`
    - Type: `[GeoPointProtocol]`
    - Description: Ordered outer ring vertices. The ring is closed automatically.
- `id`
    - Type: `String?`
    - Default: `nil`
    - Description: Stable identifier. Auto-generated from content hash if `nil`.
- `strokeColor`
    - Type: `UIColor`
    - Default: `.black`
    - Description: Color of the polygon border.
- `strokeWidth`
    - Type: `Double`
    - Default: `2.0`
    - Description: Border width in points.
- `fillColor`
    - Type: `UIColor`
    - Default: `.clear`
    - Description: Fill color of the polygon interior.
- `geodesic`
    - Type: `Bool`
    - Default: `false`
    - Description: If `true`, edges follow the curvature of the Earth.
- `zIndex`
    - Type: `Int`
    - Default: `0`
    - Description: Draw order relative to other overlays.
- `holes`
    - Type: `[[GeoPointProtocol]]`
    - Default: `[]`
    - Description: List of inner rings that punch holes in the polygon fill.
- `extra`
    - Type: `Any?`
    - Default: `nil`
    - Description: Arbitrary user data attached to the polygon.
- `onClick`
    - Type: `OnPolygonEventHandler?`
    - Default: `nil`
    - Description: Called when the polygon is tapped. Receives a `PolygonEvent`.

## Methods

### `copy(...)`

Returns a new `PolygonState` with any of the given values overriding the current ones.

```swift
public func copy(
    points: [GeoPointProtocol]? = nil,
    id: String? = nil,
    strokeColor: UIColor? = nil,
    strokeWidth: Double? = nil,
    fillColor: UIColor? = nil,
    geodesic: Bool? = nil,
    zIndex: Int? = nil,
    holes: [[GeoPointProtocol]]? = nil,
    extra: Any? = nil,
    onClick: OnPolygonEventHandler? = nil
) -> PolygonState
```

## Example

```swift
let area = PolygonState(
    points: [
        GeoPoint(latitude: 35.70, longitude: 139.75),
        GeoPoint(latitude: 35.70, longitude: 139.80),
        GeoPoint(latitude: 35.65, longitude: 139.80),
        GeoPoint(latitude: 35.65, longitude: 139.75)
    ],
    fillColor: UIColor.green.withAlphaComponent(0.3),
    strokeColor: UIColor.green
)
```
