public protocol MarkerEntityProtocol {
    associatedtype ActualMarker

    var marker: ActualMarker? { get set }
    var state: MarkerState { get }
    var fingerPrint: MarkerFingerPrint { get }
    var visible: Bool { get set }
    var isRendered: Bool { get set }
    /// この entity が「マーカータイル担当」かどうか。
    ///
    /// 多くのプロバイダはコントローラの `MarkerManager` を [MarkerTileRenderer] にも
    /// そのまま渡すので、1 つのマネージャにタイル担当とネイティブ担当が同居する。
    /// 描き分けはこのフラグで行う。
    ///
    /// - [MarkerTileRenderer] は `filter { $0.tiling }` を PNG に焼く。
    /// - ネイティブ側のレンダラはタイル担当を描かない
    ///   （iOS では `compactMap { $0.marker }` がタイル担当を自然に落とす。
    ///   タイル担当は `marker == nil` で登録されるため）。
    ///
    /// ドラッグ可能／アニメーション付きのマーカーは `shouldTile` で弾かれ、
    /// `tiling = false` のままネイティブに描かれる。
    ///
    /// android-sdk の `MarkerEntityInterface.tiling` と同じ意味。
    var tiling: Bool { get set }
}

public final class MarkerEntity<ActualMarker>: MarkerEntityProtocol {
    public var marker: ActualMarker?
    public let state: MarkerState
    public let fingerPrint: MarkerFingerPrint
    public var visible: Bool
    public var isRendered: Bool
    public var tiling: Bool

    public init(
        marker: ActualMarker?,
        state: MarkerState,
        visible: Bool = true,
        isRendered: Bool = false,
        tiling: Bool = false
    ) {
        self.marker = marker
        self.state = state
        self.visible = visible
        self.isRendered = isRendered
        self.tiling = tiling
        self.fingerPrint = state.fingerPrint()
    }
}
