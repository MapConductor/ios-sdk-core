# MapDesignTypeProtocol

A protocol that all map design (tile style) types must implement. Each map SDK integration
provides a concrete conforming type (e.g. `GoogleMapDesign`, `MapboxMapDesign`).

## Signature

```swift
public protocol MapDesignTypeProtocol {
    associatedtype Identifier
    var id: Identifier { get }
    func getValue() -> Identifier
}
```

## Associated Types

- `Identifier` — The underlying type used to identify the map style
  (e.g. `MKMapType` for MapKit, `String` for Mapbox/MapLibre).

## Properties

- `id` — Type: `Identifier` — The raw style identifier.

## Methods

### `getValue()`

Returns the raw `Identifier` value for this design type.

```swift
func getValue() -> Identifier
```
