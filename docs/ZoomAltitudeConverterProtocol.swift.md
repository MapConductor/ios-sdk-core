# ZoomAltitudeConverterProtocol

A protocol for converting between map zoom levels and camera altitude. Each map SDK integration
provides a concrete implementation (e.g. `GoogleMapsZoomAltitudeConverter`,
`MapboxZoomAltitudeConverter`).

The standard altitude formula is:
- `altitude = (zoom0Altitude × cos(latitude)) / 2^zoom × cos(tilt)`

## Signature

```swift
public protocol ZoomAltitudeConverterProtocol {
    var zoom0Altitude: Double { get }

    func zoomLevelToAltitude(zoomLevel: Double, latitude: Double, tilt: Double) -> Double
    func altitudeToZoomLevel(altitude: Double, latitude: Double, tilt: Double) -> Double
}
```

## Properties

- `zoom0Altitude`
    - Type: `Double`
    - Description: The reference altitude in meters at zoom level 0 near the equator.

## Methods

### `zoomLevelToAltitude(zoomLevel:latitude:tilt:)`

```swift
func zoomLevelToAltitude(zoomLevel: Double, latitude: Double, tilt: Double) -> Double
```

### `altitudeToZoomLevel(altitude:latitude:tilt:)`

```swift
func altitudeToZoomLevel(altitude: Double, latitude: Double, tilt: Double) -> Double
```

## Static Extension Defaults

The protocol provides the following read-only computed properties via a public extension:

- `defaultZoom0Altitude: Double` — `171_319_879.0`
- `zoomFactor: Double` — `2.0`
- `minZoomLevel: Double` — `0.0`
- `maxZoomLevel: Double` — `22.0`
- `minAltitude: Double` — `100.0`
- `maxAltitude: Double` — `50_000_000.0`
- `minCosLat: Double` — `0.01`
- `minCosTilt: Double` — `0.05`
- `webMercatorInitialMpp256: Double` — `156_543.033_928`
