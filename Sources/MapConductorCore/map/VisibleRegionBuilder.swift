import CoreGraphics
import UIKit

/// ビューポートの 4 隅を逆投影して ``VisibleRegion`` を組み立てる。
///
/// ios-for-maplibre / mapbox / maptiler が同じ 15 行前後を各自持っていたものの集約。
/// android-sdk の `buildVisibleRegion` と同じ形・同じ隅の割り当て。
///
/// ## 使えないプロバイダがある
///
/// すべてのプロバイダがこの形ではない。無理に寄せないこと。
///  - **googlemaps**: ネイティブの `projection.visibleRegion` を使う。SDK が返す値の方が
///    正確なので 4 隅の逆投影に置き換えない。
///  - **here**: bounds はネイティブの `boundingBox` から取り、4 隅だけ逆投影する。
///  - **arcgis**: カメラから幾何的に算出する（`arcGISComputeVisibleRegion`）。
///  - **mapkit**: `MKMapView.region` から直接得られる。
///  - **longdo**: WebView ブリッジで同期の逆投影を持たない
///    （``MapCapability/screenProjectionSync`` を参照）。
public extension MapViewHolderProtocol {
    /// - Parameters:
    ///   - inset: 端から何 px 内側の点を使うか。0 なら端ちょうど。
    ///   - requireAllCorners: `true`（既定）なら 4 隅すべてが解けないと nil を返す。
    ///     `false` なら解けた隅だけで bounds を作り、解けなかった隅は nil のまま残す。
    ///     傾けた地図や球体表示では隅の逆投影が地表に当たらないことがあり、そこで
    ///     ``VisibleRegion`` ごと落とすと marker-clustering がビューポートを算出できず
    ///     クラスタが一切描画されなくなる。それを避けたいプロバイダが `false` を使う。
    /// - Returns: 隅が 1 つも解けなければ nil。
    func buildVisibleRegion(
        inset: CGFloat = 0,
        requireAllCorners: Bool = true
    ) -> VisibleRegion? {
        guard let size = viewportSizePx() else { return nil }
        return buildVisibleRegion(size: size, inset: inset, requireAllCorners: requireAllCorners)
    }

    /// ビューポートのサイズを明示して ``buildVisibleRegion(inset:requireAllCorners:)`` する。
    ///
    /// サイズの解決手段を持たない呼び出し元（ネイティブビューが無いプロバイダ）と、
    /// `UIView` を用意できないユニットテストのためのオーバーロード。
    func buildVisibleRegion(
        size: CGSize,
        inset: CGFloat = 0,
        requireAllCorners: Bool = true
    ) -> VisibleRegion? {
        let left = inset
        let top = inset
        let right = size.width - inset
        let bottom = size.height - inset

        let nearLeft = fromScreenOffsetSync(offset: CGPoint(x: left, y: bottom))
        let nearRight = fromScreenOffsetSync(offset: CGPoint(x: right, y: bottom))
        let farLeft = fromScreenOffsetSync(offset: CGPoint(x: left, y: top))
        let farRight = fromScreenOffsetSync(offset: CGPoint(x: right, y: top))

        let corners = [nearLeft, nearRight, farLeft, farRight].compactMap { $0 }
        if requireAllCorners, corners.count < 4 { return nil }
        if corners.isEmpty { return nil }

        let bounds = GeoRectBounds()
        corners.forEach { bounds.extend(point: $0) }
        return VisibleRegion(
            bounds: bounds,
            nearLeft: nearLeft,
            nearRight: nearRight,
            farLeft: farLeft,
            farRight: farRight
        )
    }

    /// ビューポートのピクセルサイズ。
    ///
    /// 既定では ``MapViewHolderProtocol/mapView`` が `UIView` ならそこから解決する。
    /// まだレイアウト前（幅か高さが 0）なら nil。ネイティブビューを持たないプロバイダ
    /// （WebView ブリッジやビュー以外の描画面）はこれを上書きする。
    func viewportSizePx() -> CGSize? {
        guard let view = mapView as? UIView else { return nil }
        let size = view.bounds.size
        if size.width <= 0 || size.height <= 0 { return nil }
        return size
    }
}
