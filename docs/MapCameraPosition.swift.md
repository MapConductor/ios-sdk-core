# MapCameraPosition

Camera position types used across all map SDK integrations.

---

# VisibleRegion

A struct representing the bounding box and four corners of the currently visible map area.

## Signature

```swift
public struct VisibleRegion: Equatable, Hashable {
    public let bounds: GeoRectBounds
    public let nearLeft: GeoPoint?
    public let nearRight: GeoPoint?
    public let farLeft: GeoPoint?
    public let farRight: GeoPoint?

    public init(
        bounds: GeoRectBounds,
        nearLeft: GeoPoint? = nil,
        nearRight: GeoPoint? = nil,
        farLeft: GeoPoint? = nil,
        farRight: GeoPoint? = nil
    )
}
```

## Properties

- `bounds` — Type: `GeoRectBounds` — Bounding box encompassing the visible region.
- `nearLeft` — Type: `GeoPoint?` — Bottom-left corner of the visible region.
- `nearRight` — Type: `GeoPoint?` — Bottom-right corner of the visible region.
- `farLeft` — Type: `GeoPoint?` — Top-left corner of the visible region.
- `farRight` — Type: `GeoPoint?` — Top-right corner of the visible region.

---

# MapCameraPositionProtocol

A protocol that camera position types must implement.

## Signature

```swift
public protocol MapCameraPositionProtocol {
    var position: GeoPointProtocol { get }
    var zoom: Double { get }
    var bearing: Double { get }
    var tilt: Double { get }
    var paddings: MapPaddingsProtocol? { get }
    var visibleRegion: VisibleRegion? { get }
}
```

---

# MapCameraPosition

A concrete camera position value. Conforms to `MapCameraPositionProtocol`.

## Signature

```swift
public final class MapCameraPosition: MapCameraPositionProtocol {
    public var position: GeoPointProtocol { get }
    public let zoom: Double
    public let bearing: Double
    public let tilt: Double
    public let paddings: MapPaddingsProtocol?
    public let visibleRegion: VisibleRegion?

    public init(
        position: GeoPointProtocol,
        zoom: Double = 0.0,
        bearing: Double = 0.0,
        tilt: Double = 0.0,
        paddings: MapPaddingsProtocol? = MapPaddings.Zeros,
        visibleRegion: VisibleRegion? = nil
    )
}
```

## Constructor Parameters

- `position`
    - Type: `GeoPointProtocol`
    - Description: The geographic center of the camera.
- `zoom`
    - Type: `Double`
    - Default: `0.0`
    - Description: Zoom level. Higher values zoom in closer.
- `bearing`
    - Type: `Double`
    - Default: `0.0`
    - Description: Camera bearing in degrees clockwise from north.
- `tilt`
    - Type: `Double`
    - Default: `0.0`
    - Description: Camera tilt angle in degrees from vertical.
- `paddings`
    - Type: `MapPaddingsProtocol?`
    - Default: `MapPaddings.Zeros`
    - Description: Insets applied to the visible map area.
- `visibleRegion`
    - Type: `VisibleRegion?`
    - Default: `nil`
    - Description: The four corners of the visible map area.

## Static Properties

- `.Default` — A default camera position centered at `(0, 0)` with zoom `0.0`.

## Methods

### `copy(...)`

Returns a new `MapCameraPosition` with any of the given values overriding the current ones.

```swift
public func copy(
    position: GeoPointProtocol? = nil,
    zoom: Double? = nil,
    bearing: Double? = nil,
    tilt: Double? = nil,
    paddings: MapPaddingsProtocol? = nil,
    visibleRegion: VisibleRegion? = nil
) -> MapCameraPosition
```

## Example

```swift
let camera = MapCameraPosition(
    position: GeoPoint(latitude: 35.6812, longitude: 139.7671),
    zoom: 13.0,
    bearing: 45.0,
    tilt: 30.0
)

let zoomed = camera.copy(zoom: 16.0)
```
