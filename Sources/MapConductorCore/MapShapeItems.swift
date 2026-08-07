import SwiftUI
import UIKit

/// 線・面・円の DSL 要素。
public struct Polyline: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: PolylineState

    public init(state: PolylineState) {
        self.state = state
        self.id = state.id
    }

    public init(
        points: [GeoPointProtocol],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolylineEventHandler? = nil
    ) {
        let state = PolylineState(
            points: points,
            id: id,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            geodesic: geodesic,
            zIndex: zIndex,
            extra: extra,
            onClick: onClick
        )
        self.state = state
        self.id = state.id
    }

    public init(
        bounds: GeoRectBounds,
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolylineEventHandler? = nil
    ) {
        if let northEast = bounds.northEast, let southWest = bounds.southWest {
            let points: [GeoPointProtocol] = [
                northEast,
                GeoPoint(latitude: southWest.latitude, longitude: northEast.longitude),
                southWest,
                GeoPoint(latitude: northEast.latitude, longitude: southWest.longitude),
                northEast
            ]
            self.init(
                points: points,
                id: id,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                geodesic: geodesic,
                zIndex: zIndex,
                extra: extra,
                onClick: onClick
            )
        } else {
            self.init(
                points: [],
                id: id,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                geodesic: geodesic,
                zIndex: zIndex,
                extra: extra,
                onClick: onClick
            )
        }
    }

    public func append(to content: inout MapViewContent) {
        content.polylines.append(self)
    }
}

public struct Polygon: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: PolygonState

    public init(state: PolygonState) {
        // 穴のユニオンはここ（コンポーネント層）で一度だけ適用する。
        // android-sdk の `PolygonComponent.kt` が `LaunchedEffect(state)` の中で
        // `state.unionHolesInPlace()` を呼んでからコレクタへ渡すのと同じ位置づけ。
        // 以前は各プロバイダの `PolygonOverlayRenderer` が `state.unionHoles()` を
        // 呼んでおり、プロバイダごとに実装が重複していた。
        state.unionHolesInPlace()
        self.state = state
        self.id = state.id
    }

    /// 引数順は android-sdk の `Polygon` コンポーザブル
    /// （points, holes, id, strokeColor, strokeWidth, fillColor, geodesic, zIndex, extra, onClick）
    /// に合わせてある。Swift は宣言順に引数を並べる必要があるため、順序自体が API の一部になる。
    public init(
        points: [GeoPointProtocol],
        holes: [[GeoPointProtocol]] = [],
        id: String? = nil,
        strokeColor: UIColor = .black,
        strokeWidth: Double = 1.0,
        fillColor: UIColor = .clear,
        geodesic: Bool = false,
        zIndex: Int = 0,
        extra: Any? = nil,
        onClick: OnPolygonEventHandler? = nil
    ) {
        // すべての初期化子は init(state:) に集約する（穴のユニオンを 1 箇所で適用するため）。
        self.init(state: PolygonState(
            points: points,
            holes: holes,
            id: id,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            fillColor: fillColor,
            geodesic: geodesic,
            zIndex: zIndex,
            extra: extra,
            onClick: onClick
        ))
    }

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
    ) {
        if let northEast = bounds.northEast, let southWest = bounds.southWest {
            let points: [GeoPointProtocol] = [
                northEast,
                GeoPoint(latitude: southWest.latitude, longitude: northEast.longitude),
                southWest,
                GeoPoint(latitude: northEast.latitude, longitude: southWest.longitude),
                northEast
            ]
            self.init(
                points: points,
                id: id,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                fillColor: fillColor,
                geodesic: geodesic,
                zIndex: zIndex,
                extra: extra,
                onClick: onClick
            )
        } else {
            self.init(
                points: [],
                id: id,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                fillColor: fillColor,
                geodesic: geodesic,
                zIndex: zIndex,
                extra: extra,
                onClick: onClick
            )
        }
    }

    public func append(to content: inout MapViewContent) {
        content.polygons.append(self)
    }
}

public struct Circle: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: CircleState

    public init(state: CircleState) {
        self.state = state
        self.id = state.id
    }

    public init(
        center: GeoPointProtocol,
        radiusMeters: Double,
        geodesic: Bool = true,
        clickable: Bool = true,
        strokeColor: UIColor = .red,
        // android-sdk の `Circle` コンポーザブル（strokeWidth = 2.dp）と同じ既定値。
        // `CircleState` 側の既定は 3 者とも 1 で、コンポーネントだけ 2 という
        // 差はプラットフォーム共通（Polygon も同じ構図）。
        strokeWidth: Double = 2.0,
        fillColor: UIColor = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.5),
        id: String? = nil,
        zIndex: Int? = nil,
        extra: Any? = nil,
        onClick: OnCircleEventHandler? = nil
    ) {
        let state = CircleState(
            center: center,
            radiusMeters: radiusMeters,
            geodesic: geodesic,
            clickable: clickable,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            fillColor: fillColor,
            id: id,
            zIndex: zIndex,
            extra: extra,
            onClick: onClick
        )
        self.state = state
        self.id = state.id
    }

    public func append(to content: inout MapViewContent) {
        content.circles.append(self)
    }
}
