import Foundation

/// オーバーレイの重なり順の「帯」。下から順に並ぶ。
///
/// すべてのプロバイダ・3 プラットフォームで、オーバーレイは下からこの順に重ねる:
///
/// 1. ラスターレイヤー（``RasterLayerState``、アプリが足すタイル）
/// 2. グラウンドイメージ
/// 3. ポリゴン（ネイティブのポリゴンと、SDK のポリゴンのタイルレイヤーが同じ帯）
/// 4. サークル
/// 5. ポリライン（ネイティブのポリラインと、SDK のポリラインのタイルレイヤーが同じ帯。タイルは帯の一番下）
/// 6. マーカー（ネイティブのマーカーと、SDK のマーカーのタイルレイヤー・strategy の描画が同じ帯）
///
/// 追加した順・送り直した順（`clearOverlays()` の後など）・デザイン変更の後に左右されない。
/// 帯の中は zIndex、同じ zIndex なら渡された順（先に置いたものが下）。
///
/// クリックの探索順（``OverlayKind``）とは別軸。
///
/// android-sdk-core / js-sdk-core にも同じ並びで置く。
@_spi(MapConductorDriver)
public enum OverlayBand: Int, CaseIterable, Comparable, Sendable {
    case rasterLayer = 0
    case groundImage = 1
    case polygon = 2
    case circle = 3
    case polyline = 4
    case marker = 5

    public static func < (lhs: OverlayBand, rhs: OverlayBand) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 重なり順の比較キー。帯 → zIndex の順に比べる。
@_spi(MapConductorDriver)
public struct OverlayStackKey: Comparable, Hashable, Sendable {
    public let band: OverlayBand
    public let zIndex: Int

    public init(_ band: OverlayBand, zIndex: Int = 0) {
        self.band = band
        self.zIndex = zIndex
    }

    public static func < (lhs: OverlayStackKey, rhs: OverlayStackKey) -> Bool {
        if lhs.band != rhs.band { return lhs.band < rhs.band }
        return lhs.zIndex < rhs.zIndex
    }
}

/// 帯の順に並べるための計算。プロバイダの描画担当が、レイヤを差し込む位置や
/// ネイティブの zIndex を決めるのに使う。
@_spi(MapConductorDriver)
public enum OverlayStacking {
    /// 下から並んだ既存のレイヤ（`nil` はベースマップなど MapConductor 以外のレイヤ）に対して、
    /// `key` のレイヤを差し込む位置（その位置にあるレイヤの**下**に入る。`existing.count` なら一番上）。
    ///
    /// - 自分より上に来るべき MapConductor のレイヤ（キーが大きいもの）のうち一番下のものの直下に入る。
    ///   キーが同じものの上に入るので、同じキーなら渡された順になる。
    /// - 無ければ一番上。
    /// - `ceiling` を渡すと、それより上には入れない（ラスターを「ベースマップのラベルの下」に
    ///   置くのに使う）。ただし自分より下に来るべき MapConductor のレイヤよりは下げない。
    public static func insertionIndex(
        for key: OverlayStackKey,
        among existing: [OverlayStackKey?],
        ceiling: Int? = nil
    ) -> Int {
        var index = existing.firstIndex { other in
            guard let other else { return false }
            return key < other
        } ?? existing.count
        if let ceiling, ceiling < index {
            let floor = (existing.lastIndex { other in
                guard let other else { return false }
                return other <= key
            }).map { $0 + 1 } ?? 0
            index = max(ceiling, floor)
        }
        return index
    }

    /// GL スタイル（MapLibre / Mapbox / MapTiler / Mappls）で MapConductor が使うレイヤ ID の帯。
    /// MapConductor のレイヤでなければ `nil`。
    ///
    /// 4 プロバイダとも同じ接頭辞を使っている。新しい種類のレイヤを足したらここにも足すこと
    /// （足し忘れるとそのレイヤは「ベースマップのレイヤ」扱いになり、帯の計算から外れる）。
    public static func band(ofStyleLayerId id: String) -> OverlayBand? {
        for (prefix, band) in styleLayerPrefixes where id.hasPrefix(prefix) {
            return band
        }
        return nil
    }

