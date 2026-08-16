import Foundation

/// カメラ移動の中心とズームを補間する「滑らかで効率的なズーム」
/// （van Wijk & Nuij 2003）。MapLibre GL JS / gl-native の `flyTo` と同じ式。
///
/// ## ★ なぜ固定のサインアークではだめなのか
///
/// 以前は各プロバイダの `CameraAnimator` が
/// `zoom = lerp(z0, z1, t) - 2.5 * sin(π t)` という**距離に依らない**固定アークを
/// 掛けていた。長距離の移動でタイル読み込みが追いつかない問題は隠せるが、
/// **短い移動でも必ず 2.5 段ズームアウトしてから戻る。**
/// クラスターをタップして `+2` ズームするだけの操作で、中間が
/// `z + 1 - 2.5 = z - 1.5` になり、**一瞬引いてから寄る**という挙動になっていた
/// （実機で報告された症状）。
///
/// ## Android 対向はどれも van Wijk だった
///
/// 「MapTiler だけ Android が flyTo で、maplibre / mapbox / mappls の対向は素の ease
/// だからアークを外すのが正解」と一度判断したが、**それは誤りだった。**
/// 実際に確かめた対向実装は次のとおりで、4 本とも van Wijk に行き着く。
///
/// | | Android 側の呼び出し | 実体 |
/// |---|---|---|
/// | maptiler | `MTMapViewController.flyTo` | MapLibre GL JS の `flyTo` |
/// | maplibre | `map.animateCamera(update, duration)` | `Transform.animateCamera` → `NativeMap.flyTo` |
/// | mappls   | `map.animateCamera(update, duration)` | 同上（mappls-android-sdk 9.0.3 で確認） |
/// | mapbox   | `map.flyTo(cameraOptions, animationOptions)` | 明示的に flyTo |
///
/// maplibre / mappls は AAR を逆アセンブルして `NativeMap.flyTo` を呼んでいることを
/// 確認した。`easeCamera` のほうが `easeTo`（アーク無し）で、`animateCamera` は
/// **`flyTo`** に落ちる。名前から素の ease だと決めつけたのが誤りの元だった。
///
/// SwiftUI / Jetpack Compose と React Native はどちらも同じコントローラを通るので、
/// この差はプラットフォーム全体の差であって RN 固有ではない。
///
/// ## 使い方
///
/// `progress` は 0…1 の正規化時間。`zoom(at:)` と `centerFraction(at:)` を返す。
/// **中心を `progress` で素朴に補間しないこと。** ズームだけ弧を描かせて中心を
/// 等速で動かすと、移動が破綻して見える。必ず `centerFraction(at:)` を使う。
///
/// アプリ開発者向けの API ではないので `@_spi(MapConductorDriver)` を付けてある。
/// 使う側は `@_spi(MapConductorDriver) import MapConductorCore` と書く。
@_spi(MapConductorDriver)
public struct FlyToZoomArc {
    /// van Wijk の曲率 ρ。MapLibre GL JS の `flyTo` 既定 `curve: 1.42` と同じ。
    private static let rho = 1.42

    private let startZoom: Double
    private let endZoom: Double
    /// 退化ケース（中心がほぼ動かない）かどうか。クラスタータップはここに入る。
    private let isPureZoom: Bool

    // van Wijk の係数。`isPureZoom` のときは使わない。
    private let w0: Double
    private let r0: Double
    private let u1: Double
    /// 総移動量 S。`progress * S` が式のパラメータ s になる。
    private let totalS: Double

