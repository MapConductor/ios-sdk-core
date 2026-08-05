import Foundation

/// カメラの可動範囲を制限する設定。
///
/// android-sdk の `com.mapconductor.core.map.CameraRestriction` の移植。
/// フィールド名・既定値・`isEmpty` / `None` の意味論を Android と一致させている。
///
/// - `bounds` : カメラ（ビューポート）がこの矩形の外へ出られないように制限する。`nil` で無制限。
/// - `minZoom` / `maxZoom` : ズームの下限・上限。値は統一ズーム（Google Maps 準拠, 0..22 相当）で
///   指定し、各プロバイダが自身のズーム体系へ変換して適用する。`nil` で無制限。
///
/// プロバイダ実装の方針は、そのプロバイダの SDK が何を提供しているかで決まる:
///
/// - **Google / Mapbox** : ネイティブの範囲制限 API（`cameraTargetBounds` /
///   `CameraBoundsOptions`）で、ジェスチャー・プログラム移動の両方をまとめて制限する。
/// - **MapLibre / MapTiler** : ズームはネイティブ（`minimumZoomLevel` /
///   `maximumZoomLevel`）。パン範囲はジェスチャーを `MLNMapViewDelegate` の
///   `mapView(_:shouldChangeFrom:to:reason:)` で拒否して境界で止め、同デリゲートが呼ばれない
///   プログラム移動だけ ``CameraRestrictionClamp`` で引き戻す。
/// - **HERE / ArcGIS / TomTom / MapKit / Longdo** : ネイティブに範囲制限の手段が無いため、
///   カメラ停止時に中心座標・ズームを矩形内へクランプして再適用する
///   （``CameraRestrictionClamp``）。android-sdk の HERE/ArcGIS/TomTom と同じ方式。
public struct CameraRestriction: Equatable {
    public let bounds: GeoRectBounds?
    public let minZoom: Double?
    public let maxZoom: Double?

    public init(
        bounds: GeoRectBounds? = nil,
        minZoom: Double? = nil,
        maxZoom: Double? = nil
    ) {
        self.bounds = bounds
        self.minZoom = minZoom
        self.maxZoom = maxZoom
    }

    /// 制限が実質的に無い状態。android-sdk の `CameraRestriction.isEmpty` と同じ判定。
    public var isEmpty: Bool {
        (bounds == nil || bounds?.isEmpty == true) && minZoom == nil && maxZoom == nil
    }

    /// 制限なし。android-sdk の `CameraRestriction.None` に対応。
    public static let None = CameraRestriction()

    public static func == (lhs: CameraRestriction, rhs: CameraRestriction) -> Bool {
        lhs.minZoom == rhs.minZoom
            && lhs.maxZoom == rhs.maxZoom
            && boundsEqual(lhs.bounds, rhs.bounds)
    }

    private static func boundsEqual(_ lhs: GeoRectBounds?, _ rhs: GeoRectBounds?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return left == right
        default: return false
        }
    }
}

/// 範囲制限をクランプ方式で適用するプロバイダ（HERE / ArcGIS / TomTom / MapKit / Longdo、
/// および MapLibre / MapTiler のプログラム移動）が使う共通ロジック。
///
/// android-sdk では `BaseMapViewController` がこの状態と補正関数を持つが、iOS の各プロバイダ
/// コントローラは共通基底クラスを持たない（`final class ...: MapViewControllerProtocol`）ため、
/// 同じ振る舞いを持つ小さなヘルパーとして切り出している。閾値 `zoomEps` / `coordEps` と
/// 補正アルゴリズムは `BaseMapViewController.cameraRestrictionCorrection` と一致。
public final class CameraRestrictionClamp {
    /// 統一ズーム（Google 準拠）での許容誤差。これ未満の差では補正しない。
    public static let zoomEps = 1e-3
    /// 緯度経度（度）での許容誤差。
    public static let coordEps = 1e-7

    private var restriction: CameraRestriction?

    public init() {}

    /// android-sdk の `BaseMapViewController.setCameraRestriction` と同じく、
    /// 空の制限は保持しない（= 制限解除）。
    public func set(_ restriction: CameraRestriction?) {
        self.restriction = restriction.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 現在保持している制限。
    public var current: CameraRestriction? { restriction }

    /// android-sdk の `hasCameraRestriction()` 相当。
    public var hasRestriction: Bool { restriction != nil }

    /// カメラ位置が制限に違反していれば補正後の位置を返す。違反が無ければ `nil`。
    ///
    /// ズームは統一ズーム（Google 準拠）前提。範囲制限はネイティブの
    /// `setLatLngBoundsForCameraTarget` 相当（カメラ中心を矩形内へクランプ）のセマンティクスに揃える。
    /// クランプ方式のプロバイダはカメラ停止時にこれを呼び、返り値があれば `moveCamera` で再適用する。
    /// ε を用いて微小な誤差では補正しないことで、再適用 → イベント → 再補正の無限ループを防ぐ。
    public func correction(for current: MapCameraPosition) -> MapCameraPosition? {
        guard let restriction else { return nil }

        var lat = current.position.latitude
        var lng = current.position.longitude
        var zoom = current.zoom
        var changed = false

        if let minZoom = restriction.minZoom, zoom < minZoom - Self.zoomEps {
            zoom = minZoom
            changed = true
        }
        if let maxZoom = restriction.maxZoom, zoom > maxZoom + Self.zoomEps {
            zoom = maxZoom
            changed = true
        }

        if let sw = restriction.bounds?.southWest, let ne = restriction.bounds?.northEast {
            let south = min(sw.latitude, ne.latitude)
            let north = max(sw.latitude, ne.latitude)
            let west = min(sw.longitude, ne.longitude)
            let east = max(sw.longitude, ne.longitude)
            let clampedLat = min(max(lat, south), north)
            let clampedLng = min(max(lng, west), east)
            if abs(clampedLat - lat) > Self.coordEps {
                lat = clampedLat
                changed = true
            }
            if abs(clampedLng - lng) > Self.coordEps {
                lng = clampedLng
                changed = true
            }
        }

        guard changed else { return nil }
        return current.copy(position: GeoPoint(latitude: lat, longitude: lng), zoom: zoom)
    }
}
