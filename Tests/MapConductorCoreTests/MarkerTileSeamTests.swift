import UIKit
import XCTest

@testable import MapConductorCore

/// 隣り合うタイルは、継ぎ目にかかるマーカーについて同じ判断をしなければならない。
///
/// タイルは 1 枚ずつ独立に描かれる。あるマーカーがタイル A では描かれ、隣の B では
/// 描かれないと、境界でアイコンが**切れて**見える。A 側の半分だけが残り、続きが
/// どこにも無い。
///
/// レンダラは、アイコンが食い込む分だけ箱を広げて問い合わせる（`queryByHalfExtentPx`）。
/// だから「A に返ったマーカーのうち B の広げた箱にも入るものは、B にも返る」が
/// 成り立てば、継ぎ目は合う。ここが見ているのはその 1 点だけで、描画には触れない。
///
/// android-sdk の `MarkerTileSeamTest`、react-sdk の `MarkerTileSeam.test.mjs` と
/// 同じことを見ている。
final class MarkerTileSeamTests: XCTestCase {

    private let tileSize = 512.0
    /// サンプルと同じ declutter。継ぎ目の食い違いは間引きの副作用として出る。
    private let declutterPx = 14.0
    /// アイコン半分ぶん。レンダラは実測の最大半径を使うが、ここでは固定でよい。
    private let halfExtentPx = 10.0

    private struct Lcg {
        private var seed: UInt64 = 12345
        mutating func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
    }

    private func markers(_ count: Int) -> [MarkerEntity<Int>] {
        var lcg = Lcg()
        return (0..<count).map { at in
            MarkerEntity(
                marker: at,
                state: MarkerState(
                    position: GeoPoint(
                        latitude: 35.5 + lcg.next() * 0.4,
                        longitude: 139.5 + lcg.next() * 0.5
                    ),
                    id: String(at)
                ),
                isRendered: true
            )
        }
    }

    /// タイル座標から緯度経度の箱。レンダラと同じ式。
    private func tileBounds(x: Int, y: Int, z: Int) -> GeoRectBounds {
        func point(_ tx: Double, _ ty: Double) -> GeoPoint {
            let n = pow(2.0, Double(z))
            let lon = tx / n * 360.0 - 180.0
            let lat = atan(sinh(.pi * (1.0 - 2.0 * (ty / n)))) * 180.0 / .pi
            return GeoPoint(latitude: lat, longitude: lon)
        }
        let northWest = point(Double(x), Double(y))
        let southEast = point(Double(x + 1), Double(y + 1))
        return GeoRectBounds(
            southWest: GeoPoint(latitude: southEast.latitude, longitude: northWest.longitude),
            northEast: GeoPoint(latitude: northWest.latitude, longitude: southEast.longitude)
        )
    }

    /// レンダラが実際に問い合わせる箱と分離距離。
    ///
    /// 分離距離が最下段より細かいズームでは索引が間引きを断り、レンダラは
    /// そのまま全件クエリに落ちる。そちらも継ぎ目が合っていなければならない
    /// ので、断られたら `inBounds` の結果で同じことを見る。
    private func query(
        _ index: MarkerGridIndex<Int>,
        x: Int,
        y: Int,
        z: Int
    ) -> (expanded: GeoRectBounds, kept: [MarkerEntity<Int>], thinned: Bool) {
        let bounds = tileBounds(x: x, y: y, z: z)
        let span = bounds.toSpan()!
        let padNorm = halfExtentPx / tileSize
        let expanded = bounds.expandedByDegrees(
            latPad: span.latitude * padNorm,
            lonPad: span.longitude * padNorm
        )
        let separation = max(span.latitude, span.longitude) * declutterPx / tileSize
        if let kept = index.inBoundsThinned(expanded, minSeparationDegrees: separation) {
            return (expanded, kept, true)
        }
        return (expanded, index.inBounds(expanded), false)
    }