    /// - Parameters:
    ///   - startZoom / endZoom: 統一ズーム（Google 基準）。
    ///   - screenTravelPixels: 開始ズームでの中心間距離（画面ピクセル）。
    ///   - viewportSizePixels: ビューポートの代表寸法（幅と高さの大きいほう）。
    public init(
        startZoom: Double,
        endZoom: Double,
        screenTravelPixels: Double,
        viewportSizePixels: Double
    ) {
        self.startZoom = startZoom
        self.endZoom = endZoom

        let rho = Self.rho
        let rho2 = rho * rho
        let w0 = max(viewportSizePixels, 1.0)
        // 目標ズームでの見かけのビューポート幅。ズームが 1 上がると半分になる。
        let w1 = w0 / pow(2.0, endZoom - startZoom)
        let u1 = screenTravelPixels

        self.w0 = w0
        // 中心がほとんど動かないときは van Wijk の一般式が 0 除算になる。
        // MapLibre GL JS も同じ判定で分岐し、そちらは**単調な指数ズーム**になる
        // （＝アークが出ない）。クラスタータップはこの枝。
        if u1 < 1e-6 {
            self.isPureZoom = true
            self.u1 = 0
            self.r0 = 0
            self.totalS = abs(log(w1 / w0)) / rho
        } else {
            self.isPureZoom = false
            self.u1 = u1
            let b0 = (w1 * w1 - w0 * w0 + rho2 * rho2 * u1 * u1) / (2.0 * w0 * rho2 * u1)
            let b1 = (w1 * w1 - w0 * w0 - rho2 * rho2 * u1 * u1) / (2.0 * w1 * rho2 * u1)
            let r0 = log(-b0 + (b0 * b0 + 1).squareRoot())
            let r1 = log(-b1 + (b1 * b1 + 1).squareRoot())
            self.r0 = r0
            self.totalS = (r1 - r0) / rho
        }
    }

    /// 2 つのカメラ位置とビューポートの大きさから組み立てる。
    ///
    /// 中心間の距離を**開始ズームの画面ピクセル**で測る。van Wijk はこの距離と
    /// ビューポートの大きさの比でアークの有無を決めるので、度のまま渡すと
    /// 高緯度と低ズームで別物になる。各プロバイダが同じ換算を書き写さずに済むよう
    /// ここに畳んである。
    ///
    /// - Parameter viewportSizePixels: ビューポートの幅と高さの大きいほう。
    public init(
        from: MapCameraPosition,
        to: MapCameraPosition,
        viewportSizePixels: Double
    ) {
        self.init(
            startZoom: from.zoom,
            endZoom: to.zoom,
            screenTravelPixels: Self.screenDistancePixels(
                from: from.position,
                to: to.position,
                zoom: from.zoom
            ),
            viewportSizePixels: viewportSizePixels
        )
    }

    /// 2 点間の距離を、指定ズームでの Web Mercator 画面ピクセルに換算する。
    public static func screenDistancePixels(
        from: GeoPointProtocol,
        to: GeoPointProtocol,
        zoom: Double
    ) -> Double {
        let worldSize = 256.0 * pow(2.0, zoom)
        func project(_ point: GeoPointProtocol) -> (Double, Double) {
            let x = (point.longitude + 180.0) / 360.0
            let latRad = point.latitude * .pi / 180.0
            let clamped = min(max(sin(latRad), -0.9999), 0.9999)
            let y = 0.5 - log((1 + clamped) / (1 - clamped)) / (4 * .pi)
            return (x * worldSize, y * worldSize)
        }
        let a = project(from)
        let b = project(to)
        return ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot()
    }

    /// 正規化時間 `progress`（0…1）でのズーム。
    public func zoom(at progress: Double) -> Double {
        guard totalS.isFinite, totalS != 0 else { return lerp(startZoom, endZoom, progress) }
        let s = progress * totalS
        let w = width(at: s)
        guard w > 0, w.isFinite else { return lerp(startZoom, endZoom, progress) }
        return startZoom + log2(w0 / w)
    }

    /// 正規化時間 `progress` での中心の進み具合（0…1）。開始点と目標点の補間係数。
    public func centerFraction(at progress: Double) -> Double {
        guard !isPureZoom, totalS.isFinite, totalS != 0 else { return progress }
        let rho = Self.rho
        let s = progress * totalS
        let value = w0 * (cosh(r0) * tanh(rho * s + r0) - sinh(r0)) / (rho * rho) / u1
        guard value.isFinite else { return progress }
        return min(max(value, 0.0), 1.0)
    }

    private func width(at s: Double) -> Double {
        if isPureZoom {
            let sign: Double = endZoom > startZoom ? -1.0 : 1.0
            return w0 * exp(sign * Self.rho * s)
        }
        return w0 * cosh(r0) / cosh(Self.rho * s + r0)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}
