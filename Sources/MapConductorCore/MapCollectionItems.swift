import SwiftUI
import UIKit

/// 複数要素をまとめて積む DSL 要素。
///
/// `ForArray` はコレクションから要素を作る。SwiftUI の `ForEach` と違い
/// ビューを作らないので、`MapViewContentBuilder` の中でそのまま使える。
public struct Markers: MapOverlayItemProtocol {
    private let states: [MarkerState]

    public init(_ states: [MarkerState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { Marker(state: $0) }
        if content.markers.isEmpty { content.markers = items } else { content.markers.append(contentsOf: items) }
    }
}

public struct Circles: MapOverlayItemProtocol {
    private let states: [CircleState]

    public init(_ states: [CircleState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { Circle(state: $0) }
        if content.circles.isEmpty { content.circles = items } else { content.circles.append(contentsOf: items) }
    }
}

public struct Polylines: MapOverlayItemProtocol {
    private let states: [PolylineState]

    public init(_ states: [PolylineState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { Polyline(state: $0) }
        if content.polylines.isEmpty { content.polylines = items } else { content.polylines.append(contentsOf: items) }
    }
}

public struct Polygons: MapOverlayItemProtocol {
    private let states: [PolygonState]

    public init(_ states: [PolygonState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { Polygon(state: $0) }
        if content.polygons.isEmpty { content.polygons = items } else { content.polygons.append(contentsOf: items) }
    }
}

public struct GroundImages: MapOverlayItemProtocol {
    private let states: [GroundImageState]

    public init(_ states: [GroundImageState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { GroundImage(state: $0) }
        if content.groundImages.isEmpty { content.groundImages = items } else { content.groundImages.append(contentsOf: items) }
    }
}

/// Analogous to SwiftUI's `ForEach`, but for `MapViewContentBuilder` closures.
///
/// Cannot be named `ForEach` because SwiftUI's `ForEach` would take precedence when
/// `Data.Element` conforms to `Identifiable`, causing a type mismatch error.
///
/// Usage:
/// ```swift
/// MapKitMapView(camera: $camera) {
///     ForArray(markers) { marker in
///         Marker(state: marker)
///     }
/// }
/// ```
public struct ForArray<Data: RandomAccessCollection>: MapOverlayItemProtocol {
    private let built: MapViewContent

    public init(
        _ data: Data,
        @MapViewContentBuilder content: (Data.Element) -> MapViewContent
    ) {
        var result = MapViewContent()
        for item in data {
            result.merge(content(item))
        }
        self.built = result
    }

    public func append(to content: inout MapViewContent) {
        content.merge(built)
    }
}
