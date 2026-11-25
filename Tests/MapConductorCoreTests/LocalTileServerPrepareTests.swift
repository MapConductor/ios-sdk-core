import XCTest
@testable import MapConductorCore

/// データ待ちのタイルが、描画レーンを塞がないか。
///
/// レーンは CPU 用に数本しかない。ネットワークを待つタイルがそこに座ると、端末に
/// あるデータですぐ描けるタイルまで後ろに並ぶ。`prepareTile` はレーンの外で
/// 呼ばれるので、待っているタイルが何枚あっても、すぐ描けるタイルはすぐ返る。
final class LocalTileServerPrepareTests: XCTestCase {
    private var server: LocalTileServer!
    private let waitingRoute = "prepare-test-waiting"
    private let readyRoute = "prepare-test-ready"

    override func setUp() {
        super.setUp()
        server = TileServerRegistry.get()
    }

    override func tearDown() {
        server.unregister(routeId: waitingRoute)
        server.unregister(routeId: readyRoute)
        super.tearDown()
    }

    /// 準備で 2 秒待ち（遅い回線の代わり）、描くのは一瞬。
    private final class WaitingProvider: TileProvider, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)

        func renderTile(request: TileRequest) -> Data? { TransparentTile.png(size: 8) }

        func prepareTile(request: TileRequest, isCancelled: () -> Bool) {
            _ = release.wait(timeout: .now() + 2)
        }
    }

    private final class ReadyProvider: TileProvider {
        func renderTile(request: TileRequest) -> Data? { TransparentTile.png(size: 8) }
    }

    func testTilesWaitingForDataDoNotHoldBackATileThatIsReady() throws {
        let waiting = WaitingProvider()
        server.register(routeId: waitingRoute, provider: waiting)
        server.register(routeId: readyRoute, provider: ReadyProvider())
        defer { for _ in 0..<64 { waiting.release.signal() } }

        // レーンの幅（最大 8）より多く。
        let group = DispatchGroup()
        for x in 0..<12 {
            group.enter()
            DispatchQueue.global().async { [server, waitingRoute] in
                defer { group.leave() }
                let template = server!.urlTemplate(routeId: waitingRoute, tileSize: 256, cacheKey: "k")
                let url = URL(string: template.replacingOccurrences(of: "{z}", with: "4")
                    .replacingOccurrences(of: "{x}", with: "\(x)").replacingOccurrences(of: "{y}", with: "0"))!
                _ = server!.renderLocalTile(url: url)
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        let template = server.urlTemplate(routeId: readyRoute, tileSize: 256, cacheKey: "k")
        let url = URL(string: template.replacingOccurrences(of: "{z}", with: "0")
            .replacingOccurrences(of: "{x}", with: "0").replacingOccurrences(of: "{y}", with: "0"))!
        let started = Date()
        XCTAssertNotNil(server.renderLocalTile(url: url))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "a ready tile waited behind tiles waiting for data")
        group.wait()
    }
}
