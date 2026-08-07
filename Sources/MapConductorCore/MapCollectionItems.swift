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
        content.markers.append(contentsOf: states.map { Marker(state: $0) })
    }
}

public struct Circles: MapOverlayItemProtocol {
    private let states: [CircleState]

    public init(_ states: [CircleState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.circles.append(contentsOf: states.map { Circle(state: $0) })
    }
}

public struct Polylines: MapOverlayItemProtocol {
    private let states: [PolylineState]

    public init(_ states: [PolylineState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.polylines.append(contentsOf: states.map { Polyline(state: $0) })
    }
}

public struct Polygons: MapOverlayItemProtocol {
    private let states: [PolygonState]

    public init(_ states: [PolygonState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.polygons.append(contentsOf: states.map { Polygon(state: $0) })
    }
}

public struct GroundImages: MapOverlayItemProtocol {
    private let states: [GroundImageState]

    public init(_ states: [GroundImageState]) {
        self.states = states
    }

    public func append(to content: inout MapViewContent) {
        content.groundImages.append(contentsOf: states.map { GroundImage(state: $0) })
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
