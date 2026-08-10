import XCTest

@testable import MapConductorCore

/// ``WebMercatorZoomAltitudeConverter`` が移行前の各プロバイダ実装と**1 ビットも違わない**
/// ことを検証する。
///
/// `ZoomAltitudeConverter.swift` は 7 プロバイダでほぼ同一（差はズームオフセットだけ）
/// だったので、コアの 1 本にまとめた。ただしズーム換算のズレは
/// **目視では絶対に見つからない回帰**（高緯度で縮尺がわずかに違う、程度にしか見えない）
/// なので、移行前の実装が返した値を表として採取し、それに対して固定する。
///
/// リソース `zoom-golden.txt` は移行前（2026-08-10）の ios-for-* の converter を
/// **1 文字も変えずにコンパイルして走らせ**採取したもの。
/// zoom 8 点 × 緯度 8 点 × tilt 5 点 = 320 点 × 7 プロバイダ。
/// android-sdk の同名テストと同じ格子・同じ形式で、値も一致する
/// （較正定数が同じプロバイダについては、という意味。ArcGIS は違う。後述）。
///
/// ## HERE と ArcGIS を含めていない理由
///
/// この 2 つは**式が本質的に違う**のでコアの実装に寄せていない。
///  - HERE: 緯度の ±85° クランプと tilt の [0,90] クランプが無い。高緯度で値が分岐する。
///  - ArcGIS: viewport 高さでスケールする独自式。しかも `zoom0Altitude` が
///    iOS 141,600,000 / Android・React 136,500,000 と**プラットフォームで違う**。
/// 自前実装のまま残すこと。
///
/// ## ★ Mapbox だけは意図的に値が変わっている
///
/// 移行前の `MapboxZoomAltitudeConverter` は `mapboxZoomToGoogleZoom` を宣言しながら
/// 換算の中で使っておらず、実質オフセット 0 で動いていた（呼び出し側はネイティブズームを
/// 渡すので、+1 が抜けたぶん高度が 2 倍）。android-for-mapbox と ios-for-maplibre は
/// どちらも +1 を当てているので、**iOS の Mapbox だけがずれていた**。android に合わせて直した。
///
/// そのため mapbox は完全一致の対象から外し、
/// ``testMapboxOffsetWasNotAppliedBeforeTheMigration`` で
/// 「旧＝オフセット 0 / 新＝オフセット 1」の両方を固定している。
final class ZoomAltitudeConverterGoldenTests: XCTestCase {
    /// 完全一致を要求するプロバイダ。mapbox は上記の理由で外してある。
    private static let unchangedProviders: Set<String> = [
        "googlemaps", "mapkit", "longdo", "maplibre", "maptiler", "tomtom",
    ]

    /// 移行前の各プロバイダの構成。ここが実装との唯一の対応表。
    private func converter(for provider: String) throws -> ZoomAltitudeConverterProtocol {
        switch provider {
        // 256px タイル基準。ネイティブズーム == 統一ズーム。
        case "googlemaps", "mapkit", "longdo":
            return WebMercatorZoomAltitudeConverter(zoomOffset: 0.0)
        // 512px タイルのベクタエンジン。統一ズーム = ネイティブズーム + 1。
        case "maplibre", "mapbox", "maptiler":
            return WebMercatorZoomAltitudeConverter(zoomOffset: 1.0)
        // グラウンドスケール基準。オフセットが緯度依存。
        case "tomtom":
            return GroundScaleZoomAltitudeConverter(baseZoomOffset: 1.76)
        default:
            throw XCTSkip("未知のプロバイダ: \(provider)")
        }
    }

    private struct Row {
        let provider: String
        let zoom: Double
        let latitude: Double
        let tilt: Double
        let altitude: Double
        let roundTrip: Double
    }

