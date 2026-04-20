# GeoPoint

Geographic coordinate types used throughout the SDK.

---

# GeoPointProtocol

A protocol that any geographic coordinate type must implement.

## Signature

```swift
public protocol GeoPointProtocol {
    var latitude: Double { get }
    var longitude: Double { get }
    var altitude: Double? { get }

    func wrap() -> GeoPointProtocol
}
```

## Properties

- `latitude` — Type: `Double` — Latitude in degrees.
- `longitude` — Type: `Double` — Longitude in degrees.
- `altitude` — Type: `Double?` — Altitude in meters. Optional.

## Extension Methods (available on all `GeoPointProtocol` values)

### `normalize()`

Returns a copy with latitude clamped to `[-90, 90]` and longitude wrapped to `[-180, 180]`.

```swift
public func normalize() -> GeoPoint
```

### `isValid()`

Returns `true` if latitude is in `[-90, 90]` and longitude is in `[-180, 180]`.

```swift
public func isValid() -> Bool
```

---

# GeoPoint

A concrete geographic coordinate value. Conforms to `GeoPointProtocol`, `Equatable`, and `Hashable`.

## Signature

```swift
public struct GeoPoint: GeoPointProtocol, Equatable, Hashable {
    public let latitude: Double
    public let longitude: Double
    public var altitude: Double?  // computed; backed by a stored Double (default 0.0)

    public init(latitude: Double, longitude: Double, altitude: Double = 0.0)
}
```

## Constructor Parameters

- `latitude`
    - Type: `Double`
    - Description: Latitude in degrees.
- `longitude`
    - Type: `Double`
    - Description: Longitude in degrees.
- `altitude`
    - Type: `Double`
    - Default: `0.0`
    - Description: Altitude in meters.

## Factory Methods

### `fromLatLong(latitude:longitude:)`

```swift
public static func fromLatLong(
    latitude: Double,
    longitude: Double
) -> GeoPoint
```

### `fromLongLat(longitude:latitude:)`

```swift
public static func fromLongLat(
    longitude: Double,
    latitude: Double
) -> GeoPoint
```

### `from(position:)`

Creates a `GeoPoint` from any `GeoPointProtocol` value.

```swift
public static func from(position: GeoPointProtocol) -> GeoPoint
```

## Instance Methods

### `wrap()`

Returns a copy with latitude wrapped to `[-90, 90]` and longitude wrapped to `[-180, 180]`.

```swift
public func wrap() -> GeoPointProtocol
```

### `toUrlValue(precision:)`

Returns a URL-safe string representation `"lat,lng"`.

```swift
public func toUrlValue(precision: Int = 6) -> String
```

## Example

```swift
let tokyo = GeoPoint(latitude: 35.6812, longitude: 139.7671)
let normalized = tokyo.normalize()
print(normalized.isValid()) // true

let point = GeoPoint.fromLongLat(longitude: 139.7671, latitude: 35.6812)
```
