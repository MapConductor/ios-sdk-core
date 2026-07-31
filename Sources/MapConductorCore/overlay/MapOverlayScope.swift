/// Per-map holder for one ``OverlayCollector`` per overlay type — the iOS
/// analog of the React `MapViewScope` and Android `MapViewScope`. Each provider
/// `Coordinator` owns one instance, binds each collector to its matching
/// controller with ``bindOverlayCollector(_:to:)`` in `bind()`, and feeds the
/// built `MapViewContent` into the collectors from `updateContent()`.
@MainActor
public final class MapOverlayScope {
    public let markerCollector = OverlayCollector<MarkerState>()
    public let circleCollector = OverlayCollector<CircleState>()
    public let polylineCollector = OverlayCollector<PolylineState>()
    public let polygonCollector = OverlayCollector<PolygonState>()
    public let groundImageCollector = OverlayCollector<GroundImageState>()
    public let rasterLayerCollector = OverlayCollector<RasterLayerState>()

    public init() {}

    public func clear() {
        markerCollector.clear()
        circleCollector.clear()
        polylineCollector.clear()
        polygonCollector.clear()
        groundImageCollector.clear()
        rasterLayerCollector.clear()
    }
}
