import XCTest

@testable import MapConductorCore

/// マーカータイル 1 枚の実測コスト。
///
/// android-vectortile の `MarkerTileCostTest` と**同じ条件**で回す。同じ LCG
/// シード、同じ緯度経度の分布、同じマーカー数、同じタイルサイズ、同じズーム。
/// 乱数まで揃えてあるので、両者の数字は直接比べられる。
///
/// 片方が遅いという話は、実装のどこが遅いか分かるまで意味を持たない。
/// レンダリングをさらに query / prepare / draw に割る `tileCostBreakdown` を
/// 用意してあるのはそのため。
final class MarkerTileCostTests: XCTestCase {

    private let tileSize = 512

    /// android 側と同じ線形合同法。定数まで同じなので、同じ順で同じ座標が出る。
    private struct Lcg {
        private var seed: UInt64 = 12345
        mutating func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
    }

    private func manager(_ count: Int) -> MarkerManager<AnyObject> {
        let manager = MarkerManager<AnyObject>.defaultManager(minMarkerCount: 1)
        var lcg = Lcg()
        for _ in 0..<count {
            let lat = 35.5 + lcg.next() * 0.4
            let lng = 139.5 + lcg.next() * 0.5
            manager.registerEntity(
                MarkerEntity(
                    marker: nil,
                    state: MarkerState(position: GeoPoint(latitude: lat, longitude: lng)),
                    visible: true,
                    isRendered: true,
                    tiling: true
                )
            )
        }
        return manager
    }

    private func renderer(
        _ manager: MarkerManager<AnyObject>,
        declutterPx: Int = 0
    ) -> MarkerTileRenderer<AnyObject> {
        MarkerTileRenderer(
            markerManager: manager,
            tileSize: tileSize,
            cacheSizeBytes: 8 * 1024 * 1024,
            declutterPx: declutterPx
        )
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    /// タイルの中心が東京になるズーム別の x/y。android 側と同じ式。
    private func tileXY(zoom: Int) -> (Int, Int) {
        let n = Double(1 << zoom)
        let lat = 35.68 * .pi / 180
        let x = Int((139.75 + 180.0) / 360.0 * n)
        let y = Int((1.0 - log(tan(lat) + 1.0 / cos(lat)) / .pi) / 2.0 * n)
        return (x, y)
    }

    func testTileCost() throws {
        for count in [2_000, 20_000] {
            let live = manager(count)
            for declutter in [0, 14] {
                let render = renderer(live, declutterPx: declutter)
                for zoom in [6, 12] {
                    let (x, y) = tileXY(zoom: zoom)
                    let request = TileRequest(x: x, y: y, z: zoom)

                    // 1 枚目はキャッシュも何も温まっていない。中央値を採る。
                    var samples: [Double] = []
                    var bytes = 0
                    for _ in 0..<5 {
                        render.clear()
                        let started = DispatchTime.now().uptimeNanoseconds
                        let data = render.renderTile(request: request)
                        samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                        bytes = data?.count ?? 0
                    }
                    print(
                        String(
                            format: "MARKERTILE n=%d declutter=%d z=%d render=%.1fms png=%dB",
                            count, declutter, zoom, median(samples), bytes
                        )
                    )
                }
            }
        }
    }

    /// 街路樹サンプルと同じ規模。android-vectortile の `StreetTreeCostTest` が
    /// 東京の 144,183 本で測っているズームに合わせてある。
    ///
    /// 数字そのものはハードウェアが違うので android と直接は比べられないが、
    /// **declutter を入れて速くなるか遅くなるか**は比べられる。android は
    /// z=9 で 2140ms -> 109ms になる。
    func testStreetTreeScale() throws {
        let live = manager(144_183)
        for declutter in [0, 14] {
            for zoom in [9, 11, 12, 14] {
                let (x, y) = tileXY(zoom: zoom)
                let request = TileRequest(x: x, y: y, z: zoom)
                let render = renderer(live, declutterPx: declutter)
                var samples: [Double] = []
                var bytes = 0
                for _ in 0..<3 {
                    render.clear()
                    let started = DispatchTime.now().uptimeNanoseconds
                    let data = render.renderTile(request: request)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    bytes = data?.count ?? 0
                }
                print(
                    String(
                        format: "TREES declutter=%d z=%d render=%.0fms png=%dKB",
                        declutter, zoom, median(samples), bytes / 1024
                    )
                )
            }
        }
    }
}
