# MapViewContent

Overlay declaration types and the `@MapViewContentBuilder` result builder used to compose map
overlays declaratively inside `GoogleMapView`, `MapboxMapView`, and other map views.

---

# @MapViewContentBuilder

A SwiftUI-style result builder for composing map overlay items.

## Signature

```swift
@resultBuilder
public enum MapViewContentBuilder {
    public static func buildBlock(_ components: MapViewContent...) -> MapViewContent
    public static func buildOptional(_ component: MapViewContent?) -> MapViewContent
    public static func buildEither(first component: MapViewContent) -> MapViewContent
    public static func buildEither(second component: MapViewContent) -> MapViewContent
    public static func buildArray(_ components: [MapViewContent]) -> MapViewContent
}
```

---

# MapViewContent

A container holding typed collections of all overlay items.

## Signature

```swift
public struct MapViewContent {
    public var markers: [Marker]
    public var infoBubbles: [InfoBubble]
    public var polylines: [Polyline]
    public var polygons: [Polygon]
    public var circles: [Circle]
    public var groundImages: [GroundImage]
    public var rasterLayers: [RasterLayer]

    public init()
}
```

---

# Marker

Declares a single marker overlay on the map.

## Signature

```swift
public struct Marker: MapOverlayItemProtocol, Identifiable {
    public init(state: MarkerState)

    public init(
        position: GeoPoint,
        id: String? = nil,
        extra: Any? = nil,
        icon: (any MarkerIconProtocol)? = nil,
        animation: MarkerAnimation? = nil,
        clickable: Bool = true,
        draggable: Bool = false,
        onClick: OnMarkerEventHandler? = nil,
        onDragStart: OnMarkerEventHandler? = nil,
        onDrag: OnMarkerEventHandler? = nil,
        onDragEnd: OnMarkerEventHandler? = nil,
        onAnimateStart: OnMarkerEventHandler? = nil,
        onAnimateEnd: OnMarkerEventHandler? = nil
    )
}
```

---

# InfoBubble

Declares an info bubble (callout) overlay associated with a marker.

## Signature

```swift
public struct InfoBubble: MapOverlayItemProtocol, Identifiable {
    public init<Content: View>(
        marker: MarkerState,
        tailOffset: CGPoint = CGPoint(x: 0.5, y: 1.0),
        useDefaultStyle: Bool = true,
        style: InfoBubbleStyle = .Default,
        @ViewBuilder content: () -> Content
    )
}
```

---

# Polyline

Declares a polyline overlay on the map.

## Signature

```swift
public struct Polyline: MapOverlayItemProtocol, Identifiable {
    public init(state: PolylineState)

    public init(
        points: [GeoPointProtocol],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        geodesic: Bool = false,
        extra: Any? = nil,
        onClick: OnPolylineEventHandler? = nil
    )

    public init(
        bounds: GeoRectBounds,
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        geodesic: Bool = false,
        extra: Any? = nil,
        onClick: OnPolylineEventHandler? = nil
    )
}
```

---

# Polygon

Declares a polygon overlay on the map.

## Signature

```swift
public struct Polygon: MapOverlayItemProtocol, Identifiable {
    public init(state: PolygonState)

    public init(
        points: [GeoPointProtocol],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        fillColor: UIColor = .clear,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolygonEventHandler? = nil
    )

    public init(
        bounds: GeoRectBounds,
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        fillColor: UIColor = .clear,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolygonEventHandler? = nil
    )
}
```

---

# Circle

Declares a circle overlay on the map.

## Signature

```swift
public struct Circle: MapOverlayItemProtocol, Identifiable {
    public init(state: CircleState)

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
        onClick: OnCircleEventHandler? = nil
    )
}
```

---

# GroundImage

Declares a ground-anchored image overlay on the map.

## Signature

```swift
public struct GroundImage: MapOverlayItemProtocol, Identifiable {
    public init(state: GroundImageState)

    public init(
        bounds: GeoRectBounds,
        image: UIImage,
        opacity: Double = 1.0,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil
    )
}
```

---

# RasterLayer

Declares a raster tile layer overlay on the map.

## Signature

```swift
public struct RasterLayer: MapOverlayItemProtocol, Identifiable {
    public init(state: RasterLayerState)

    public init(
        source: RasterSource,
        opacity: Double = 1.0,
        visible: Bool = true,
        id: String? = nil,
        extra: Any? = nil
    )
}
```

---

# ForArray

Iterates over a collection and declares one overlay per element.

## Signature

```swift
public struct ForArray<Data: RandomAccessCollection>: MapOverlayItemProtocol {
    public init(
        _ data: Data,
        @MapViewContentBuilder content: (Data.Element) -> MapViewContent
    )
}
```

## Example

```swift
GoogleMapView(state: mapState) {
    ForArray(markerStates) { state in
        Marker(state: state)
    }
    Polyline(state: routeState)
    if showCircle {
        Circle(state: circleState)
    }
}
```
