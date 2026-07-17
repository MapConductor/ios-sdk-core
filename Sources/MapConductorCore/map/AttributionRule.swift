import Foundation

public struct AttributionRule: Hashable {
    public let attribution: String
    public let minZoom: Int?
    public let maxZoom: Int?
    public let bounds: GeoRectBounds?

    public init(
        attribution: String,
        minZoom: Int? = nil,
        maxZoom: Int? = nil,
        bounds: GeoRectBounds? = nil
    ) {
        self.attribution = attribution
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.bounds = bounds
    }
}

public func resolveAttributionRules(
    _ rules: [AttributionRule],
    camera: MapCameraPositionProtocol
) -> [String] {
    let tileZoom = Int(floor(camera.zoom))
    let visibleBounds = camera.visibleRegion?.bounds
    var seen = Set<String>()
    return rules.compactMap { rule in
        if let minZoom = rule.minZoom, tileZoom < minZoom { return nil }
        if let maxZoom = rule.maxZoom, tileZoom > maxZoom { return nil }
        if let bounds = rule.bounds {
            let matches = visibleBounds.map(bounds.intersects(other:)) ?? bounds.contains(point: camera.position)
            if !matches { return nil }
        }
        let attribution = rule.attribution.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attribution.isEmpty, seen.insert(attribution).inserted else { return nil }
        return attribution
    }
}

public func resolveMapAttributions(
    designRules: [AttributionRule],
    rasterLayers: [RasterLayer],
    camera: MapCameraPositionProtocol
) -> [String] {
    let tileZoom = Int(floor(camera.zoom))
    let rasterRules = rasterLayers.compactMap { layer -> [AttributionRule]? in
        guard layer.state.visible,
              case let .urlTemplate(_, _, minZoom, maxZoom, attributionRules, _) = layer.state.source
        else { return nil }
        if let minZoom, tileZoom < minZoom { return nil }
        if let maxZoom, tileZoom > maxZoom { return nil }
        return attributionRules
    }.flatMap { $0 }

    var seen = Set<String>()
    return (resolveAttributionRules(designRules, camera: camera) +
        resolveAttributionRules(rasterRules, camera: camera))
        .filter { seen.insert($0).inserted }
}