    func testAdjacentTilesAgreeOnTheMarkersTheyShare() {
        let all = markers(144_183)
        let index = MarkerGridIndex<Int> { all }

        var checked = 0
        var thinnedPairs = 0
        for z in [9, 10, 11, 12, 13, 14] {
            let n = pow(2.0, Double(z))
            let x = Int((139.75 + 180.0) / 360.0 * n)
            let y = Int((1.0 - log(tan(35.68 * .pi / 180) + 1.0 / cos(35.68 * .pi / 180)) / .pi) / 2.0 * n)

            // 横隣りと縦隣り。継ぎ目は 2 方向にある。
            for (dx, dy) in [(1, 0), (0, 1)] {
                let a = query(index, x: x, y: y, z: z)
                let b = query(index, x: x + dx, y: y + dy, z: z)
                // 低いズームではマーカーの塊が 1 枚に収まり、隣が空になる。
                // 空の側と比べても何も分からないので、その組は数えない。
                if a.kept.isEmpty || b.kept.isEmpty { continue }
                checked += 1
                if a.thinned { thinnedPairs += 1 }

                let inB = Set(b.kept.map(\.state.id))
                let missing = a.kept.filter {
                    b.expanded.contains(point: $0.state.position) && !inB.contains($0.state.id)
                }
                XCTAssertEqual(
                    missing.count, 0,
                    "z=\(z) d=(\(dx),\(dy)) thinned=\(a.thinned): A が描くマーカー "
                        + "\(missing.count) 個を、重なる B が描かない -- 継ぎ目でアイコンが切れる"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 8, "比べられた組が少なすぎる")
        XCTAssertGreaterThanOrEqual(thinnedPairs, 4, "間引きが効いている組を見ていない")
    }

    // MARK: - 描いた結果で見る

    /// 描いた 2 枚の継ぎ目が、画素として破綻していないこと。
    ///
    /// **粗い保険で、個々の切れは見えない。** 上のテストが数えている取りこぼしを
    /// これで再現しようとしたが、街路樹の密度だと継ぎ目の列が絵で埋まり
    /// （`touching` が 512 行中 512）、1 個のアイコンが欠けても画素には出ない。
    /// 索引の修正を戻して測っても数字は動かなかった。だから**通ったことを根拠に
    /// してはいけない。** 継ぎ目の保証は
    /// `testAdjacentTilesAgreeOnTheMarkersTheyShare` が持っている。
    ///
    /// ここに残す理由は、タイルが丸ごとずれる・半分描かれないといった大きな崩れを
    /// 拾うため。`touching` の assert は、継ぎ目に絵が無いのに通ってしまう
    /// 空振りを防ぐためにある。
    func testRenderedTilesDoNotCutIconsAtTheSeam() throws {
        let manager = MarkerManager<AnyObject>.defaultManager(minMarkerCount: 1)
        for entity in markers(40_000) {
            manager.registerEntity(
                MarkerEntity(
                    marker: nil,
                    state: entity.state,
                    visible: true,
                    isRendered: true,
                    tiling: true
                )
            )
        }
        let renderer = MarkerTileRenderer<AnyObject>(
            markerManager: manager,
            tileSize: Int(tileSize),
            cacheSizeBytes: 8 * 1024 * 1024,
            declutterPx: Int(declutterPx)
        )

        var total = 0
        var seams = 0
        for z in [11, 12, 13] {
            let n = pow(2.0, Double(z))
            let x = Int((139.75 + 180.0) / 360.0 * n)
            let y = Int((1.0 - log(tan(35.68 * .pi / 180) + 1.0 / cos(35.68 * .pi / 180)) / .pi) / 2.0 * n)

            guard let left = renderer.renderTile(request: TileRequest(x: x, y: y, z: z)),
                  let right = renderer.renderTile(request: TileRequest(x: x + 1, y: y, z: z)),
                  let leftAlpha = Self.alphaRows(left, column: Int(tileSize) - 1),
                  let rightAlpha = Self.alphaRows(right, column: 0)
            else {
                return XCTFail("z=\(z) のタイルが描けない")
            }
            seams += 1

            var cut = 0
            var touching = 0
            for row in 0..<leftAlpha.count {
                if leftAlpha[row] > 0 { touching += 1 }
                if leftAlpha[row] > 0 && rightAlpha[row] == 0 { cut += 1 }
            }
            // 左タイルの最終列に何も無ければ、この比較は空振り。
            XCTAssertGreaterThan(touching, 0, "z=\(z) の継ぎ目に絵が無く、何も検証していない")
            print("SEAM z=\(z) cut=\(cut) / touching=\(touching) / \(leftAlpha.count) rows")
            total += cut
        }
        XCTAssertEqual(seams, 3, "3 枚とも描けていないと比較にならない")
        XCTAssertLessThan(total, 20, "継ぎ目で途切れている行が多すぎる -- アイコンが切れている")
    }

    /// PNG の 1 列ぶんのアルファ。
    private static func alphaRows(_ png: Data, column: Int) -> [UInt8]? {
        guard let image = UIImage(data: png)?.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).map { pixels[($0 * width + column) * 4 + 3] }
    }

    // MARK: - 間引きの勝者はタイルに依らない

    /// 同じ間引きセルを共有する 2 本は、**両方のタイルが同じ 1 本**を描く。
    ///
    /// 勝者を「列挙順で最後」にしていたころ、列挙順はセルを歩く順 -- つまり
    /// 問い合わせた箱に依存した。境界をまたぐセルでは左右のタイルが別の木を
    /// 選び、赤と茶が 1 つの丸に半分ずつ縫い合わさって見えた（チームラボ横で
    /// 実際に出た形）。ここでは色の違う 2 本を境界ぎわの同一セルに置き、
    /// 左右のタイルを実際に描いて、**片方の色だけが両方のタイルに**現れる
    /// ことを画素で確かめる。
    func testDeclutterWinnerAgreesAcrossTiles() throws {
        let z = 14
        let n = pow(2.0, Double(z))
        // 東京付近のタイル境界（x 方向）を 1 本選ぶ。
        let boundaryX = Int((139.75 + 180.0) / 360.0 * n) + 1
        let boundaryLon = Double(boundaryX) / n * 360.0 - 180.0
        let y = Int((1.0 - log(tan(35.68 * .pi / 180) + 1.0 / cos(35.68 * .pi / 180)) / .pi) / 2.0 * n)
        let centerLat = atan(sinh(.pi * (1.0 - 2.0 * (Double(y) + 0.5) / n))) * 180.0 / .pi

        // タイルは 512px、declutter 14px。境界のすぐ西、同じ 14px セルに 2 本。
        let lonPerPx = 360.0 / n / 512.0
        func solid(_ color: UIColor) -> ImageIcon {
            let size = CGSize(width: 20, height: 20)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            return ImageIcon(image: image, iconSize: 20)
        }
        let manager = MarkerManager<AnyObject>.defaultManager(minMarkerCount: 1)
        for (at, offsetPx) in [3.0, 6.0].enumerated() {
            manager.registerEntity(
                MarkerEntity(
                    marker: nil,
                    state: MarkerState(
                        position: GeoPoint(latitude: centerLat, longitude: boundaryLon - offsetPx * lonPerPx),
                        id: "seam-\(at)",
                        icon: solid(at == 0 ? .red : .blue)
                    ),
                    visible: true,
                    isRendered: true,
                    tiling: true
                )
            )
        }
        let renderer = MarkerTileRenderer<AnyObject>(
            markerManager: manager,
            tileSize: 512,
            cacheSizeBytes: 1024 * 1024,
            declutterPx: 14
        )

        func colors(_ png: Data) throws -> (red: Int, blue: Int) {
            let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(
                data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var red = 0, blue = 0
            for at in stride(from: 0, to: pixels.count, by: 4) where pixels[at + 3] > 200 {
                if pixels[at] > 200 && pixels[at + 2] < 60 { red += 1 }
                if pixels[at + 2] > 200 && pixels[at] < 60 { blue += 1 }
            }
            return (red, blue)
        }

        let west = try XCTUnwrap(renderer.renderTile(request: TileRequest(x: boundaryX - 1, y: y, z: z)))
        let east = try XCTUnwrap(renderer.renderTile(request: TileRequest(x: boundaryX, y: y, z: z)))
        let w = try colors(west)
        let e = try colors(east)

        // 2 本は同じセルなので、生き残りは 1 本だけ。
        XCTAssertTrue((w.red == 0) != (w.blue == 0), "西タイルに両方（または どちらも）描かれている: \(w)")
        // マーカーは境界の 3px 西なので、20px のアイコンは東タイルへ 7px はみ出す。
        // 東タイルにも**同じ色**が出ていなければ、境界で切れている。
        XCTAssertTrue((e.red > 0) || (e.blue > 0), "東タイルにはみ出し分が描かれていない")
        XCTAssertEqual(w.red > 0, e.red > 0, "左右のタイルが別の木を勝者に選んだ")
        XCTAssertEqual(w.blue > 0, e.blue > 0, "左右のタイルが別の木を勝者に選んだ")
    }

    /// 同じセルの勝者は、マーカーの**登録順にも**依存しない。
    ///
    /// 間引きの勝者を「列挙順で最後」にしていたころ、同セル内の列挙順は
    /// `allEntities()` の辞書順 -- 索引を作り直すたびに変わり得る値だった。
    /// 隣のタイルは別の時刻（別の再構築世代）に描かれるので、同じセルを
    /// 共有する 2 枚が別の木を勝者に選び、上半分と下半分が別の色の
    /// 「割れた丸」になる -- 御茶ノ水の実機で出た形。ここでは同一座標・
    /// 異色の 2 本を**登録順を逆にした 2 つのマネージャ**で描き、どちらも
    /// 同じ色を勝者に選ぶことを確かめる。
    func testDeclutterWinnerDoesNotDependOnRegistrationOrder() throws {
        let z = 16
        let n = pow(2.0, Double(z))
        let x = Int((139.765 + 180.0) / 360.0 * n)
        let y = Int((1.0 - log(tan(35.68 * .pi / 180) + 1.0 / cos(35.68 * .pi / 180)) / .pi) / 2.0 * n)
        let lat = atan(sinh(.pi * (1.0 - 2.0 * (Double(y) + 0.5) / n))) * 180.0 / .pi
        let lon = (Double(x) + 0.5) / n * 360.0 - 180.0

        func solid(_ color: UIColor) -> ImageIcon {
            let size = CGSize(width: 20, height: 20)
            return ImageIcon(
                image: UIGraphicsImageRenderer(size: size).image { context in
                    color.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                },
                iconSize: 20
            )
        }
        // 同じ ImageIcon インスタンスを両方のマネージャで使う。実機でも種ごとの
        // アイコンは共有されるので、これが実際の形。
        let red = solid(.red)
        let blue = solid(.blue)

        func png(order: [(String, ImageIcon)]) throws -> Data {
            let manager = MarkerManager<AnyObject>.defaultManager(minMarkerCount: 1)
            for (id, icon) in order {
                manager.registerEntity(
                    MarkerEntity(
                        marker: nil,
                        state: MarkerState(
                            position: GeoPoint(latitude: lat, longitude: lon),
                            id: id,
                            icon: icon
                        ),
                        visible: true,
                        isRendered: true,
                        tiling: true
                    )
                )
            }
            let renderer = MarkerTileRenderer<AnyObject>(
                markerManager: manager,
                tileSize: 512,
                cacheSizeBytes: 1024 * 1024,
                declutterPx: 14
            )
            return try XCTUnwrap(renderer.renderTile(request: TileRequest(x: x, y: y, z: z)))
        }
        func colors(_ png: Data) throws -> (red: Int, blue: Int) {
            let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(
                data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var red = 0, blue = 0
            for at in stride(from: 0, to: pixels.count, by: 4) where pixels[at + 3] > 200 {
                if pixels[at] > 200 && pixels[at + 2] < 60 { red += 1 }
                if pixels[at + 2] > 200 && pixels[at] < 60 { blue += 1 }
            }
            return (red, blue)
        }

        let forward = try colors(try png(order: [("a", red), ("b", blue)]))
        let reversed = try colors(try png(order: [("b", blue), ("a", red)]))
        print("ORDERSEAM forward=\(forward) reversed=\(reversed)")
        XCTAssertTrue((forward.red == 0) != (forward.blue == 0), "1 本に間引かれていない: \(forward)")
        XCTAssertEqual(forward.red > 0, reversed.red > 0, "登録順で勝者が変わった: \(forward) vs \(reversed)")
        XCTAssertEqual(forward.blue > 0, reversed.blue > 0, "登録順で勝者が変わった: \(forward) vs \(reversed)")
    }
}
