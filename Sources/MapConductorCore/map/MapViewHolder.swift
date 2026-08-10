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
}

public extension MapViewHolderProtocol {
    func fromScreenOffset(offset: CGPoint) async -> GeoPoint? {
        fromScreenOffsetSync(offset: offset)
    }

    func fromScreenOffsetSync(offset _: CGPoint) -> GeoPoint? {
        nil
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

    public init<H: MapViewHolderProtocol>(_ holder: H) {
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
}
