import SwiftUI
import UIKit

/// 地表画像とラスタレイヤーの DSL 要素。
public struct GroundImage: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: GroundImageState

    public init(state: GroundImageState) {
        self.state = state
        self.id = state.id
    }

    public init(
        bounds: GeoRectBounds,
        image: UIImage,
        // android-sdk の `GroundImage` コンポーザブル（opacity = 0.5f）と同じ既定値。
        // `GroundImageState` 側の既定は 3 者とも 1.0 で、コンポーネントだけ 0.5。
        opacity: Double = 0.5,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil
    ) {
        let state = GroundImageState(
            bounds: bounds,
            image: image,
            opacity: opacity,
            tileSize: tileSize,
            id: id,
            extra: extra,
            onClick: onClick
        )
        self.state = state
        self.id = state.id
    }

    public func append(to content: inout MapViewContent) {
        content.groundImages.append(self)
    }
}

public struct RasterLayer: MapOverlayItemProtocol, Identifiable {
    public let id: String
    public let state: RasterLayerState

    public init(state: RasterLayerState) {
        self.state = state
        self.id = state.id
    }

    /// 引数順は android-sdk の `RasterLayer` コンポーザブル
    /// （source, opacity, visible, zIndex, userAgent, id, extraHeaders）に合わせてある。
    public init(
        source: RasterLayerSource,
        opacity: Double = 1.0,
        visible: Bool = true,
        zIndex: Int = 0,
        userAgent: String = RasterLayerState.defaultUserAgent,
        id: String? = nil,
        extraHeaders: [String: String]? = nil
    ) {
        let state = RasterLayerState(
            source: source,
            opacity: opacity,
            visible: visible,
            zIndex: zIndex,
            userAgent: userAgent,
            extraHeaders: extraHeaders,
            id: id
        )
        self.state = state
        self.id = state.id
    }

    public func append(to content: inout MapViewContent) {
        content.rasterLayers.append(self)
    }
}