    private func goldenRows() throws -> [Row] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "zoom-golden", withExtension: "txt"),
            "zoom-golden.txt が見つかりません"
        )
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .map { line in
                let f = line.split(separator: "|", omittingEmptySubsequences: false)
                return Row(
                    provider: String(f[0]),
                    zoom: Double(f[1])!,
                    latitude: Double(f[2])!,
                    tilt: Double(f[3])!,
                    altitude: Double(f[4])!,
                    roundTrip: Double(f[5])!
                )
            }
    }

    func testGoldenTableHasTheExpectedShape() throws {
        let rows = try goldenRows()
        XCTAssertEqual(rows.count, 2240, "7 プロバイダ x 320 点")
        XCTAssertEqual(Set(rows.map(\.provider)).count, 7)
    }

    func testZoomLevelToAltitudeMatchesThePreMigrationValues() throws {
        var failures: [String] = []
        for row in try goldenRows() where Self.unchangedProviders.contains(row.provider) {
            let actual = try converter(for: row.provider)
                .zoomLevelToAltitude(zoomLevel: row.zoom, latitude: row.latitude, tilt: row.tilt)
            // 丸め誤差の許容ではなく完全一致を要求する。式を 1 本にまとめただけなので、
            // 差が出たらそれは実装の変化であって数値誤差ではない。
            if actual != row.altitude {
                failures.append(
                    "\(row.provider) z=\(row.zoom) lat=\(row.latitude) tilt=\(row.tilt): "
                        + "expected=\(row.altitude) actual=\(actual)"
                )
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "移行前と値が変わった箇所が \(failures.count) 件:\n" + failures.prefix(10).joined(separator: "\n")
        )
    }

    func testAltitudeToZoomLevelMatchesThePreMigrationValues() throws {
        var failures: [String] = []
        for row in try goldenRows() where Self.unchangedProviders.contains(row.provider) {
            let actual = try converter(for: row.provider)
                .altitudeToZoomLevel(altitude: row.altitude, latitude: row.latitude, tilt: row.tilt)
            if actual != row.roundTrip {
                failures.append(
                    "\(row.provider) alt=\(row.altitude) lat=\(row.latitude) tilt=\(row.tilt): "
                        + "expected=\(row.roundTrip) actual=\(actual)"
                )
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "移行前と値が変わった箇所が \(failures.count) 件:\n" + failures.prefix(10).joined(separator: "\n")
        )
    }

    /// Mapbox の意図的な変更を両側から固定する。
    ///
    /// これが落ちたら、どちらかを勝手に変えたということ。落ちた側を読むこと:
    ///  - 前半が落ちた → ゴールデン表を書き換えた（履歴の改竄）。
    ///  - 後半が落ちた → 直したはずのオフセットがまた外れた。
    func testMapboxOffsetWasNotAppliedBeforeTheMigration() throws {
        let old = WebMercatorZoomAltitudeConverter(zoomOffset: 0.0) // 移行前の実質の挙動
        let new = WebMercatorZoomAltitudeConverter(zoomOffset: 1.0) // android と揃えた挙動

        var rows = 0
        for row in try goldenRows() where row.provider == "mapbox" {
            rows += 1
            XCTAssertEqual(
                old.zoomLevelToAltitude(zoomLevel: row.zoom, latitude: row.latitude, tilt: row.tilt),
                row.altitude,
                "移行前の mapbox はオフセット 0 で動いていた: z=\(row.zoom) lat=\(row.latitude) tilt=\(row.tilt)"
            )
        }
        XCTAssertEqual(rows, 320)

        // 直した後は maplibre / maptiler と同じ値になる。
        for zoom in [0.0, 5.0, 10.0, 18.0] {
            for lat in [-60.0, 0.0, 35.7] {
                XCTAssertEqual(
                    new.zoomLevelToAltitude(zoomLevel: zoom, latitude: lat, tilt: 0.0),
                    WebMercatorZoomAltitudeConverter(zoomOffset: 1.0)
                        .zoomLevelToAltitude(zoomLevel: zoom, latitude: lat, tilt: 0.0)
                )
                // 旧実装との差はちょうど 2 倍（クランプに掛からない範囲で）。
                let oldValue = old.zoomLevelToAltitude(zoomLevel: zoom, latitude: lat, tilt: 0.0)
                let newValue = new.zoomLevelToAltitude(zoomLevel: zoom, latitude: lat, tilt: 0.0)
                if oldValue < AbstractZoomAltitudeConverter.maxAltitude {
                    XCTAssertEqual(oldValue / newValue, 2.0, accuracy: 1e-9, "zoom=\(zoom) lat=\(lat)")
                }
            }
        }
    }

    // ── 性質テスト（ゴールデン表とは独立に式の健全性を押さえる） ──────────

    func testRoundTripOutsideTheClampRange() {
        let converter = WebMercatorZoomAltitudeConverter(zoomOffset: 1.0)
        for zoom in [2.0, 5.0, 10.0, 14.0, 18.0] {
            for lat in [-60.0, 0.0, 35.7, 60.0] {
                let altitude = converter.zoomLevelToAltitude(zoomLevel: zoom, latitude: lat, tilt: 0.0)
                let back = converter.altitudeToZoomLevel(altitude: altitude, latitude: lat, tilt: 0.0)
                XCTAssertEqual(back, zoom, accuracy: 1e-9, "zoom=\(zoom) lat=\(lat)")
            }
        }
    }

    func testAltitudeDecreasesMonotonicallyWithZoom() {
        let converter = WebMercatorZoomAltitudeConverter(zoomOffset: 0.0)
        var previous = Double.greatestFiniteMagnitude
        for zoom in 1 ... 20 {
            let altitude = converter.zoomLevelToAltitude(
                zoomLevel: Double(zoom),
                latitude: 35.7,
                tilt: 0.0
            )
            XCTAssertLessThan(altitude, previous, "zoom=\(zoom) で単調減少が崩れた")
            previous = altitude
        }
    }

    func testTiltOf90DoesNotDiverge() {
        let converter = WebMercatorZoomAltitudeConverter(zoomOffset: 0.0)
        let altitude = converter.zoomLevelToAltitude(zoomLevel: 10.0, latitude: 0.0, tilt: 90.0)
        XCTAssertTrue(altitude.isFinite)
        XCTAssertGreaterThanOrEqual(altitude, AbstractZoomAltitudeConverter.minAltitude)
    }

    func testNearThePolesDoesNotDiverge() {
        let converter = WebMercatorZoomAltitudeConverter(zoomOffset: 0.0)
        for lat in [-90.0, -89.9, 89.9, 90.0] {
            let altitude = converter.zoomLevelToAltitude(zoomLevel: 10.0, latitude: lat, tilt: 0.0)
            XCTAssertTrue(altitude.isFinite && altitude > 0.0, "lat=\(lat)")
        }
    }

    func testOffsetRoundTripsBetweenUnifiedAndNativeZoom() {
        let converter = WebMercatorZoomAltitudeConverter(zoomOffset: 1.0)
        XCTAssertEqual(converter.toUnifiedZoom(10.0), 11.0, accuracy: 1e-12)
        XCTAssertEqual(converter.toNativeZoom(11.0), 10.0, accuracy: 1e-12)
    }

    func testGroundScaleOffsetDependsOnLatitude() {
        let converter = GroundScaleZoomAltitudeConverter(baseZoomOffset: 1.76)
        let atEquator = converter.toUnifiedZoom(10.0, latitude: 0.0)
        let atHighLat = converter.toUnifiedZoom(10.0, latitude: 60.0)
        // cos(60°) = 0.5 なので log2 で -1.0 ぶんずれる。
        XCTAssertEqual(atEquator, 11.76, accuracy: 1e-9)
        XCTAssertEqual(atHighLat, 10.76, accuracy: 1e-9)
    }
}
