import XCTest
@testable import MapConductorCore

/// 描いている途中で見捨てられたタイルに、こちらが気づけるか。
///
/// 気づけないと、地図が興味を失ったタイルを最後まで描き切る。1 枚なら些細だが、
/// ArcGIS の 3D は iPad の 1 画面に 119 枚を要求し、描画は 6 並列。**見られない
/// タイルが、見られるタイルの前に並ぶ**ぶんだけ画面が埋まるのが遅れる。
///
/// android-sdk はソケットを覗いて EOF を見る。iOS は `NWConnection` の
/// `state` を見ている——ここが本当に動くのかを固定するのがこのテスト。
final class LocalTileServerAbandonTests: XCTestCase {

    private let routeId = "abandon-test"
    private var server: LocalTileServer!

    override func setUp() {
        super.setUp()
        server = TileServerRegistry.get()
    }

    override func tearDown() {
        server.unregister(routeId: routeId)
        super.tearDown()
    }

    /// 描くのに時間がかかり、その間ずっと「まだ要る？」を聞き続けるプロバイダ。
    private final class SlowProvider: TileProvider, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _noticed = false
        private var _asked = 0

        /// 中断に気づいたか。
        var noticed: Bool {
            lock.lock(); defer { lock.unlock() }
            return _noticed
        }

        /// 何回聞いたか（0 なら、そもそも聞く前に終わっている）。
        var asked: Int {
            lock.lock(); defer { lock.unlock() }
            return _asked
        }

        func renderTile(request: TileRequest) -> Data? { nil }

        func renderTile(request: TileRequest, isCancelled: () -> Bool) throws -> Data? {
            started.signal()
            // 5 秒ぶん、20ms ごとに聞く。クライアントが切れた時点で気づけるなら
            // この間に true になるはず。
            for _ in 0..<250 {
                lock.lock()
                _asked += 1
                lock.unlock()
                if isCancelled() {
                    lock.lock(); _noticed = true; lock.unlock()
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return TransparentTile.png(size: 8)
        }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func cancel() {
            lock.lock(); value = true; lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private final class FixedProvider: TileProvider {
        let png: Data

        init(png: Data) { self.png = png }

        func renderTile(request: TileRequest) -> Data? { png }
    }

    private func tileURL() throws -> URL {
        let text = server.urlTemplate(routeId: routeId, tileSize: 256)
            .replacingOccurrences(of: "{z}", with: "10")
            .replacingOccurrences(of: "{x}", with: "1")
            .replacingOccurrences(of: "{y}", with: "2")
        return try XCTUnwrap(URL(string: text))
    }

    /// ArcGIS's CustomTiledLayer exposes real task cancellation, so the
    /// in-process route must pass it through to the provider immediately.
    func testDirectTileNoticesAuthoritativeCancellation() throws {
        let provider = SlowProvider()
        let flag = CancellationFlag()
        server.register(routeId: routeId, provider: provider)
        let url = try tileURL()
        let finished = expectation(description: "direct render stopped")

        DispatchQueue.global().async {
            let data = self.server.renderLocalTile(url: url) { flag.isCancelled }
            XCTAssertNil(data)
            finished.fulfill()
        }

        XCTAssertEqual(provider.started.wait(timeout: .now() + 10), .success)
        flag.cancel()
        wait(for: [finished], timeout: 1)
        XCTAssertTrue(provider.noticed)
        XCTAssertLessThan(provider.asked, 50, "キャンセル後も長く描画を続けた")
    }

    func testDirectTileReturnsProviderBytes() throws {
        let png = try XCTUnwrap(TransparentTile.png(size: 8))
        server.register(routeId: routeId, provider: FixedProvider(png: png))

        XCTAssertEqual(server.renderLocalTile(url: try tileURL()), png)
    }

    func testDirectTileRejectsAnotherServerURL() throws {
        server.register(
            routeId: routeId,
            provider: FixedProvider(png: try XCTUnwrap(TransparentTile.png(size: 8)))
        )

        let foreign = try XCTUnwrap(URL(string: "http://example.com/tiles/\(routeId)/256/10/1/2.png"))
        XCTAssertNil(server.renderLocalTile(url: foreign))
    }

    /**
     クライアントが途中で帰ったら、描くのをやめられること。

     **HTTP 経路は現状これを満たしていない。** `NWConnection` の `state` は
     **相手が閉じても変わらない**（自分が cancel したときと、エラーのときだけ）ので、
     リクエストを解析してから応答を書くまでの間、受信は 1 つも張られていない。
     結果、地図が見捨てたタイルも最後まで描き切る。

     ArcGIS だけはこの穴を迂回済み。`renderLocalTile` を `CustomTiledLayer` の
     クロージャから直接呼び、ArcGIS 自身のタスクキャンセルを権威として使う
     （`testDirectTileNoticesAuthoritativeCancellation` が固定している）。
     HTTP で読む他のプロバイダ（MapKit, Google Maps ほか）はまだこの穴の中にいる。

     描画中に受信を張って EOF を見る、という素直な直し方を試したところ**壊れた**:
     HTTP クライアントはリクエストを送り終えた時点で書き込み側を閉じることがあり、
     それが `isComplete` として即座に届く。「もう要らない」ではなく「送り終えた」
     なので、そこで接続を切ると応答を書く前に切ることになる（実機で 3 枚しか
     描けず地図が白くなった）。android がソケットを覗いているのは、この 2 つを
     区別するためだと思われる。

     直すまで期待値として記録しておく。消すとこの穴は誰にも見えなくなる。
     */
    func testNoticesAClientThatGaveUpMidRender() throws {
        XCTExpectFailure("見捨てられたタイルに気づけない。上の説明を参照")
        let provider = SlowProvider()
        server.register(routeId: routeId, provider: provider)

        let url = try tileURL()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: url) { _, _, _ in }
        task.resume()

        // 描き始めてから帰る。始まる前に切ると、中断ではなく「来なかった」に
        // なってしまい、確かめたいものが確かめられない。
        XCTAssertEqual(
            provider.started.wait(timeout: .now() + 10), .success,
            "プロバイダが呼ばれない"
        )
        task.cancel()

        // 気づくなら即座のはず。長めに待ってから判定する。
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !provider.noticed {
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertGreaterThan(provider.asked, 0, "isCancelled が一度も呼ばれていない")
        XCTAssertTrue(
            provider.noticed,
            "クライアントが帰ったのに描き続けている（\(provider.asked) 回聞いて一度も true にならない）"
        )
    }
}
