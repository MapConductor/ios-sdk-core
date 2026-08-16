import Foundation

/// ズーム換算に共通の定数。
///
/// android-sdk の `AbstractZoomAltitudeConverter` の companion object に対応する。
/// 値は ``ZoomAltitudeConverterProtocol`` の protocol extension と同じもので、
/// **型名から参照できる置き場所**が要るのでここにも置いてある
/// （Swift は protocol 名から static メンバを引けない）。
public enum AbstractZoomAltitudeConverter {
    /// Calibrated to match Google Maps visible regions.
    public static let defaultZoom0Altitude: Double = 171_319_879.0
    public static let zoomFactor: Double = 2.0
    public static let minZoomLevel: Double = 0.0
    public static let maxZoomLevel: Double = 22.0
    public static let minAltitude: Double = 100.0
    public static let maxAltitude: Double = 50_000_000.0
    public static let minCosLat: Double = 0.01
    public static let minCosTilt: Double = 0.05
    public static let webMercatorInitialMpp256: Double = 156_543.033_928
}

/// Web Mercator 系の地図SDK向けの、統一ズーム ⇄ 高度の変換。
///
/// 統一ズームは Google Maps 基準（256px タイル）。各 SDK のネイティブズームとの差は
/// ``zoomOffset(at:)`` だけなので、そこをパラメータにして実装を 1 本にまとめてある。
///
/// ```
/// unifiedZoom = nativeZoom + zoomOffset(at: latitude)
/// distance    = zoom0Altitude * cos(latitude) / 2^unifiedZoom
/// altitude    = distance * cos(tilt)
/// ```
///
/// ## 継承ではなく合成で選ぶこと
///
/// これは ``ZoomAltitudeConverterProtocol`` の「既定の実装」ではなく、**Web Mercator の
/// 参照実装**である。全プロバイダの親にしてはいけない。ズームが `2^n` のスケール則に
/// 載らない SDK（正距円筒タイル、WMTS / ArcGIS LOD のような離散 scale-set、屋内地図の
/// ローカル平面座標、3D globe）ではこの式自体が成立しない。そうした SDK は
/// ``ZoomAltitudeConverterProtocol`` を直接実装する。
///
/// 較正定数（`zoom0Altitude`）も**プロバイダが持つ**。同じプロバイダでもプラットフォームで
/// 値が違う実例がある（ArcGIS の zoom0Altitude は iOS 141,600,000 / Android・React
/// 136,500,000）。コアに固定しないこと。
///
/// - Parameter zoomOffset: `unifiedZoom = nativeZoom + zoomOffset`。512px タイルのベクタ
///   エンジン（MapLibre / Mapbox / MapTiler）は 1.0、256px 基準（Google Maps / MapKit /
///   Longdo）は 0.0。緯度に依存するプロバイダは ``GroundScaleZoomAltitudeConverter`` を使う。
open class WebMercatorZoomAltitudeConverter: ZoomAltitudeConverterProtocol {
    public let zoom0Altitude: Double
    private let fixedZoomOffset: Double

    public init(
        zoom0Altitude: Double = AbstractZoomAltitudeConverter.defaultZoom0Altitude,
        zoomOffset: Double = 0.0
    ) {
        self.zoom0Altitude = zoom0Altitude
        self.fixedZoomOffset = zoomOffset
    }

    /// ネイティブズームに足すと統一ズームになる量。既定は緯度によらず `zoomOffset`。
    ///
    /// グラウンドスケール基準の SDK は緯度に依存するのでここを上書きする
    /// （``GroundScaleZoomAltitudeConverter`` を参照）。
    open func zoomOffset(at _: Double) -> Double { fixedZoomOffset }

    /// ネイティブズーム → 統一ズーム（Google Maps 基準）。
    public func toUnifiedZoom(_ nativeZoom: Double, latitude: Double = 0.0) -> Double {
        clamp(
            nativeZoom + zoomOffset(at: latitude),
            AbstractZoomAltitudeConverter.minZoomLevel,
            AbstractZoomAltitudeConverter.maxZoomLevel
        )
    }

    /// 統一ズーム（Google Maps 基準） → ネイティブズーム。
    public func toNativeZoom(_ unifiedZoom: Double, latitude: Double = 0.0) -> Double {
        clamp(
            unifiedZoom - zoomOffset(at: latitude),
            AbstractZoomAltitudeConverter.minZoomLevel,
            AbstractZoomAltitudeConverter.maxZoomLevel
        )
    }

    /// 緯度による水平スケール補正。極付近で発散しないよう緯度を ±85° に、
    /// 係数を `minCosLat` にクランプする。
    public func cosLatitudeFactor(_ latitudeDeg: Double) -> Double {
        let clampedLat = clamp(latitudeDeg, -85.0, 85.0)
        return Swift.max(AbstractZoomAltitudeConverter.minCosLat, abs(cos(clampedLat * .pi / 180.0)))
    }

    /// 傾きによる視距離補正。真横（90°）で発散しないよう `minCosTilt` にクランプする。
    public func cosTiltFactor(_ tiltDeg: Double) -> Double {
        let clampedTilt = clamp(tiltDeg, 0.0, 90.0)
        return Swift.max(AbstractZoomAltitudeConverter.minCosTilt, cos(clampedTilt * .pi / 180.0))
    }

    public func zoomLevelToAltitude(zoomLevel: Double, latitude: Double, tilt: Double) -> Double {
        let unifiedZoom = toUnifiedZoom(zoomLevel, latitude: latitude)
        let distance = (zoom0Altitude * cosLatitudeFactor(latitude))
            / pow(AbstractZoomAltitudeConverter.zoomFactor, unifiedZoom)
        return clamp(
            distance * cosTiltFactor(tilt),
            AbstractZoomAltitudeConverter.minAltitude,
            AbstractZoomAltitudeConverter.maxAltitude
        )
    }

    public func altitudeToZoomLevel(altitude: Double, latitude: Double, tilt: Double) -> Double {
        let clampedAltitude = clamp(
            altitude,
            AbstractZoomAltitudeConverter.minAltitude,
            AbstractZoomAltitudeConverter.maxAltitude
        )
        let distance = clampedAltitude / cosTiltFactor(tilt)
        let unifiedZoom = log2((zoom0Altitude * cosLatitudeFactor(latitude)) / distance)
        return toNativeZoom(unifiedZoom, latitude: latitude)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }
}

/// グラウンドスケール基準（画面上の meter/pixel が緯度によらず一定）でズームを定義する
/// SDK 向け。Web Mercator 基準との差が `log2(cos φ)` なので、そこだけを足す。
///
/// - Parameter baseZoomOffset: 赤道でのオフセット。TomTom は 1.76（実測較正値）。
open class GroundScaleZoomAltitudeConverter: WebMercatorZoomAltitudeConverter {
    private let baseZoomOffset: Double

    public init(
        zoom0Altitude: Double = AbstractZoomAltitudeConverter.defaultZoom0Altitude,
        baseZoomOffset: Double
    ) {
        self.baseZoomOffset = baseZoomOffset
        super.init(zoom0Altitude: zoom0Altitude, zoomOffset: baseZoomOffset)
    }

    override public func zoomOffset(at latitude: Double) -> Double {
        baseZoomOffset + log2(cosLatitudeFactor(latitude))
    }
}
