import UIKit
import XCTest

@testable import MapConductorCore

/// ポリラインのタップ判定（`PolylineManager.find`）。タイルでもネイティブでも同じ。
///
/// - 許容距離 = 指の大きさ（`Settings.Default.tapTolerance`）＋ 線幅の半分。どちらも pt × 画面の倍率で
///   画素にしてから、そのズームの 1 画素の長さを掛ける（既存の換算）。太い線は縁から指の大きさ以内であたる。
/// - 複数あたれば中心線が一番近い線。返す点は線上の最近点。
/// - 外接矩形で先に間引いても、結果は全部の線を調べた場合と同じ。5 万本でも 1 タップが速い。
///
/// iOS の `PolylineState` には `clickable` が無い（web / Android の「clickable=false は素通り」に当たるテストは無い）。
/// js-sdk-core の `PolylineHit.test.mjs`、android-sdk の `PolylineHitTest` と同じ内容。
final class PolylineHitToleranceTests: XCTestCase {
    private let lat = 42.3555, lng = -71.0605, zoom = 16.0
    private let metersPerDegLat = 111_132.954

    private var camera: MapCameraPosition {
        MapCameraPosition(position: GeoPoint(latitude: lat, longitude: lng), zoom: zoom, bearing: 0, tilt: 0, paddings: nil)
    }

    /// The tolerance in metres for a line `width` pt wide, as the manager computes it.
    private func tolerance(width: Double) -> Double {
        let scale = max(1.0, Double(UIScreen.main.scale))
        return calculateMetersPerPixel(latitude: lat, zoom: zoom) * (Double(Settings.Default.tapTolerance) + width / 2) * scale
    }

    private func horizontal(_ id: String, northMeters: Double = 0, width: Double) -> PolylineState {
        let dLat = northMeters / metersPerDegLat
        return PolylineState(
            points: [GeoPoint(latitude: lat + dLat, longitude: lng - 0.002), GeoPoint(latitude: lat + dLat, longitude: lng + 0.002)],
            id: id,
            strokeWidth: width
        )
    }

    private func manager(_ states: [PolylineState]) -> PolylineManager<Void> {
        let manager = PolylineManager<Void>()
        for state in states { manager.registerEntity(PolylineEntity<Void>(polyline: nil, state: state)) }
        return manager
    }

    private func north(_ meters: Double) -> GeoPoint {
        GeoPoint(latitude: lat + meters / metersPerDegLat, longitude: lng)
    }

    func testAWideLineIsHitWithinAFingerOfItsEdge() {
        let wide = manager([horizontal("wide", width: 20)])
        let t = tolerance(width: 20)
        XCTAssertEqual(wide.find(position: north(t * 0.95), cameraPosition: camera)?.entity.state.id, "wide")
        XCTAssertNil(wide.find(position: north(t * 1.05), cameraPosition: camera))
        // A hairline at the same distance is missed: the extra is half the width.
        let thin = manager([horizontal("thin", width: 0)])
        XCTAssertNil(thin.find(position: north(t * 0.95), cameraPosition: camera))
        XCTAssertNotNil(thin.find(position: north(tolerance(width: 0) * 0.95), cameraPosition: camera))
    }

    func testAThinLineIsHitAsBefore() {
        // 1–5 pt: the finger dominates; the line adds at most 2.5 pt.
        let t1 = tolerance(width: 1), t0 = tolerance(width: 0)
        XCTAssertLessThan((t1 - t0) / t0, 0.05)
        XCTAssertNotNil(manager([horizontal("a", width: 1)]).find(position: north(t1 * 0.99), cameraPosition: camera))
    }

    func testTheNearestLineWinsAndItsClosestPointIsReturned() throws {
        let t = tolerance(width: 4)
        let m = manager([
            horizontal("far", northMeters: t * 0.8, width: 4),
            horizontal("near", northMeters: -t * 0.3, width: 4),
        ])
        let hit = try XCTUnwrap(m.find(position: north(0), cameraPosition: camera))
        XCTAssertEqual(hit.entity.state.id, "near")
        XCTAssertEqual(hit.closestPoint.latitude, lat - t * 0.3 / metersPerDegLat, accuracy: 1e-7)
        XCTAssertEqual(hit.closestPoint.longitude, lng, accuracy: 1e-7)
    }

