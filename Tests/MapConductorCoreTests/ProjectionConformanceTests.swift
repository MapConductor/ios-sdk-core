import XCTest

@testable import MapConductorCore

/// Web Mercator の適合テスト。
///
/// 同じ `projection-vectors.txt` を android-sdk / react-sdk も読む。3 つが同じ
/// 答えを出すことを担保するのが目的で、ここが見ているのはこのプラットフォームの
/// 分だけ。突き合わせは 3 つの出力に対して別途行う。
///
/// `zoom-golden.txt` とは役割が違う。あちらは移行前の値の記録（既知の不具合込み）。
/// こちらは現在の実装どうしが一致しているかを見る。
final class ProjectionConformanceTests: XCTestCase {

    /// 桁を固定する。
    ///
    /// 言語ごとの既定の数値表記は揃わない。f64 のノイズより粗く、実装差より細かい
    /// 桁で切る。
    private func fixed(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value == .infinity { return "inf" }
        if value == -.infinity { return "-inf" }
        return String(format: "%.6f", value)
    }

    private func runVectors() throws -> String {
        guard let url = Bundle.module.url(forResource: "projection-vectors", withExtension: "txt") else {
            XCTFail("projection-vectors.txt が見つからない")
            return ""
        }
        let projection = WebMercatorProjection()
        var out = ""
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            let row = line.trimmingCharacters(in: .whitespaces)
            if row.isEmpty || row.hasPrefix("#") { continue }
            let parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let (op, a, b) = (parts[0], parts[1], parts[2])
            switch op {
            case "project":
                let p = projection.project(GeoPoint(latitude: Double(a)!, longitude: Double(b)!))
                out += "project|\(a)|\(b)|\(fixed(p.x))|\(fixed(p.y))\n"
            case "unproject":
                let g = projection.unproject(CGPoint(x: Double(a)!, y: Double(b)!))
                out += "unproject|\(a)|\(b)|\(fixed(g.latitude))|\(fixed(g.longitude))\n"
            default:
                XCTFail("未知の演算: \(op)")
            }
        }
        return out
    }

    func testVectorsAllRun() throws {
        let actual = try runVectors()

        // 突き合わせに使う。テストの副産物ではなく、これが成果物。
        // シミュレータのサンドボックス内なので、ログにも出して外から拾えるようにする。
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("projection-actual.ios.txt")
        try actual.write(to: destination, atomically: true, encoding: .utf8)
        print("CONFORMANCE_BEGIN")
        print(actual, terminator: "")
        print("CONFORMANCE_END")

        let rows = actual.split(separator: "\n").map(String.init)
        XCTAssertFalse(rows.isEmpty, "ベクタが 1 行も処理されていない")
        for row in rows {
            XCTAssertEqual(row.split(separator: "|").count, 5, "列数が合わない: \(row)")
        }
    }

    /// 正本が決まるまでは存在しない。3 プラットフォームの差を潰してから凍結する。
    func testMatchesCanonicalIfPresent() throws {
        guard let url = Bundle.module.url(forResource: "projection-expected", withExtension: "txt") else {
            throw XCTSkip("正本がまだない")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), try runVectors())
    }
}
