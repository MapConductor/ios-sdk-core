import Foundation

public struct VisibleRegion: Equatable, Hashable {
    public let bounds: GeoRectBounds
    public let nearLeft: GeoPoint?
    public let nearRight: GeoPoint?
    public let farLeft: GeoPoint?
    public let farRight: GeoPoint?

    public init(
        bounds: GeoRectBounds,
        nearLeft: GeoPoint? = nil,
        nearRight: GeoPoint? = nil,
        farLeft: GeoPoint? = nil,
        farRight: GeoPoint? = nil
    ) {
        self.bounds = bounds
        self.nearLeft = nearLeft
        self.nearRight = nearRight
        self.farLeft = farLeft
        self.farRight = farRight
    }

    public static func == (lhs: VisibleRegion, rhs: VisibleRegion) -> Bool {
        lhs.bounds == rhs.bounds &&
            geoPointEquals(lhs.nearLeft, rhs.nearLeft) &&
            geoPointEquals(lhs.nearRight, rhs.nearRight) &&
            geoPointEquals(lhs.farLeft, rhs.farLeft) &&
            geoPointEquals(lhs.farRight, rhs.farRight)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bounds)
        hasher.combine(geoPointHash(nearLeft))
        hasher.combine(geoPointHash(nearRight))
        hasher.combine(geoPointHash(farLeft))
        hasher.combine(geoPointHash(farRight))
    }
}

public protocol MapCameraPositionProtocol {
    var position: GeoPointProtocol { get }
    var zoom: Double { get }
    /// 地図の回転角（度、0 が北）。
    ///
    /// 値を増やすと地図は**時計回り（右）**に回る。90 なら地図が右へ 90 度回り、
    /// 画面の上には西が来る。多くのネイティブ SDK の「カメラの向き（heading）」とは
    /// 符号が逆なので、変換は ``CameraBearing`` を通すこと。
    var bearing: Double { get }
    var tilt: Double { get }
    var paddings: MapPaddingsProtocol? { get }
    var visibleRegion: VisibleRegion? { get }
}

public final class MapCameraPosition: MapCameraPositionProtocol {
    public var position: GeoPointProtocol { positionValue }
    /// 指定されなかったときは 0。指定されたかどうかは ``isZoomSpecified`` で区別する。
    public let zoom: Double
    /// 指定されなかったときは 0。指定されたかどうかは ``isBearingSpecified`` で区別する。
    public let bearing: Double
    /// 指定されなかったときは 0。指定されたかどうかは ``isTiltSpecified`` で区別する。
    public let tilt: Double
    public let paddings: MapPaddingsProtocol?
    public let visibleRegion: VisibleRegion?
    private let positionValue: GeoPoint

    /// `zoom` / `bearing` / `tilt` が明示されたか。
    ///
    /// 明示された 0（zoom 0 = 世界全体、真北、真上から）と未指定を区別するために持つ。
    /// ``MapViewState/moveCameraTo(cameraPosition:durationMillis:)`` は未指定の
    /// プロパティだけを現在のカメラから引き継ぐ（``resolved(onto:)``）。
    public let isZoomSpecified: Bool
    public let isBearingSpecified: Bool
    public let isTiltSpecified: Bool

    public init(
        position: GeoPointProtocol,
        zoom: Double? = nil,
        bearing: Double? = nil,
        tilt: Double? = nil,
        paddings: MapPaddingsProtocol? = MapPaddings.Zeros,
        visibleRegion: VisibleRegion? = nil
    ) {
        self.positionValue = GeoPoint.from(position: position)
        self.zoom = zoom ?? 0.0
        self.bearing = bearing ?? 0.0
        self.tilt = tilt ?? 0.0
        self.isZoomSpecified = zoom != nil
        self.isBearingSpecified = bearing != nil
        self.isTiltSpecified = tilt != nil
        self.paddings = paddings
        self.visibleRegion = visibleRegion
    }

    /// 未指定の `zoom` / `bearing` / `tilt` を `current` の値で埋めたカメラを返す。
    ///
    /// 明示されたプロパティは、0 であってもそのまま使う。
    public func resolved(onto current: MapCameraPositionProtocol) -> MapCameraPosition {
        if isZoomSpecified && isBearingSpecified && isTiltSpecified {
            return self
        }
        return MapCameraPosition(
            position: positionValue,
            zoom: isZoomSpecified ? zoom : current.zoom,
            bearing: isBearingSpecified ? bearing : current.bearing,
            tilt: isTiltSpecified ? tilt : current.tilt,
            paddings: paddings,
            visibleRegion: visibleRegion
        )
    }

    public func equals(other: MapCameraPositionProtocol) -> Bool {
        positionValue == GeoPoint.from(position: other.position) &&
            zoomEquals(other) &&
            bearingEquals(other) &&
            tiltEquals(other)
    }

    public func copy(
        position: GeoPointProtocol? = nil,
        zoom: Double? = nil,
        bearing: Double? = nil,
        tilt: Double? = nil,
        paddings: MapPaddingsProtocol? = nil,
        visibleRegion: VisibleRegion? = nil
    ) -> MapCameraPosition {
        // 渡されなかったプロパティは、未指定だったならコピー後も未指定のまま。
        MapCameraPosition(
            position: position ?? self.positionValue,
            zoom: zoom ?? (isZoomSpecified ? self.zoom : nil),
            bearing: bearing ?? (isBearingSpecified ? self.bearing : nil),
            tilt: tilt ?? (isTiltSpecified ? self.tilt : nil),
            paddings: paddings ?? self.paddings,
            visibleRegion: visibleRegion ?? self.visibleRegion
        )
    }

    private func zoomEquals(_ other: MapCameraPositionProtocol) -> Bool {
        let tolerance = 1e-2
        return abs(zoom - other.zoom) < tolerance
    }

    private func bearingEquals(_ other: MapCameraPositionProtocol) -> Bool {
        let tolerance = 1e-2
        return abs(bearing - other.bearing) < tolerance
    }

    private func tiltEquals(_ other: MapCameraPositionProtocol) -> Bool {
        let tolerance = 1e-2
        return abs(tilt - other.tilt) < tolerance
    }

    public func hashCode() -> Int {
        var result = positionValue.hashValue
        result = 31 * result + zoom.hashValue
        result = 31 * result + bearing.hashValue
        result = 31 * result + tilt.hashValue
        let paddingHash = paddings.map { MapPaddings.from(paddings: $0).hashCode() } ?? 0
        result = 31 * result + paddingHash
        result = 31 * result + (visibleRegion?.hashValue ?? 0)
        return result
    }

    public static let Default = MapCameraPosition(
        position: GeoPoint(latitude: 0.0, longitude: 0.0, altitude: 0.0),
        zoom: 0.0,
        bearing: 0.0,
        tilt: 0.0
    )
}

private func geoPointEquals(_ lhs: GeoPoint?, _ rhs: GeoPoint?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case (let left?, let right?):
        return left == right
    default:
        return false
    }
}

private func geoPointHash(_ point: GeoPoint?) -> GeoPoint? {
    point
}
