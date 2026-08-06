import XCTest

@testable import MapConductorCore

/// ラスタタイルのヘッダ規則を、**宛先ホスト単位**で持つという約束を固定する。
///
/// MapLibre 系のフックはプロセス全体に 1 つしか無いので、ホストで絞れていないと
/// ラスタレイヤ用のヘッダがベースマップの取得にも載る。ここが緩むと静かに漏れる。
final class RasterHeaderRuleSetTests: XCTestCase {
    private func state(
        template: String,
        userAgent: String = RasterLayerState.defaultUserAgent,
        extraHeaders: [String: String]? = nil,
        id: String = "layer"
    ) -> RasterLayerState {
        RasterLayerState(
            source: .urlTemplate(template: template),
            userAgent: userAgent,
            extraHeaders: extraHeaders,
            id: id
        )
    }

    func testMakeRulesExtractsHostAndPortFromTemplate() {
        let rules = RasterHeaderRuleSet.makeRules(
            from: [state(template: "https://tiles.example.com:8443/{z}/{x}/{y}.png")]
        )

        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].host, "tiles.example.com")
        XCTAssertEqual(rules[0].port, 8443)
    }

    /// `{z}` を含んだままだと URL として解釈できないことがある。切ってからホストを取る。
    func testMakeRulesHandlesTemplateWithoutPort() {
        let rules = RasterHeaderRuleSet.makeRules(
            from: [state(template: "https://tiles.example.com/{z}/{x}/{y}.png")]
        )

        XCTAssertEqual(rules[0].host, "tiles.example.com")
        XCTAssertNil(rules[0].port)
    }

    /// ヘッダ指定が何も無い状態は規則を作らない。作ると無駄にフックが載る。
    func testMakeRulesSkipsStateWithoutAnyHeader() {
        let rules = RasterHeaderRuleSet.makeRules(
            from: [state(template: "https://tiles.example.com/{z}/{x}/{y}.png", userAgent: "  ")]
        )

        XCTAssertTrue(rules.isEmpty)
    }

    func testHeadersMatchOnlyTheDeclaredHost() {
        let set = RasterHeaderRuleSet()
        let owner = NSObject()
        set.setRules(
            RasterHeaderRuleSet.makeRules(from: [
                state(
                    template: "https://tiles.example.com/{z}/{x}/{y}.png",
                    userAgent: "Probe/1.0",
                    extraHeaders: ["X-Token": "abc"]
                )
            ]),
            owner: owner
        )

        let hit = set.headers(for: URL(string: "https://tiles.example.com/3/1/2.png")!)
        XCTAssertEqual(hit?.userAgent, "Probe/1.0")
        XCTAssertEqual(hit?.extraHeaders["X-Token"], "abc")

        // ベースマップが別ホストなら載らない。ここが漏れると地図全体の UA が変わる。
        XCTAssertNil(set.headers(for: URL(string: "https://basemap.example.org/style.json")!))
    }

    /// ポートを明示した規則は、そのポート宛にだけ載る。
    func testHeadersRespectPort() {
        let set = RasterHeaderRuleSet()
        set.setRules(
            RasterHeaderRuleSet.makeRules(from: [
                state(template: "http://127.0.0.1:9000/{z}/{x}/{y}.png", userAgent: "Probe/1.0")
            ]),
            owner: NSObject()
        )

        XCTAssertNotNil(set.headers(for: URL(string: "http://127.0.0.1:9000/1/0/0.png")!))
        XCTAssertNil(set.headers(for: URL(string: "http://127.0.0.1:9001/1/0/0.png")!))
    }

    /// 地図が複数あっても互いの規則を消さない。登録元ごとに分けて持つ。
    func testRulesAreScopedPerOwner() {
        let set = RasterHeaderRuleSet()
        let first = NSObject()
        let second = NSObject()

        set.setRules(
            RasterHeaderRuleSet.makeRules(from: [
                state(template: "https://a.example.com/{z}/{x}/{y}.png", userAgent: "A/1.0", id: "a")
            ]),
            owner: first
        )
        set.setRules(
            RasterHeaderRuleSet.makeRules(from: [
                state(template: "https://b.example.com/{z}/{x}/{y}.png", userAgent: "B/1.0", id: "b")
            ]),
            owner: second
        )

        XCTAssertEqual(set.headers(for: URL(string: "https://a.example.com/1/0/0.png")!)?.userAgent, "A/1.0")
        XCTAssertEqual(set.headers(for: URL(string: "https://b.example.com/1/0/0.png")!)?.userAgent, "B/1.0")

        set.removeRules(owner: first)
        XCTAssertNil(set.headers(for: URL(string: "https://a.example.com/1/0/0.png")!))
        XCTAssertEqual(set.headers(for: URL(string: "https://b.example.com/1/0/0.png")!)?.userAgent, "B/1.0")
    }

    /// 全部外れたら空になる。フックを外してよい合図。
    func testIsEmptyReflectsRegistrations() {
        let set = RasterHeaderRuleSet()
        let owner = NSObject()
        XCTAssertTrue(set.isEmpty)

        set.setRules(
            RasterHeaderRuleSet.makeRules(from: [
                state(template: "https://a.example.com/{z}/{x}/{y}.png", userAgent: "A/1.0")
            ]),
            owner: owner
        )
        XCTAssertFalse(set.isEmpty)

        set.removeRules(owner: owner)
        XCTAssertTrue(set.isEmpty)
    }
}
