import CoreGraphics
import Foundation

/// ネイティブにパディングを持たない地図 SDK 向けの、`MapCameraPosition.paddings` の再現。
///
/// パディングの意味は「画面の端をその分だけ空け、残りの領域の中央にカメラのターゲットを置く」。
/// ネイティブに無い SDK では、ターゲットが空けた残りの中央に来るよう、**カメラの中心をずらして**
/// 渡す（``cameraCenter(for:fov:viewportSize:)``）。読み戻しでは逆にずらしてターゲットへ戻す
/// （``target(forCameraCenter:camera:paddings:fov:viewportSize:)``）。
///
/// ずらす量は、画面の中心からターゲットまでの画面上のずれ
/// `dx = (left − right) / 2`、`dy = (top − bottom) / 2`（pt）を、地表の距離へ換算したもの。
///
/// - 遠近あり（`fov > 0`）: 焦点距離 `f = (H / 2) / tan(fov / 2)`、カメラから画面中心の地点までの
///   距離 `D = f · mpp`（mpp は画面中心での 1pt あたりのメートル）。ターゲットへの視線が
///   光軸から下へ `α = atan(dy / f)` 傾くので、手前への距離は `D·sin t − D·cos t·tan(t − α)`。
///   横は、ターゲットの光軸方向の奥行き `z` を使って `dx · z / f`。
/// - 遠近なし（`fov == 0`。ビューを傾けて擬似的に tilt を表す SDK）: 手前へ `dy · mpp / cos t`、横へ
///   `dx · mpp`。
/// - 視野角が分からない（`fov == nil`）か tilt が 0: tilt 0 と同じ `dy · mpp`、`dx · mpp`。
///
/// 視野角はプロバイダが持つ値を渡す。**コアは既定の視野角を持たない。**
@_spi(MapConductorDriver)
public enum CameraPaddingEmulation {
    /// ターゲットをパディングの残りの中央に見せるために、カメラの中心として渡す地点。
    ///
    /// パディングが無い（または全て 0）ならターゲットをそのまま返す。
    public static func cameraCenter(
        for camera: MapCameraPositionProtocol,
        fov: Double?,
        viewportSize: CGSize
    ) -> GeoPoint {
        let target = GeoPoint.from(position: camera.position)
        guard let offset = groundOffset(camera: camera, paddings: camera.paddings, fov: fov, viewportSize: viewportSize) else {
            return target
        }
        let heading = CameraBearing.toNativeHeading(camera.bearing)
        // ターゲットが画面中心より下（手前）・右に見えるよう、中心は奥・左へ置く。
        let forward = Spherical.computeOffset(origin: target, distance: offset.backward, heading: heading)
        let center = Spherical.computeOffset(origin: forward, distance: offset.lateral, heading: heading - 90.0)
        return GeoPoint(latitude: center.latitude, longitude: center.longitude, altitude: target.altitude ?? 0)
    }

    /// ``cameraCenter(for:fov:viewportSize:)`` の逆。読み戻したカメラの中心からターゲットを求める。
    ///
    /// `camera` からは zoom / tilt / bearing だけを使う。
    public static func target(
        forCameraCenter center: GeoPointProtocol,
        camera: MapCameraPositionProtocol,
        paddings: MapPaddingsProtocol?,
        fov: Double?,
        viewportSize: CGSize
    ) -> GeoPoint {
        let origin = GeoPoint.from(position: center)
        guard let offset = groundOffset(camera: camera, paddings: paddings, fov: fov, viewportSize: viewportSize) else {
            return origin
        }
        let heading = CameraBearing.toNativeHeading(camera.bearing)
        let back = Spherical.computeOffset(origin: origin, distance: offset.backward, heading: heading + 180.0)
        let target = Spherical.computeOffset(origin: back, distance: offset.lateral, heading: heading + 90.0)
        return GeoPoint(latitude: target.latitude, longitude: target.longitude, altitude: origin.altitude ?? 0)
    }

    /// 地図 SDK へ渡すカメラ。`position` をずらした中心に、`paddings` を 0 にしたもの。
    ///
    /// 移動の入り口で一度だけ通す。アニメーションの補間は、この「中心」の空間で行う。
    public static func applied(
        to camera: MapCameraPosition,
        fov: Double?,
        viewportSize: CGSize
    ) -> MapCameraPosition {
        guard groundOffset(camera: camera, paddings: camera.paddings, fov: fov, viewportSize: viewportSize) != nil else {
            return camera
        }
        return camera.copy(
            position: cameraCenter(for: camera, fov: fov, viewportSize: viewportSize),
            paddings: MapPaddings.Zeros
        )
    }

    /// 地図 SDK から読み戻したカメラ（`position` は画面中心）を、ターゲットと `paddings`・`fov` を
    /// 持つカメラへ戻す。``applied(to:fov:viewportSize:)`` の逆。
    public static func restored(
        _ camera: MapCameraPosition,
        paddings: MapPaddingsProtocol?,
        fov: Double?,
        viewportSize: CGSize
    ) -> MapCameraPosition {
        let target = self.target(
            forCameraCenter: camera.position,
            camera: camera,
            paddings: paddings,
            fov: fov,
            viewportSize: viewportSize
        )
        return MapCameraPosition(
            position: GeoPoint(
                latitude: target.latitude,
                longitude: target.longitude,
                altitude: camera.position.altitude ?? 0
            ),
            zoom: camera.zoom,
            bearing: camera.bearing,
            tilt: camera.tilt,
            paddings: paddings ?? MapPaddings.Zeros,
            visibleRegion: camera.visibleRegion,
            fov: fov
        )
    }

    /// 画面中心からターゲットまでの地表の距離（メートル）。手前が正の `backward`、右が正の `lateral`。
    static func groundOffset(
        camera: MapCameraPositionProtocol,
        paddings: MapPaddingsProtocol?,
        fov: Double?,
        viewportSize: CGSize
    ) -> (backward: Double, lateral: Double)? {
        guard let paddings else { return nil }
        let dx = (paddings.left - paddings.right) / 2.0
        let dy = (paddings.top - paddings.bottom) / 2.0
        if dx == 0, dy == 0 { return nil }

        let latitude = min(max(camera.position.latitude, -85.0), 85.0)
        let mpp = WebMercatorZoomAltitudeConverter.webMercatorInitialMpp256
            * cos(latitude * .pi / 180.0) / pow(2.0, camera.zoom)
        let tilt = min(max(camera.tilt, 0.0), 89.0) * .pi / 180.0
        let height = Double(viewportSize.height)

        guard tilt > 0, let fov else {
            return (dy * mpp, dx * mpp)
        }
        if fov <= 0 {
            return (dy * mpp / cos(tilt), dx * mpp)
        }
        guard height > 0 else { return (dy * mpp, dx * mpp) }

        let focal = (height / 2.0) / tan(fov * .pi / 360.0)
        let distance = focal * mpp
        let alpha = atan(dy / focal)
        // 視線が地平線より上を向くと地表に当たらない。手前すれすれで止める。
        let fromVertical = min(tilt - alpha, 89.0 * .pi / 180.0)
        let backward = distance * sin(tilt) - distance * cos(tilt) * tan(fromVertical)
        let depth = distance * cos(tilt) / cos(fromVertical) * cos(alpha)
        return (backward, dx * depth / focal)
    }
}
