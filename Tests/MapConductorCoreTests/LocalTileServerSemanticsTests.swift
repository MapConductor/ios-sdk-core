import XCTest
@testable import MapConductorCore

/// サーバが「タイルが無い」理由をどう答えるか。
///
/// 3 通りあり、取り違えると画面に出る。地図 SDK は 404 を**恒久の答え**として
/// 覚えるので、一瞬だけ空だったタイル（データ取り込み中、レイヤ切り替えの最中）を
/// 404 で答えると二度と要求されず、隣のタイルのはみ出し分だけが残って穴の縁で
/// アイコンが半分に切れる。空は透明な絵、失敗は引き直せる 503、404 は
/// 「その名前のものは無い」ときだけ。
///
/// android-sdk-core の `LocalTileServerSemanticsTest` と同じ 4 点を見ている。
final class LocalTileServerSemanticsTests: XCTestCase {

    private let routeId = "semantics-test"
    private var server: LocalTileServer!

    /// キャッシュを持たないセッション。
    ///
    /// 共有セッションで撮ると、空タイルに付く `max-age=31536000` のせいで
    /// 2 本目以降が**前のテストの答え**を受け取る（実際に一度そうなった）。
    /// 見たいのはサーバが今なんと答えるかなので、毎回本当に聞きに行く。
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    override func setUp() {
        super.setUp()
        server = TileServerRegistry.get()
    }

    override func tearDown() {
        server.unregister(routeId: routeId)
        super.tearDown()
    }

    /// 空で nil を返すプロバイダ。geojson / kml / groundimage と同じ形。
    private final class EmptyProvider: TileProvider {
        func renderTile(request: TileRequest) -> Data? { nil }
    }

    /// 今は描けないプロバイダ。
    private final class FailingProvider: TileProvider {
        struct Failure: Error {}

        func renderTile(request: TileRequest) -> Data? { nil }

        func renderTile(request: TileRequest, isCancelled: () -> Bool) throws -> Data? {
            throw Failure()
        }
    }

    private final class FixedProvider: TileProvider {
        let png: Data

        init(png: Data) { self.png = png }

        func renderTile(request: TileRequest) -> Data? { png }
    }

    private struct Answer {
        let status: Int
        let headers: [AnyHashable: Any]
        let body: Data
    }

    /// タイルを 1 枚取りに行く。`urlTemplate` が返す URL をそのまま使う。
    private func fetch(z: Int, x: Int, y: Int, tileSize: Int = 512, retina: Bool = false) throws -> Answer {
        let template = server.urlTemplate(routeId: routeId, tileSize: tileSize)
        var text = template
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
        if retina {
            text = text.replacingOccurrences(of: ".png", with: "@2x.png")
        }
        let url = try XCTUnwrap(URL(string: text))

        var answer: Answer?
        let done = expectation(description: "tile \(text)")
        let task = session.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                answer = Answer(status: http.statusCode, headers: http.allHeaderFields, body: data ?? Data())
            }
            done.fulfill()
        }
        task.resume()
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(answer, "サーバが答えなかった")
    }

    private func header(_ answer: Answer, _ name: String) -> String? {
        for (key, value) in answer.headers where (key as? String)?.lowercased() == name.lowercased() {
            return value as? String
        }
        return nil
    }

    /// 登録されていないルートは「その名前のものは無い」。404 はここだけ。
    func testUnknownRouteIsNotFound() throws {
        let answer = try fetch(z: 10, x: 0, y: 0)
        XCTAssertEqual(answer.status, 404)
    }

    /// 空は本物の答え。透明な絵で 200。
    ///
    /// マーカーのレンダラだけでなく、空で nil を返すすべてのプロバイダに効く
    /// ことを確かめたいので、いちばん素朴なプロバイダで見る。
    func testEmptyTileIsATransparentPicture() throws {
        server.register(routeId: routeId, provider: EmptyProvider())
        let answer = try fetch(z: 10, x: 11, y: 12)
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(header(answer, "Content-Type"), "image/png")

        let image = try XCTUnwrap(UIImage(data: answer.body), "PNG として読めない")
        XCTAssertEqual(image.size.width, 512)
        XCTAssertEqual(image.size.height, 512)
        XCTAssertEqual(alpha(of: image, atX: 0, y: 0), 0, "隅が不透明")
        XCTAssertEqual(alpha(of: image, atX: 256, y: 256), 0, "中央が不透明")
    }

    /// @2x の URL には、その密度の透明タイルを返す。
    func testEmptyRetinaTileMatchesItsDensity() throws {
        server.register(routeId: routeId, provider: EmptyProvider())
        let answer = try fetch(z: 10, x: 21, y: 22, retina: true)
        XCTAssertEqual(answer.status, 200)
        let image = try XCTUnwrap(UIImage(data: answer.body))
        XCTAssertEqual(image.size.width, 1024)
    }

    /// 描けなかったタイルは 503。404 にすると穴が残り、200 にすると嘘が残る。
    func testRenderFailureIsRetryable() throws {
        server.register(routeId: routeId, provider: FailingProvider())
        let answer = try fetch(z: 10, x: 31, y: 32)
        XCTAssertEqual(answer.status, 503)
        XCTAssertEqual(header(answer, "Retry-After"), "1")
        XCTAssertEqual(header(answer, "Cache-Control"), "no-store")
    }

    /// 描けたタイルはそのまま返る（上の 3 つが偶然通っていないことの確認）。
    func testRenderedTileIsServedAsIs() throws {
        let png = try XCTUnwrap(TransparentTile.png(size: 8))
        server.register(routeId: routeId, provider: FixedProvider(png: png))
        let answer = try fetch(z: 10, x: 41, y: 42)
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.body, png)
    }

    private func alpha(of image: UIImage, atX x: Int, y: Int) -> Int {
        guard let cgImage = image.cgImage else { return -1 }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return Int(pixel[3])
    }
}