    /// ``band(ofStyleLayerId:)`` の表。長い接頭辞を先に書く（`mapconductor-markers-` より
    /// `mapconductor-tile-markers-` が先、など前方一致の取り違えを避ける）。
    public static let styleLayerPrefixes: [(String, OverlayBand)] = [
        // ポリゴンのタイル（feat/polygon-tiling の PolygonTiler）はラスターの経路で載るが、帯はポリゴン。
        ("mapconductor-raster-layer-\(polygonTileStateId)", .polygon),
        // ポリラインのタイル（PolylineTiler）も同じ。帯はポリライン。
        ("mapconductor-raster-layer-\(polylineTileStateId)", .polyline),
        ("mapconductor-raster-layer-\(markerTileStateIdPrefix)", .marker),
        ("mapconductor-raster-layer-", .rasterLayer),
        ("mc-gimg-lyr-", .groundImage),
        ("mapconductor-polygons-fill-", .polygon),
        ("mapconductor-polygons-line-", .polygon),
        ("mapconductor-circles-layer-", .circle),
        ("mapconductor-polylines-layer-", .polyline),
        ("mapconductor-tile-markers-layer-", .marker),
        ("mapconductor-cluster-layer-", .marker),
        ("mapconductor-markers-layer-", .marker),
    ]

    /// ラスターの経路（``RasterLayerState``）で載るレイヤの帯のキー。
    ///
    /// アプリのラスターはラスターの帯（zIndex つき）。SDK がラスターの経路で載せる
    /// ポリゴンのタイル（id ``polygonTileStateId``）はポリゴンの帯、マーカーのタイル
    /// （id が ``markerTileStateIdPrefix`` で始まる）はマーカーの帯。ポリラインのタイル
    /// （id ``polylineTileStateId``）はポリラインの帯の一番下（``polylineTileKey``）で、
    /// ネイティブで描くポリライン（geodesic など）がその上に来る。
    public static func rasterKey(stateId: String, zIndex: Int) -> OverlayStackKey {
        if stateId == polygonTileStateId { return OverlayStackKey(.polygon) }
        if stateId == polylineTileStateId { return polylineTileKey }
        if stateId.hasPrefix(markerTileStateIdPrefix) { return OverlayStackKey(.marker) }
        return OverlayStackKey(.rasterLayer, zIndex: zIndex)
    }

    /// PolygonTiler（feat/polygon-tiling）がラスターの経路で載せるレイヤの id。
    public static let polygonTileStateId = "mc-polygon-tiles"
    /// PolylineTiler がラスターの経路で載せるレイヤの id。
    public static let polylineTileStateId = "mc-polyline-tiles"
    /// ポリラインのタイルのキー。帯の中で一番下（``globalZIndex(_:)`` が受け付ける範囲のすぐ外で、
    /// 帯の下端に丸まる。`Int.min` にしないのは、zIndex に足し引きするプロバイダで桁あふれしないため）。
    /// GL スタイルでは既存のポリラインのレイヤ（zIndex 0 扱い）より下に差し込まれる。
    public static let polylineTileKey = OverlayStackKey(.polyline, zIndex: -(zIndexSpan + 1))

    /// GL スタイルでラスターの経路から載せるレイヤ（ID `mapconductor-raster-layer-<state id>`）のキー。
    /// ``rasterKey(stateId:zIndex:)`` をレイヤ ID から引く版。
    public static func rasterKey(styleLayerId id: String, zIndex: Int) -> OverlayStackKey {
        let prefix = "mapconductor-raster-layer-"
        guard id.hasPrefix(prefix) else { return OverlayStackKey(.rasterLayer, zIndex: zIndex) }
        return rasterKey(stateId: String(id.dropFirst(prefix.count)), zIndex: zIndex)
    }
    /// マーカーのタイルをラスターの経路で載せるプロバイダ（ArcGIS / OMM）の id の接頭辞。
    public static let markerTileStateIdPrefix = "marker-tile-"

    /// 種類をまたいで 1 本の数で重なり順を比べる SDK（Google Maps の `zIndex`、HERE の
    /// `drawOrder` など）へ渡す値。帯ごとに十分離した区間に zIndex を収める。
    ///
    /// zIndex は ±``zIndexSpan`` に丸める（区間からはみ出して隣の帯へ入らないように）。
    public static func globalZIndex(_ key: OverlayStackKey) -> Int32 {
        globalZIndex(key, bandStride: bandStride)
    }

    /// 帯の幅を指定する版。受け付ける zIndex は ±(`bandStride` / 2 - 1) に丸める。
    /// 大きな値を扱えない SDK（HERE の `drawOrder` など）向け。
    public static func globalZIndex(_ key: OverlayStackKey, bandStride: Int) -> Int32 {
        let span = max(bandStride / 2 - 1, 0)
        let clamped = min(max(key.zIndex, -span), span)
        return Int32(key.band.rawValue * bandStride + clamped)
    }

    /// ``globalZIndex(_:)`` で 1 つの帯が使う区間の幅。
    ///
    /// 小さく取ってある（6 帯で 0〜約 2.2 万）。SDK によっては大きな zIndex を
    /// 内部で丸めるおそれがあるため（Int16 に収まる範囲にとどめる）。
    public static let bandStride = 4_096
    /// ``globalZIndex(_:)`` が受け付ける zIndex の絶対値の上限。これを超える zIndex は丸める。
    public static let zIndexSpan = 2_047
}
