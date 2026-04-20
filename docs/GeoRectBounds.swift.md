# GeoRectBounds

A mutable bounding rectangle defined by optional southwest and northeast `GeoPoint` corners. Used
for computing visible regions, clustering bounds, and overlay culling.

## Signature

```swift
public final class GeoRectBounds: Equatable, Hashable {
    public var southWest: GeoPoint?
    public var northEast: GeoPoint?

    public init(
        southWest: GeoPoint? = nil,
        northEast: GeoPoint? = nil
    )
}
```

## Properties

- `southWest` — Type: `GeoPoint?` — The southwest corner of the bounds. `nil` when empty.
- `northEast` — Type: `GeoPoint?` — The northeast corner of the bounds. `nil` when empty.
- `isEmpty` — Type: `Bool` — `true` when either corner is `nil`.
- `center` — Type: `GeoPoint?` — The geographic center of the bounds. `nil` when empty.

## Methods

### `extend(point:)`

Expands the bounds to include the given point.

```swift
public func extend(point: GeoPointProtocol)
```

### `contains(point:)`

Returns `true` if the given point lies within or on the boundary of this rect.

```swift
public func contains(point: GeoPointProtocol) -> Bool
```

### `union(other:)`

Returns a new `GeoRectBounds` that encompasses both this rect and `other`.

```swift
public func union(other: GeoRectBounds) -> GeoRectBounds
```

### `intersects(other:)`

Returns `true` if this rect overlaps with `other`.

```swift
public func intersects(other: GeoRectBounds) -> Bool
```

### `toSpan()`

Returns the latitude and longitude span of the bounds as a `GeoPoint`
(latitude = span in degrees, longitude = span in degrees). Returns `nil` when empty.

```swift
public func toSpan() -> GeoPoint?
```

### `expandedByDegrees(latPad:lonPad:)`

Returns a new `GeoRectBounds` expanded by the given padding in degrees on each side.

```swift
public func expandedByDegrees(latPad: Double, lonPad: Double) -> GeoRectBounds
```

## Example

```swift
let bounds = GeoRectBounds(
    southWest: GeoPoint(latitude: 35.0, longitude: 139.0),
    northEast: GeoPoint(latitude: 36.0, longitude: 140.0)
)
bounds.extend(point: GeoPoint(latitude: 36.5, longitude: 140.5))
print(bounds.contains(point: GeoPoint(latitude: 35.5, longitude: 139.5))) // true

let padded = bounds.expandedByDegrees(latPad: 0.1, lonPad: 0.1)
```
