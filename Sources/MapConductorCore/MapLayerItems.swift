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
        // `GroundImageState` と同じ既定値（3 プラットフォームとも 1.0）。
        opacity: Double = 1.0,
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

    /// 画像を URL で渡す（``GroundImageState/init(bounds:imageUrl:opacity:tileSize:id:extra:onClick:)``）。
    public init(
        bounds: GeoRectBounds,
        imageUrl: URL,
        opacity: Double = 1.0,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil
    ) {
        let state = GroundImageState(
            bounds: bounds,
            imageUrl: imageUrl,
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
