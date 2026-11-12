import CoreGraphics

public protocol MapViewHolderProtocol {
    associatedtype ActualMapView
    associatedtype ActualMap

    var mapView: ActualMapView { get }
    var map: ActualMap { get }

    /// 地理座標 → 画面座標。
    ///
    /// 同期でしか用意できない SDK があるためこの形。逆変換と違って非同期版は無い。
    func toScreenOffset(position: GeoPointProtocol) -> CGPoint?

    /// 画面座標 → 地理座標（非同期）。
    ///
    /// 既定は ``fromScreenOffsetSync(offset:)`` へ委譲する。同期で変換できる
    /// プロバイダは同期版だけを実装すればよい（実際 7 プロバイダが
    /// `fromScreenOffsetSync(offset: offset)` の 1 行を書いていた）。
    ///
    /// 同期版を持てない SDK（ArcGIS の `screenToLocation` など）はこちらを実装する。
    func fromScreenOffset(offset: CGPoint) async -> GeoPoint?

    /// 画面座標 → 地理座標（同期）。**同期変換を必須にしないこと。**
    ///
    /// WebView ブリッジ越しのプロバイダ（ios-for-longdo）は同期 API を持たず、
    /// ここは nil を返すしかない。同期変換を要求する機能（InfoBubble・マーカー
    /// アニメーション・タイル方式マーカーのヒットテスト）は、動かないことを
    /// ``MapCapability/screenProjectionSync`` で宣言すること。
    /// 既定 nil のまま黙って無反応にしない（``ScreenProjectionRequirement`` を参照）。
    func fromScreenOffsetSync(offset: CGPoint) -> GeoPoint?

    /// ビューポートの大きさ。``buildVisibleRegion(inset:requireAllCorners:)`` が
    /// 4 隅を逆投影するのに使う。
    ///
    /// 既定は `mapView as? UIView` の `bounds.size`。SDK の地図ビューが `UIView` なら
    /// 書かなくてよい。
    ///
    /// **プロトコルの要件として宣言してあるのは、override を効かせるため。**
    /// 拡張にだけ置くと Swift は静的ディスパッチするので、ドライバーが同名の関数を
    /// 書いてもコアの `buildVisibleRegion` からは呼ばれず、`visibleRegion` が
    /// 黙って nil になる（`ios-for-template` を書いていて実際に踏んだ）。
    func viewportSizePx() -> CGSize?

    /// 地図エンジンが今使っている座標系。``toProjectedPoint(_:)`` の値はこの座標系になる。
    ///
    /// 既定は EPSG:3857 メートル。Mercator しか持たないエンジンと、地球儀表示中の
    /// エンジンはこのままでよい。地図ごとに座標系を持てるエンジン（ArcGIS など）
    /// だけが上書きする。override を効かせるため、``viewportSizePx()`` と同じく
    /// プロトコルの要件として宣言してある。
    var coordinateSystem: MapCoordinateSystem { get }

    /// 地理座標 → ``coordinateSystem`` の投影座標。**画面座標ではない。**
    ///
    /// 投影の定義域の外などで変換できないときは nil。既定は EPSG:3857。
    func toProjectedPoint(_ position: GeoPointProtocol) -> CGPoint?

    /// ``coordinateSystem`` の投影座標 → 地理座標。``toProjectedPoint(_:)`` の逆。
    ///
    /// 変換できないときは nil。既定は EPSG:3857。
    func fromProjectedPoint(_ point: CGPoint) -> GeoPoint?
}

public extension MapViewHolderProtocol {
    func fromScreenOffset(offset: CGPoint) async -> GeoPoint? {
        fromScreenOffsetSync(offset: offset)
    }

    func fromScreenOffsetSync(offset _: CGPoint) -> GeoPoint? {
        nil
    }

    var coordinateSystem: MapCoordinateSystem {
        .webMercator
    }

    func toProjectedPoint(_ position: GeoPointProtocol) -> CGPoint? {
        WebMercator().project(position)
    }

    func fromProjectedPoint(_ point: CGPoint) -> GeoPoint? {
        WebMercator().unproject(point)
    }
}

public struct AnyMapViewHolder: MapViewHolderProtocol {
    public typealias ActualMapView = Any
    public typealias ActualMap = Any

    public let mapView: Any
    public let map: Any

    private let toScreenOffsetHandler: (GeoPointProtocol) -> CGPoint?
    private let fromScreenOffsetHandler: (CGPoint) async -> GeoPoint?
    private let fromScreenOffsetSyncHandler: (CGPoint) -> GeoPoint?
    /// 型消去でも override を落とさないよう、ここでも包んだホルダーへ転送する。
    private let viewportSizePxHandler: () -> CGSize?
    private let coordinateSystemHandler: () -> MapCoordinateSystem
    private let toProjectedPointHandler: (GeoPointProtocol) -> CGPoint?
    private let fromProjectedPointHandler: (CGPoint) -> GeoPoint?

    public init<H: MapViewHolderProtocol>(_ holder: H) {
        self.viewportSizePxHandler = { holder.viewportSizePx() }
        self.coordinateSystemHandler = { holder.coordinateSystem }
        self.toProjectedPointHandler = { holder.toProjectedPoint($0) }
        self.fromProjectedPointHandler = { holder.fromProjectedPoint($0) }
        self.mapView = holder.mapView
        self.map = holder.map
        self.toScreenOffsetHandler = { holder.toScreenOffset(position: $0) }
        self.fromScreenOffsetHandler = { offset in
            await holder.fromScreenOffset(offset: offset)
        }
        self.fromScreenOffsetSyncHandler = { holder.fromScreenOffsetSync(offset: $0) }
    }

    public func toScreenOffset(position: GeoPointProtocol) -> CGPoint? {
        toScreenOffsetHandler(position)
    }

    public func fromScreenOffset(offset: CGPoint) async -> GeoPoint? {
        await fromScreenOffsetHandler(offset)
    }

    public func fromScreenOffsetSync(offset: CGPoint) -> GeoPoint? {
        fromScreenOffsetSyncHandler(offset)
    }

    public func viewportSizePx() -> CGSize? {
        viewportSizePxHandler()
    }

    public var coordinateSystem: MapCoordinateSystem {
        coordinateSystemHandler()
    }

    public func toProjectedPoint(_ position: GeoPointProtocol) -> CGPoint? {
        toProjectedPointHandler(position)
    }

    public func fromProjectedPoint(_ point: CGPoint) -> GeoPoint? {
        fromProjectedPointHandler(point)
    }
}
