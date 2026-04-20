# MapConductor Core

## Description

MapConductor Core is the foundation library of the MapConductor iOS SDK.
It provides the shared data types, SwiftUI overlay components, and abstraction interfaces used across all map implementations (Google Maps, MapLibre, MapKit, Mapbox, ArcGIS, etc.).

App developers use types from this module (e.g. `GeoPoint`, `MarkerState`, `DefaultMarkerIcon`) directly, regardless of which map implementation they choose.
The actual map view (`GoogleMapView`, `MapLibreMapView`, etc.) is provided by each implementation module.

## Setup

https://docs-ios.mapconductor.com/setup/

## Data Types

### GeoPoint

```swift
// From latitude / longitude
let point = GeoPoint(latitude: 35.6762, longitude: 139.6503)

// Convenience constructors
let point = GeoPoint.fromLatLong(35.6762, 139.6503)
let point = GeoPoint.fromLongLat(139.6503, 35.6762)
```

### GeoRectBounds

```swift
let bounds = GeoRectBounds(
    southWest: GeoPoint(latitude: 35.0, longitude: 139.0),
    northEast: GeoPoint(latitude: 36.0, longitude: 140.0)
)
```

### MapCameraPosition

```swift
let cameraPosition = MapCameraPosition(
    position: GeoPoint(latitude: 35.6762, longitude: 139.6503),
    zoom: 14,
    bearing: 45,
    tilt: 30
)
```

------------------------------------------------------------------------

## Marker Icons

### DefaultMarkerIcon (color fill)

```swift
let icon = DefaultMarkerIcon(
    fillColor: UIColor.red,
    strokeColor: UIColor.white,
    label: "Tokyo",
    labelTextColor: UIColor.white
)
```

### ImageDefaultIcon (image fill)

```swift
let icon = ImageDefaultIcon(
    backgroundImage: uiImage,
    label: "Tokyo"
)
```

------------------------------------------------------------------------

## Overlay Components

All overlay components are available inside any `XxxMapView` content block.

### Marker

```swift
let markerState = MarkerState(
    position: GeoPoint(latitude: 35.6762, longitude: 139.6503),
    icon: DefaultMarkerIcon(label: "Tokyo", fillColor: UIColor.blue),
    onClick: { state in
        state.animate(.bounce)
    }
)

XxxMapView(state: mapState) {
    Marker(state: markerState)
}
```

### MarkerAnimation

```swift
// Available animations
MarkerAnimation.bounce
MarkerAnimation.drop

markerState.animate(.bounce)
```

### InfoBubble

```swift
@State private var selectedMarker: MarkerState? = nil

XxxMapView(state: mapState) {
    Marker(state: markerState)
    if let selected = selectedMarker {
        InfoBubble(marker: selected) {
            Text("Hello, world!")
        }
    }
}
```

### Circle

```swift
Circle(
    center: GeoPoint(latitude: 35.6762, longitude: 139.6503),
    radiusMeters: 500,
    fillColor: UIColor.blue.withAlphaComponent(0.3),
    strokeColor: UIColor.blue
)
```

### Polyline

```swift
Polyline(
    points: [
        GeoPoint(latitude: 35.6762, longitude: 139.6503),
        GeoPoint(latitude: 35.6895, longitude: 139.6917),
    ],
    strokeColor: UIColor.red,
    strokeWidth: 4
)
```

### Polygon

```swift
Polygon(
    points: points,
    fillColor: UIColor.green.withAlphaComponent(0.4),
    strokeColor: UIColor.green
)
```

### GroundImage

```swift
GroundImage(
    bounds: GeoRectBounds(
        southWest: GeoPoint(latitude: 35.0, longitude: 139.0),
        northEast: GeoPoint(latitude: 36.0, longitude: 140.0)
    ),
    image: uiImage,
    opacity: 0.7
)
```

### RasterLayer

```swift
RasterLayer(
    source: RasterLayerSource.xyz("https://tile.openstreetmap.org/{z}/{x}/{y}.png")
)
```
