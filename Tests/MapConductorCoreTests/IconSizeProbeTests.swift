import UIKit
import XCTest

@testable import MapConductorCore

/// アイコンが実際に何ピクセルで描かれるかを、出来上がったタイルから数える。
///
/// android-sdk の `IconSizeProbeTest` と対になっていて、同じ 14 単位の円を、
/// 同じ zoom・同じ iconScaleCallback で描いて比べる。計算で追うと前提を一つ
/// 間違えるだけで答えが変わるので、描いた結果を測る。
final class IconSizeProbeTests: XCTestCase {

    func testDrawnIconSize() {
        let screenScale = UIScreen.main.scale
        // プロバイダと同じ組み立て（GoogleMapMarkerController.setupTileRenderer）:
        // タイルは Retina 倍、コールバックも画面スケール倍して渡す。
        let tileSize = 256 * max(1, Int(screenScale))
        let contentScale = Double(screenScale)
        let callbackScale = 1.4  // サンプルの zoom > 15 の帯

        // サンプルと同じ作り: 14 ポイントの円。
        let sizePt: CGFloat = 10
        let image = UIGraphicsImageRenderer(size: CGSize(width: sizePt, height: sizePt)).image { ctx in
            UIColor.red.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0.5, y: 0.5, width: sizePt - 1, height: sizePt - 1))
        }
        let icon = ImageIcon(image: image, iconSize: sizePt)

        let zoom = 16
        let n = Double(1 << zoom)
        let lat = 35.68, lon = 139.75
        let latRad = lat * .pi / 180
        let tx = Int((lon + 180.0) / 360.0 * n)
        let ty = Int((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n)

        let manager = MarkerManager<AnyObject>.defaultManager(minMarkerCount: 1)
        manager.registerEntity(
            MarkerEntity(
                marker: nil,
                state: MarkerState(position: GeoPoint(latitude: lat, longitude: lon), icon: icon),
                visible: true, isRendered: true, tiling: true
            )
        )
        let renderer = MarkerTileRenderer<AnyObject>(
            markerManager: manager,
            tileSize: tileSize,
            cacheSizeBytes: 1 << 20,
            iconScaleCallback: { _, _ in callbackScale * contentScale }
        )

        guard let data = renderer.renderTile(request: TileRequest(x: tx, y: ty, z: zoom)),
              let cg = UIImage(data: data)?.cgImage else {
            return XCTFail("タイルが描けていない")
        }

        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, maxX = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        let drawnPx = maxX - minX + 1
        // タイルは 256pt として表示されるので、見かけの大きさはこの比。
        let apparentPt = Double(drawnPx) / Double(w) * 256.0
        print(String(
            format: "ICONPROBE ios scale=%.2f tile=%d canvas=%d iconSize=%.0f drawnPx=%d apparentPt=%.2f",
            screenScale, tileSize, w, sizePt, drawnPx, apparentPt))
        XCTAssertGreaterThan(drawnPx, 0)
    }
}
