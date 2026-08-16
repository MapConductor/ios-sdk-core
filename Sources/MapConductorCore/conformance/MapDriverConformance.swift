import CoreGraphics
import Foundation

/// 地図SDKドライバーの適合チェック。
///
/// 外部の作者が自分のドライバーのユニットテストから呼んで、コアが前提にしている
/// 契約を満たしているかを機械的に確かめるためのもの。**XCTest に依存しない**
/// （素の関数と例外だけ）ので、どのテストランナーからでも使える。
///
/// ```swift
/// func testZoomConverterRoundTrips() throws {
///     try MapDriverConformance.checkZoomConverter(MyZoomConverter())
/// }
/// func testEveryOverlayKindIsSlotted() throws {
///     try MapDriverConformance.checkOverlaySlots(controller.registeredOverlayControllers())
/// }
/// ```
///
/// android-sdk の `MapDriverConformance.kt`、react-sdk の
/// `MapDriverConformance.ts` と同じ 5 つのチェックを持つ。
///
/// ## ここに入れられないもの
///
/// マーカーの描画は `UIImage` を通り、当たり判定は実際のビューの大きさに依存する。
/// マーカーのタップやドラッグは**実機で確かめるしかない**。
/// このチェックが緑でも実機確認は省略しないこと。
public enum MapDriverConformance {
    /// 適合していないときに投げる。
    public struct ViolationError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw ViolationError(message()) }
    }

    // MARK: - ズーム

    /// ズームの往復換算が壊れていないか。
    ///
    /// ドライバーは SDK の生ズームと統一ズーム（Google 準拠）を相互変換する。
    /// ここがずれると、当たり判定の許容量（metersPerPixel × tapTolerance）が
    /// 実際の縮尺と食い違い、**線や円をタップしても反応しない**という形で表面化する。
    ///
    /// - Parameters:
    ///   - converter: ドライバーのコンバータ。
    ///   - latitudes: 検査する緯度。高緯度で分岐するプロバイダがあるので端も入れる。
    public static func checkZoomConverter(
        _ converter: WebMercatorZoomAltitudeConverter,
        latitudes: [Double] = [0.0, 35.0, 60.0, 85.0, -85.0],
        zooms: [Double] = [0.0, 1.0, 5.5, 10.0, 15.25, 22.0]
    ) throws {
        for latitude in latitudes {
            for zoom in zooms {
                let native = converter.toNativeZoom(zoom, latitude: latitude)
                let roundTrip = converter.toUnifiedZoom(native, latitude: latitude)
                // 端はクランプされるので、クランプ範囲内でのみ往復を要求する。
                let clampedInput = min(
                    max(zoom, AbstractZoomAltitudeConverter.minZoomLevel),
                    AbstractZoomAltitudeConverter.maxZoomLevel
                )
                if native > AbstractZoomAltitudeConverter.minZoomLevel,
                   native < AbstractZoomAltitudeConverter.maxZoomLevel {
                    try check(
                        abs(roundTrip - clampedInput) < zoomTolerance,
                        "zoom round-trip failed at zoom=\(zoom) latitude=\(latitude): "
                            + "toNativeZoom=\(native) toUnifiedZoom=\(roundTrip)"
                    )
                }
            }
        }

        // 単調性。統一ズームを上げたら生ズームも上がること。
        for latitude in latitudes {
            var previous = -Double.infinity
            for step in 0...22 {
                let native = converter.toNativeZoom(Double(step), latitude: latitude)
                try check(
                    native >= previous,
                    "toNativeZoom is not monotonic at latitude=\(latitude) (zoom=\(step))"
                )
                previous = native
            }
        }

        // クランプ。範囲外を渡しても [0, 22] に収まること。
        for extreme in [-100.0, 1000.0] {
            let unified = converter.toUnifiedZoom(extreme)
            try check(
                unified >= AbstractZoomAltitudeConverter.minZoomLevel
                    && unified <= AbstractZoomAltitudeConverter.maxZoomLevel,
                "toUnifiedZoom(\(extreme)) = \(unified) is out of [0, 22]"
            )
        }
    }

    // MARK: - スロット

    /// 6 種別すべてがスロットに参加しているか。
    ///
    /// ## これが最重要のチェック
    ///
    /// ``SlottedOverlayController`` を実装し忘れたコントローラは、
    /// Capable ファサードとクリックカスケードから**黙って漏れる**。
    /// ビルドも apiCheck も既存のユニットテストも緑のまま、
    ///
    ///   - マーカーが 1 つも表示されない
    ///   - ポリゴン単体の状態更新が捨てられる
    ///
    /// という形で出る。移行中に 3 プロバイダの GroundImageController が
    /// スロットに載っていないことを、これと同じ検査で見つけた。
    ///
    /// **Swift は Kotlin と違って、プロトコル適合を書き忘れてもコンパイルは通る。**
    /// `registerOverlayController` は `AnyOverlayController` を受けるので、
    /// `SlottedOverlayController` を付け忘れても型エラーにならない。
    ///
    /// - Parameters:
    ///   - controllers: `registerOverlayController` に渡したものすべて。
    ///   - expected: 期待する種別。ラスターレイヤを持たないドライバーは外してよい。
    public static func checkOverlaySlots(
        _ controllers: [any AnyOverlayController],
        expected: Set<OverlayKind> = Set(OverlayKind.allCases)
    ) throws {
        let slotted = controllers.compactMap { $0 as? any SlottedOverlayController }
        let declared = Set(slotted.map(\.kind))
        let missing = expected.subtracting(declared)
        try check(
            missing.isEmpty,
            "these overlay kinds are not reachable from the Capable facade or the click cascade: "
                + "\(missing.map(\.rawValue).sorted()) — the controller is probably not a "
                + "SlottedOverlayController (registered controllers: "
                + "\(controllers.map { String(describing: type(of: $0)) }))"
        )
    }

    // MARK: - カスケード

    /// クリックカスケードの探索順が正準どおりか。
    ///
    /// ドライバーが ``OverlayHitResolver/canonicalOrder`` を差し替えている場合に、
    /// 意図した順になっているかを確かめる。
    public static func checkCascadeOrder(
        _ order: [OverlayKind] = OverlayHitResolver.canonicalOrder
    ) throws {
        try check(
            !order.contains(.marker),
            "marker must not be in the overlay cascade; it goes through dispatchMarkerTap "
                + "because the hit test needs screen projection"
        )
        let circle = order.firstIndex(of: .circle)
        let polygon = order.firstIndex(of: .polygon)
        if let circle, let polygon {
            try check(circle < polygon, "circle must be probed before polygon (small overlays win): \(order)")
        }
    }

    // MARK: - capability

    /// capability の宣言が意味の通る形か。
    ///
    /// ## Unknown を非対応と混同しないこと
    ///
    /// 宣言が無い（``MapCapabilityStatus/unknown``）は「まだ宣言していない」であって
    /// 「使えない」ではない。地図の初期化途中もここに入る。
    /// **``MapCapabilityStatus/unsupported(_:)`` は「その機能が動かない」ときだけ**。
    /// ホルダーに同期変換が無くても別経路で動いているなら
    /// ``MapCapabilityStatus/degraded(_:)`` にすること。`unsupported` にすると
    /// コアが**動いている機能を止める**。
    public static func checkCapabilityDeclarations(_ registry: MapServiceRegistry) throws {
        for capability in MapCapability.allCases {
            let status = registry.capabilityStatus(capability)
            if status.isKnownUnsupported {
                try check(
                    !(status.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(capability.id) is declared unsupported without a reason; the diagnostic log "
                        + "would tell the app developer nothing about why the feature stopped"
                )
            }
        }
    }

    // MARK: - 投影

    /// ホルダーの投影が往復するか。同期変換を持つドライバーだけ呼ぶこと。
    public static func checkProjectionRoundTrip(
        toScreen: (GeoPointProtocol) -> CGPoint?,
        fromScreen: (CGPoint) -> GeoPointProtocol?,
        samples: [GeoPointProtocol]
    ) throws {
        for point in samples {
            guard let screen = toScreen(point) else { continue }
            guard let back = fromScreen(screen) else {
                throw ViolationError(
                    "fromScreenOffsetSync returned nil for a point it just projected: "
                        + "(\(point.latitude), \(point.longitude))"
                )
            }
            try check(
                abs(back.latitude - point.latitude) < coordTolerance
                    && abs(back.longitude - point.longitude) < coordTolerance,
                "projection round-trip failed: (\(point.latitude), \(point.longitude)) -> "
                    + "\(screen) -> (\(back.latitude), \(back.longitude))"
            )
        }
    }

    private static let zoomTolerance = 1e-6

    // 画面座標は CGFloat なので往復の誤差はズームに比例して残る。
    // 1e-5 度 ≒ 1m。投影が「壊れている」ことを見るには十分細かい。
    private static let coordTolerance = 1e-5
}
