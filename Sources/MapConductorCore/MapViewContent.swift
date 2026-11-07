import SwiftUI
import UIKit

public typealias OnMapLoadedHandler<State: MapViewStateProtocol> = (State) -> Void
public typealias OnMapEventHandler = (GeoPoint) -> Void
public typealias OnCameraMoveHandler = (MapCameraPosition) -> Void

public protocol MapOverlayItemProtocol {
    func append(to content: inout MapViewContent)
}

/// A marker protocol for map overlay items that are also SwiftUI Views.
/// These overlays need to be rendered in the view hierarchy in addition to
/// being added to the map content.
public protocol ViewBasedMapOverlay: MapOverlayItemProtocol, View {
}

public struct MapViewContent {
    public var markers: [Marker] = []
    public var infoBubbles: [InfoBubble] = []
    public var polylines: [Polyline] = []
    public var polygons: [Polygon] = []
    public var circles: [Circle] = []
    public var groundImages: [GroundImage] = []
    public var rasterLayers: [RasterLayer] = []
    public var views: [AnyView] = []
    /// Marker tiling for this content. Reads ``MarkerTilingOptions/Default`` until something sets it.
    ///
    /// Whether it was set is tracked separately from its value, so that merging the pieces a
    /// ``MapViewContentBuilder`` closure produces keeps an explicit choice — including
    /// ``MarkerTilingOptions/Disabled`` — while pieces that never touched it leave it alone.
    public var markerTilingOptions: MarkerTilingOptions {
        get { explicitMarkerTilingOptions ?? .Default }
        set { explicitMarkerTilingOptions = newValue }
    }
    /// `nil` until ``markerTilingOptions`` is assigned.
    ///
    /// `merge` used to carry the option over only when it was enabled, because a fresh
    /// content's `.Default` and a deliberate `.Disabled` could not be told apart otherwise.
    /// A single-expression builder closure always goes through `buildBlock`, which merges
    /// into a fresh content, so `.Disabled` was silently replaced by the default (tiling on).
    var explicitMarkerTilingOptions: MarkerTilingOptions?
    /// Handlers that manage a subset of polygons imperatively (e.g. cluster hull polygons).
    /// Map view coordinators call ``PolygonSyncHandler/bindPolygonSync(_:)`` on each handler
    /// to provide a direct polygon sync function, ensuring those polygons are committed before
    /// marker animations start rather than through SwiftUI's deferred recomposition path.
    public var polygonSyncHandlers: [any PolygonSyncHandler] = []

    public init() {}

    mutating func append(_ item: MapOverlayItemProtocol) {
        item.append(to: &self)
    }

    mutating func merge(_ other: MapViewContent) {
        markers.append(contentsOf: other.markers)
        infoBubbles.append(contentsOf: other.infoBubbles)
        polylines.append(contentsOf: other.polylines)
        polygons.append(contentsOf: other.polygons)
        circles.append(contentsOf: other.circles)
        groundImages.append(contentsOf: other.groundImages)
        rasterLayers.append(contentsOf: other.rasterLayers)
        views.append(contentsOf: other.views)
        polygonSyncHandlers.append(contentsOf: other.polygonSyncHandlers)
        // An explicit setting wins over an unset one, whether it enables tiling or not;
        // between two explicit settings the later one wins.
        if let tiling = other.explicitMarkerTilingOptions {
            explicitMarkerTilingOptions = tiling
        }
    }
}

@resultBuilder
public enum MapViewContentBuilder {
    public static func buildBlock() -> MapViewContent {
        MapViewContent()
    }

    public static func buildBlock(_ components: MapViewContent...) -> MapViewContent {
        var content = MapViewContent()
        for component in components {
            content.merge(component)
        }
        return content
    }

    public static func buildOptional(_ component: MapViewContent?) -> MapViewContent {
        component ?? MapViewContent()
    }

    public static func buildEither(first component: MapViewContent) -> MapViewContent {
        component
    }

    public static func buildEither(second component: MapViewContent) -> MapViewContent {
        component
    }

    public static func buildArray(_ components: [MapViewContent]) -> MapViewContent {
        var content = MapViewContent()
        for component in components {
            content.merge(component)
        }
        return content
    }

    public static func buildExpression<T: ViewBasedMapOverlay>(_ expression: T) -> MapViewContent {
        var content = MapViewContent()
        content.append(expression)
        content.views.append(AnyView(expression))
        return content
    }

    @_disfavoredOverload
    public static func buildExpression(_ expression: MapOverlayItemProtocol) -> MapViewContent {
        var content = MapViewContent()
        content.append(expression)
        return content
    }

    public static func buildExpression(_ expression: MapViewContent) -> MapViewContent {
        expression
    }
}
