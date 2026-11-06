// URL で渡した画像（ImageIcon(imageUrl:) / GroundImageState(imageUrl:)）。
//
// - 同じ URL は 1 度しか取りに行かない。
// - アイコンは読み終えるまで同じ大きさの透明な画像で、読み終えると hashCode が変わる。
// - マーカーは、自分のアイコンが読み終えたときだけ描き直しを知らせる。その前に別のアイコンへ
//   差し替えられていたら知らせない。
// - 地表画像は読み終えたら image に入る。後から自分で image を入れたら imageUrl は nil。
//
// 取りに行く処理は偽物に差し替え、テストから返す。

import UIKit
import XCTest
@testable import MapConductorCore

@MainActor
final class ImageUrlLoadingTests: XCTestCase {
    private final class FakeFetch {
        var requests: [URL] = []
        var completions: [URL: [(Data?) -> Void]] = [:]

        lazy var loader = RemoteImageLoader { [unowned self] url, completion in
            self.requests.append(url)
            self.completions[url, default: []].append(completion)
        }

        func respond(_ url: URL, _ data: Data?) {
            let pending = completions.removeValue(forKey: url) ?? []
            pending.forEach { $0(data) }
        }
    }

    private let url = URL(string: "https://example.com/icon.png")!
    private let otherUrl = URL(string: "https://example.com/other.png")!

    private func png(_ color: UIColor, size: CGFloat = 4) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    func testSameUrlIsFetchedOnce() {
        let fake = FakeFetch()
        let a = ImageIcon(imageUrl: url, loader: fake.loader)
        let b = ImageIcon(imageUrl: url, loader: fake.loader)
        _ = a.toBitmapIcon()
        _ = b.hashCode()
        XCTAssertEqual(fake.requests, [url])

        var calls = 0
        XCTAssertTrue(fake.loader.whenSettled(url) { _ in calls += 1 })
        fake.respond(url, png(.red))
        XCTAssertEqual(calls, 1)
        // 読み終えた後は登録せず、状態を見ればよい。
        XCTAssertFalse(fake.loader.whenSettled(url) { _ in calls += 1 })
        XCTAssertEqual(fake.requests, [url])
    }

    func testIconIsBlankUntilLoadedAndHashChangesOnce() {
        let fake = FakeFetch()
        let icon = ImageIcon(imageUrl: url, iconSize: 20, loader: fake.loader)
        let pendingHash = icon.hashCode()
        let pending = icon.toBitmapIcon()
        XCTAssertEqual(pending.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(icon.imageUrl, url)

        fake.respond(url, png(.red))
        let readyHash = icon.hashCode()
        XCTAssertNotEqual(pendingHash, readyHash)
        let ready = icon.toBitmapIcon()
        XCTAssertEqual(ready.size, pending.size)
        XCTAssertFalse(ready.bitmap === pending.bitmap)
        XCTAssertEqual(icon.hashCode(), readyHash)
        // 同じ URL・同じ設定なら、後から作ったアイコンも同じ値。
        XCTAssertEqual(ImageIcon(imageUrl: url, iconSize: 20, loader: fake.loader).hashCode(), readyHash)
    }

    func testFailedLoadStaysBlankAndIsNotRetried() {
        let fake = FakeFetch()
        let icon = ImageIcon(imageUrl: url, loader: fake.loader)
        let pendingHash = icon.hashCode()
        fake.respond(url, nil)
        XCTAssertNotEqual(icon.hashCode(), pendingHash)
        _ = ImageIcon(imageUrl: url, loader: fake.loader).toBitmapIcon()
        XCTAssertEqual(fake.requests, [url])
    }

    func testMarkerRedrawsWhenItsIconLoads() {
        let fake = FakeFetch()
        let icon = ImageIcon(imageUrl: url, loader: fake.loader)
        let marker = MarkerState(position: GeoPoint(latitude: 35, longitude: 139), id: "m", icon: icon)
        var mutations = 0
        marker.mutations.listen { mutations += 1 }
        let before = marker.fingerPrint()

        fake.respond(url, png(.red))
        XCTAssertEqual(mutations, 1)
        XCTAssertTrue(marker.icon as? ImageIcon === icon)
        XCTAssertNotEqual(marker.fingerPrint(), before)
    }

    func testMarkerDoesNotRedrawForAReplacedIcon() {
        let fake = FakeFetch()
        let marker = MarkerState(
            position: GeoPoint(latitude: 35, longitude: 139),
            id: "m",
            icon: ImageIcon(imageUrl: url, loader: fake.loader)
        )
        var mutations = 0
        marker.mutations.listen { mutations += 1 }
        marker.icon = ImageIcon(imageUrl: otherUrl, loader: fake.loader)
        XCTAssertEqual(mutations, 1)

        fake.respond(url, png(.red))
        XCTAssertEqual(mutations, 1)
        fake.respond(otherUrl, png(.blue))
        XCTAssertEqual(mutations, 2)
    }

    func testManyMarkersShareOneLoad() {
        let fake = FakeFetch()
        let icon = ImageIcon(imageUrl: url, loader: fake.loader)
        let markers = (0 ..< 1000).map {
            MarkerState(position: GeoPoint(latitude: 35, longitude: 139), id: "m\($0)", icon: icon)
        }
        var mutations = 0
        markers.forEach { $0.mutations.listen { mutations += 1 } }
        fake.respond(url, png(.red))
        XCTAssertEqual(fake.requests, [url])
        XCTAssertEqual(mutations, markers.count)
    }

    func testGroundImageLoadsIntoImage() {
        let fake = FakeFetch()
        let bounds = GeoRectBounds(
            southWest: GeoPoint(latitude: 35, longitude: 139),
            northEast: GeoPoint(latitude: 36, longitude: 140)
        )
        let state = GroundImageState(bounds: bounds, imageUrl: url, loader: fake.loader)
        XCTAssertEqual(state.image.size, CGSize(width: 1, height: 1))
        let id = state.id
        var mutations = 0
        state.mutations.listen { mutations += 1 }

        fake.respond(url, png(.red, size: 8))
        XCTAssertEqual(state.image.size, CGSize(width: 8, height: 8))
        XCTAssertEqual(state.imageUrl, url)
        XCTAssertEqual(state.id, id)
        XCTAssertEqual(mutations, 1)

        // 自分で入れた画像が勝ち、URL は外れる。
        let own = UIImage(data: png(.green, size: 2))!
        state.image = own
        XCTAssertNil(state.imageUrl)
        XCTAssertTrue(state.image === own)
    }

    func testGroundImageIgnoresAStaleUrl() {
        let fake = FakeFetch()
        let bounds = GeoRectBounds(
            southWest: GeoPoint(latitude: 35, longitude: 139),
            northEast: GeoPoint(latitude: 36, longitude: 140)
        )
        let state = GroundImageState(bounds: bounds, imageUrl: url, loader: fake.loader)
        state.imageUrl = otherUrl
        fake.respond(url, png(.red, size: 8))
        XCTAssertEqual(state.image.size, CGSize(width: 1, height: 1))
        fake.respond(otherUrl, png(.blue, size: 6))
        XCTAssertEqual(state.image.size, CGSize(width: 6, height: 6))
        XCTAssertEqual(state.imageUrl, otherUrl)

        // 写しは URL を引き継ぐ。
        XCTAssertEqual(state.copy().imageUrl, otherUrl)
    }
}
