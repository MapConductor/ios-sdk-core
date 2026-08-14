import CoreGraphics
import Foundation

/// 地理座標 ⇄ 画面座標を、カメラとビューの大きさだけから計算する。
///
/// ## なぜコアに置くのか
///
/// 地図が Web Mercator なら、投影はカメラ（中心・ズーム・方位）とビューの大きさで
/// 決まる。地図SDKに聞く必要がない。**WebView 系のプロバイダは同期の投影 API を
/// 持たない**（Longdo / MapTiler のホルダーは `toScreenOffset` が nil）ため、
/// これが無いと InfoBubble・マーカー追従・タイルの当たり判定が黙って死ぬ。
///
/// 同じ式を各プロバイダやブリッジ層で書き直すと、片方だけ直る／片方だけずれる。
/// **判定も計算もここに一本化すること。**
/// （android-sdk-core の `WebMercatorScreenProjection` と同じ式・同じ引数。）
///
/// ## 使えない条件
///
/// - **Web Mercator でない地図**（3D globe の HERE、球面の Cesium 等）。
///   これらは地図SDK自身の投影を使うこと。
/// - **tilt が 0 でないとき。** 傾いたカメラは平面の相似変換にならないので誤差が出る。
///   （必要になったら `visibleRegion` の 4 隅からホモグラフィを組む方式へ拡張できる。）
///
/// bearing（回転）には対応している。
public enum WebMercatorScreenProjection {
    /// 統一ズーム 0 のときの世界の大きさ（pt）。統一ズームは Google 基準の 256px タイル。
    private static let worldSizeAtZoom0: Double = 256

    /// 地理座標 → 画面座標。ビューが未レイアウト（幅か高さが 0）なら nil。
    public static func toScreenOffset(
        _ position: GeoPointProtocol,
        camera: MapCameraPosition,
        size: CGSize
    ) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let worldSize = worldSizeAtZoom0 * pow(2.0, camera.zoom)
        let center = normalize(camera.position)
        let target = normalize(position)

        // 日付変更線をまたぐときは短いほうへ回す。これをしないと地図の反対側へ飛ぶ。
        var dx = target.x - center.x
        if dx > 0.5 { dx -= 1.0 }
        if dx < -0.5 { dx += 1.0 }

        var sx = dx * worldSize
        var sy = (target.y - center.y) * worldSize
        if camera.bearing != 0 {
            // bearing は「画面の上が指す方位（北から時計回り）」。世界を -bearing 回す。
            let angle = -camera.bearing * .pi / 180.0
            let rx = sx * cos(angle) - sy * sin(angle)
            let ry = sx * sin(angle) + sy * cos(angle)
            sx = rx
            sy = ry
        }
        let result = CGPoint(x: size.width / 2.0 + sx, y: size.height / 2.0 + sy)
        return (result.x.isFinite && result.y.isFinite) ? result : nil
    }

    /// ``toScreenOffset(_:camera:size:)`` の逆。タップの当たり判定に使う。
    public static func fromScreenOffset(
        _ offset: CGPoint,
        camera: MapCameraPosition,
        size: CGSize
    ) -> GeoPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        var sx = offset.x - size.width / 2.0
        var sy = offset.y - size.height / 2.0
        if camera.bearing != 0 {
            let angle = camera.bearing * .pi / 180.0
            let rx = sx * cos(angle) - sy * sin(angle)
            let ry = sx * sin(angle) + sy * cos(angle)
            sx = rx
            sy = ry
        }
        let worldSize = worldSizeAtZoom0 * pow(2.0, camera.zoom)
        let center = normalize(camera.position)
        var wx = center.x + Double(sx) / worldSize
        let wy = center.y + Double(sy) / worldSize
        wx -= floor(wx)

        let extent = 2.0 * Earth.radiusMeters * Double.pi
        let projected = CGPoint(x: (wx - 0.5) * extent, y: (0.5 - wy) * extent)
        let point = WebMercatorProjection().unproject(projected)
        guard point.latitude.isFinite, point.longitude.isFinite else { return nil }
        return point
    }

    /// Web Mercator のメートル座標を [0,1] へ。y は北が 0。
    private static func normalize(_ position: GeoPointProtocol) -> (x: Double, y: Double) {
        let projected = WebMercatorProjection().project(position)
        let extent = 2.0 * Earth.radiusMeters * Double.pi
        return (x: 0.5 + Double(projected.x) / extent, y: 0.5 - Double(projected.y) / extent)
    }
}