    func testTheBoxPrefilterChangesNothing() {
        // 5,000 本の短い線を格子に並べ、500 か所のタップを、間引きなしで全部の線を調べた答えと比べる。
        var states: [PolylineState] = []
        for i in 0..<5_000 {
            let la = 42.30 + Double(i / 100) * 0.0004, ln = -71.10 + Double(i % 100) * 0.0004
            states.append(PolylineState(
                points: [GeoPoint(latitude: la, longitude: ln), GeoPoint(latitude: la + 0.0002, longitude: ln + 0.0003)],
                id: "s\(i)",
                strokeWidth: Double(i % 7)
            ))
        }
        let m = manager(states)
        var rng = SystemRandomNumberGenerator()
        let cam = MapCameraPosition(position: GeoPoint(latitude: 42.31, longitude: -71.08), zoom: 17, bearing: 0, tilt: 0, paddings: nil)
        let scale = max(1.0, Double(UIScreen.main.scale))
        for _ in 0..<500 {
            let tap = GeoPoint(latitude: 42.30 + Double.random(in: -0.001...0.021, using: &rng),
                               longitude: -71.10 + Double.random(in: -0.001...0.041, using: &rng))
            let mpp = calculateMetersPerPixel(latitude: tap.latitude, zoom: 17)
            var best: (String, Double)?
            for state in states {
                let threshold = mpp * (Double(Settings.Default.tapTolerance) + state.strokeWidth / 2) * scale
                if let hit = Planar.pointOnLineOrNull(from: state.points[0], to: state.points[1], position: tap, thresholdMeters: threshold),
                   best == nil || hit.1 < best!.1 {
                    best = (state.id, hit.1)
                }
            }
            XCTAssertEqual(m.find(position: tap, cameraPosition: cam)?.entity.state.id, best?.0, "tap \(tap.latitude),\(tap.longitude)")
        }
    }

    func testGeodesicAndVeryWideLinesAreStillFound() {
        let geodesic = PolylineState(
            points: [GeoPoint(latitude: lat, longitude: lng - 0.002), GeoPoint(latitude: lat, longitude: lng + 0.002)],
            id: "g", geodesic: true
        )
        let wide = PolylineState(
            points: [GeoPoint(latitude: 10, longitude: -120), GeoPoint(latitude: 10, longitude: 100)],
            id: "w"
        )
        let m = manager([geodesic, wide])
        XCTAssertEqual(m.find(position: north(tolerance(width: 1) * 0.5), cameraPosition: camera)?.entity.state.id, "g")
    }

    func testATapAmongFiftyThousandLinesIsQuick() {
        // ボストンの道路と同じ桁: 5 万本・各 4 点。
        var states: [PolylineState] = []
        states.reserveCapacity(50_000)
        for i in 0..<50_000 {
            let la = 42.23 + Double(i / 250) * 0.0007, ln = -71.19 + Double(i % 250) * 0.0007
            states.append(PolylineState(
                points: (0..<4).map { GeoPoint(latitude: la + Double($0) * 0.0001, longitude: ln + Double($0) * 0.0001) },
                id: "r\(i)",
                strokeWidth: 2
            ))
        }
        let m = manager(states)
        let cam = MapCameraPosition(position: GeoPoint(latitude: 42.3, longitude: -71.1), zoom: 17, bearing: 0, tilt: 0, paddings: nil)
        let target = states[25_123].points[1]
        // The first read of the screen scale in a test bundle without an app takes seconds; not a tap's cost.
        _ = UIScreen.main.scale
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 {
            XCTAssertEqual(m.find(position: target, cameraPosition: cam)?.entity.state.id, "r25123")
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / 10
        XCTAssertLessThan(ms, 60, String(format: "%.1f ms per tap", ms))
    }
}
