import XCTest

@testable import MapConductorCore

/// geocell の適合テスト。
///
/// 同じ `geocell-vectors.txt` を android-sdk / react-sdk も読む。3 つが同じセルを
/// 名指すことを担保するのが目的で、ここが見ているのはこのプラットフォームの分だけ。
///
/// `ProjectionConformanceTests` と同じ作りにしてある。違うのは中身ではなく、
/// **なぜ文字列で比べるか**のほう。投影は 3 つとも Double を返すので桁を丸めれば
/// 済むが、セルの鍵は Long / Int64 / number と型が違う。JS の `number` は 53 ビット
/// までしか整数を持てず、ビット演算にいたっては 32 ビットに丸められる。数値を
/// そのまま突き合わせると、揃っていないのか表現が違うだけなのか区別できない。
/// 0123456789abcdef の文字列にしてしまえば、その問いは消える。
final class GeocellConformanceTests: XCTestCase {

    private func runVectors() throws -> String {
        guard let url = Bundle.module.url(forResource: "geocell-vectors", withExtension: "txt") else {
            XCTFail("geocell-vectors.txt が見つからない")
            return ""
        }
        var out = ""
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            let row = line.trimmingCharacters(in: .whitespaces)
            if row.isEmpty || row.hasPrefix("#") { continue }
            let parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            switch parts[0] {
            case "geocell":
                let text = MarkerGrid.geocell(
                    latitude: Double(parts[1])!,
                    longitude: Double(parts[2])!,
                    characters: Int(parts[3])!
                )
                out += "geocell|\(parts[1])|\(parts[2])|\(parts[3])|\(text)\n"
            case "level":
                let level = MarkerGrid.level(forSeparation: Double(parts[1])!)
                out += "level|\(parts[1])|\(level.map(String.init) ?? "none")\n"
            case "cell":
                let level = Int64(parts[3])!
                let lat = MarkerGrid.latCell(Double(parts[1])!, level: level)
                let lon = MarkerGrid.lonCell(Double(parts[2])!, level: level)
                out += "cell|\(parts[1])|\(parts[2])|\(parts[3])|\(lat),\(lon)\n"
            case "qlevel":
                let level = MarkerGrid.queryLevel(latSpan: Double(parts[1])!, lonSpan: Double(parts[2])!)
                out += "qlevel|\(parts[1])|\(parts[2])|\(level)\n"
            case "colwalk":
                let level = Int64(parts[3])!
                let span = MarkerGrid.eastwardSpan(from: Double(parts[1])!, to: Double(parts[2])!)
                let walk = MarkerGrid.columnWalk(from: Double(parts[1])!, spanning: span, level: level)
                out += "colwalk|\(parts[1])|\(parts[2])|\(parts[3])|\(walk.start),\(walk.count)\n"
            case "morton":
                let key = MarkerGrid.morton(
                    Int64(parts[1])!, Int64(parts[2])!, level: Int64(parts[3])!
                )
                out += "morton|\(parts[1])|\(parts[2])|\(parts[3])|\(key)\n"
            default:
                XCTFail("未知の演算: \(parts[0])")
            }
        }
        return out
    }

    func testVectorsAllRun() throws {
        let actual = try runVectors()

        // 突き合わせに使う。テストの副産物ではなく、これが成果物。
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("geocell-actual.ios.txt")
        try actual.write(to: destination, atomically: true, encoding: .utf8)
        print("GEOCELL_CONFORMANCE_BEGIN")
        print(actual, terminator: "")
        print("GEOCELL_CONFORMANCE_END")

        XCTAssertFalse(actual.split(separator: "\n").isEmpty, "ベクタが 1 行も処理されていない")
    }

    func testMatchesCanonicalIfPresent() throws {
        guard let url = Bundle.module.url(forResource: "geocell-expected", withExtension: "txt") else {
            throw XCTSkip("正本がまだない")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), try runVectors())
    }

    /// 深い段の答えは、浅い段の答えを接頭辞に持つ。
    ///
    /// 索引が階層として働く条件そのもので、これが崩れていると「粗いセルの
    /// マーカーは連続している」という前提が外れ、範囲クエリが静かに取りこぼす。
    func testDeeperCellsExtendShallowerOnes() {
        for (latitude, longitude) in [(35.681236, 139.767125), (-33.86882, 151.20929), (0.0, 0.0)] {
            var previous = ""
            for characters in 1...10 {
                let text = MarkerGrid.geocell(latitude: latitude, longitude: longitude, characters: characters)
                XCTAssertEqual(text.count, characters)
                XCTAssertTrue(text.hasPrefix(previous), "\(text) が \(previous) を接頭辞に持たない")
                previous = text
            }
        }
    }
}
