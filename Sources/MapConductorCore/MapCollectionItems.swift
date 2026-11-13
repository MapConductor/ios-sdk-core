import SwiftUI
import UIKit

/// 複数要素をまとめて積む DSL 要素。
///
/// `ForArray` はコレクションから要素を作る。SwiftUI の `ForEach` と違い
/// ビューを作らないので、`MapViewContentBuilder` の中でそのまま使える。
public struct Markers: MapOverlayItemProtocol {
    private let states: [MarkerState]
    private let progress: AddProgressRequest?

    /// `onAddStart`, `onAddProgress` and `onAddEnd` say how far the states this
    /// list adds are with reaching the map; see ``AddProgressCallbacks``. Leave
    /// `fileID`, `line` and `column` to their defaults: they tell this
    /// collection apart from the others on the map.
    public init(
        _ states: [MarkerState],
        onAddStart: ((_ total: Int) -> Void)? = nil,
        onAddProgress: ((_ added: Int, _ total: Int) -> Void)? = nil,
        onAddEnd: ((_ total: Int) -> Void)? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.states = states
        let callbacks = AddProgressCallbacks(onAddStart: onAddStart, onAddProgress: onAddProgress, onAddEnd: onAddEnd)
        progress = callbacks.isEmpty
            ? nil
            : AddProgressRequest(kind: "markers", states: states, callbacks: callbacks, fileID: fileID, line: line, column: column)
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { Marker(state: $0) }
        if content.markers.isEmpty { content.markers = items } else { content.markers.append(contentsOf: items) }
        if let progress { content.addProgressRequests.append(progress) }
    }
}

public struct Circles: MapOverlayItemProtocol {
    private let states: [CircleState]
    private let progress: AddProgressRequest?

    /// `onAddStart`, `onAddProgress` and `onAddEnd` say how far the states this
    /// list adds are with reaching the map; see ``AddProgressCallbacks``. Leave
    /// `fileID`, `line` and `column` to their defaults: they tell this
    /// collection apart from the others on the map.
    public init(
        _ states: [CircleState],
        onAddStart: ((_ total: Int) -> Void)? = nil,
        onAddProgress: ((_ added: Int, _ total: Int) -> Void)? = nil,
        onAddEnd: ((_ total: Int) -> Void)? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.states = states
        let callbacks = AddProgressCallbacks(onAddStart: onAddStart, onAddProgress: onAddProgress, onAddEnd: onAddEnd)
        progress = callbacks.isEmpty
            ? nil
            : AddProgressRequest(kind: "circles", states: states, callbacks: callbacks, fileID: fileID, line: line, column: column)
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { Circle(state: $0) }
        if content.circles.isEmpty { content.circles = items } else { content.circles.append(contentsOf: items) }
        if let progress { content.addProgressRequests.append(progress) }
    }
}

/// Sets the map's ``MapViewContent/circleTilingOptions`` from inside a
/// `MapViewContentBuilder` closure, next to the circles it applies to:
///
/// ```swift
/// MapLibreMapView(state: state) {
///     CircleTiling(.Disabled)
///     Circles(trees)
/// }
/// ```
public struct CircleTiling: MapOverlayItemProtocol {
    private let options: CircleTilingOptions

    public init(_ options: CircleTilingOptions) {
        self.options = options
    }

    public func append(to content: inout MapViewContent) {
        content.circleTilingOptions = options
    }
}

public struct Polylines: MapOverlayItemProtocol {
    private let states: [PolylineState]
    private let progress: AddProgressRequest?

    /// `onAddStart`, `onAddProgress` and `onAddEnd` say how far the states this
    /// list adds are with reaching the map; see ``AddProgressCallbacks``. Leave
    /// `fileID`, `line` and `column` to their defaults: they tell this
    /// collection apart from the others on the map.
    public init(
        _ states: [PolylineState],
        onAddStart: ((_ total: Int) -> Void)? = nil,
        onAddProgress: ((_ added: Int, _ total: Int) -> Void)? = nil,
        onAddEnd: ((_ total: Int) -> Void)? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.states = states
        let callbacks = AddProgressCallbacks(onAddStart: onAddStart, onAddProgress: onAddProgress, onAddEnd: onAddEnd)
        progress = callbacks.isEmpty
            ? nil
            : AddProgressRequest(kind: "polylines", states: states, callbacks: callbacks, fileID: fileID, line: line, column: column)
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { Polyline(state: $0) }
        if content.polylines.isEmpty { content.polylines = items } else { content.polylines.append(contentsOf: items) }
        if let progress { content.addProgressRequests.append(progress) }
    }
}

/// Sets the map's ``MapViewContent/polylineTilingOptions`` from inside a
/// `MapViewContentBuilder` closure, next to the polylines it applies to:
///
/// ```swift
/// MapLibreMapView(state: state) {
///     PolylineTiling(.Disabled)
///     Polylines(roads)
/// }
/// ```
public struct PolylineTiling: MapOverlayItemProtocol {
    private let options: PolylineTilingOptions

    public init(_ options: PolylineTilingOptions) {
        self.options = options
    }

    public func append(to content: inout MapViewContent) {
        content.polylineTilingOptions = options
    }
}

public struct Polygons: MapOverlayItemProtocol {
    private let states: [PolygonState]
    private let progress: AddProgressRequest?

    /// `onAddStart`, `onAddProgress` and `onAddEnd` say how far the states this
    /// list adds are with reaching the map; see ``AddProgressCallbacks``. Leave
    /// `fileID`, `line` and `column` to their defaults: they tell this
    /// collection apart from the others on the map.
    public init(
        _ states: [PolygonState],
        onAddStart: ((_ total: Int) -> Void)? = nil,
        onAddProgress: ((_ added: Int, _ total: Int) -> Void)? = nil,
        onAddEnd: ((_ total: Int) -> Void)? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.states = states
        let callbacks = AddProgressCallbacks(onAddStart: onAddStart, onAddProgress: onAddProgress, onAddEnd: onAddEnd)
        progress = callbacks.isEmpty
            ? nil
            : AddProgressRequest(kind: "polygons", states: states, callbacks: callbacks, fileID: fileID, line: line, column: column)
    }

    public func append(to content: inout MapViewContent) {
        let items = states.map { Polygon(state: $0) }
        if content.polygons.isEmpty { content.polygons = items } else { content.polygons.append(contentsOf: items) }
        if let progress { content.addProgressRequests.append(progress) }
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
