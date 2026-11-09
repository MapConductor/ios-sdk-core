import XCTest

@testable import MapConductorCore

/// `clearOverlays()` が strategy（クラスタリングなど）のマーカーも消すこと。
///
/// 各プロバイダの `clearOverlays()` は自分のオーバーレイのコントローラを clear した後に
/// ``MapServiceRegistry/clearMarkerRendering()`` を 1 回呼ぶ。これがレジストリに登録された
/// ``MarkerRenderingSupport``（``StrategyMarkerManager``）の ``StrategyMarkerManager/clearMarkers()`` に届き、
/// GL 型の描画担当（onPostProcess で manager の全部を描く）でも何も描かれていない状態で終わること。
/// 送り直したら（次の syncMarkers）もう一度描かれること。
@MainActor
final class MarkerRenderingClearTests: XCTestCase {
    private let camera = MapCameraPosition(
        position: GeoPoint(latitude: 35.0, longitude: 139.0),
        zoom: 10,
        visibleRegion: VisibleRegion(bounds: GeoRectBounds(
            southWest: GeoPoint(latitude: 34.0, longitude: 138.0),
            northEast: GeoPoint(latitude: 36.0, longitude: 140.0)
        ))
    )

    private let markers = [
        MarkerState(position: GeoPoint(latitude: 35.0, longitude: 139.0), id: "s1"),
        MarkerState(position: GeoPoint(latitude: 35.1, longitude: 139.1), id: "s2"),
    ]

    @MainActor
    private final class GlRenderer: MarkerOverlayRendererProtocol {
        typealias ActualMarker = String
        let manager: MarkerManager<String>
        var drawn: [String] = []
        var animateStartListener: OnMarkerEventHandler?
        var animateEndListener: OnMarkerEventHandler?
        init(_ manager: MarkerManager<String>) { self.manager = manager }
        func onAdd(data: [MarkerOverlayAddParams]) async -> [String?] { data.map { $0.state.id } }
        func onChange(data: [MarkerOverlayChangeParams<String>]) async -> [String?] { data.map { $0.current.state.id } }
        func onRemove(data _: [MarkerEntity<String>]) async {}
        func onAnimate(entity _: MarkerEntity<String>) async {}
        func onPostProcess() async { drawn = manager.allEntities().map { $0.state.id }.sorted() }
    }

    private final class DrawAllStrategy: MarkerRenderingStrategyProtocol {
        typealias ActualMarker = String
        let markerManager = MarkerManager<String>()
        func clear() { markerManager.clear() }
        func onAdd<Renderer: MarkerOverlayRendererProtocol>(
            data: [MarkerState], viewport _: GeoRectBounds, renderer: Renderer
        ) async -> Bool where Renderer.ActualMarker == String {
            markerManager.clear()
            for state in data {
                markerManager.registerEntity(MarkerEntity(marker: state.id, state: state, isRendered: true))
            }
            await renderer.onPostProcess()
            return true
        }
        func onUpdate<Renderer: MarkerOverlayRendererProtocol>(
            state _: MarkerState, viewport _: GeoRectBounds, renderer _: Renderer
        ) async -> Bool where Renderer.ActualMarker == String { true }
        func onCameraChanged<Renderer: MarkerOverlayRendererProtocol>(
            mapCameraPosition _: MapCameraPosition, renderer _: Renderer
        ) async where Renderer.ActualMarker == String {}
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testClearOverlaysPathClearsStrategyMarkersAndResendDrawsThemAgain() async {
        let strategy = DrawAllStrategy()
        var renderer: GlRenderer?
        let manager = StrategyMarkerManager<String, GlRenderer>(
            makeRenderer: { s in
                let r = GlRenderer(s.markerManager)
                renderer = r
                return r
            },
            currentCamera: { [camera] in camera }
        )
        let registry = MutableMapServiceRegistry()
        registry.put(MarkerRenderingSupportKey.self, manager)

        manager.beginContentPass()
        XCTAssertTrue(manager.connect(strategy: AnyMarkerRenderingStrategy(strategy), markers: markers))
        manager.endContentPass()
        await waitUntil { renderer?.drawn == ["s1", "s2"] }
        XCTAssertEqual(renderer?.drawn, ["s1", "s2"])

        await registry.clearMarkerRendering()

        XCTAssertEqual(renderer?.drawn, [])
        XCTAssertTrue(strategy.markerManager.allEntities().isEmpty)
        XCTAssertTrue(manager.latestMarkers.isEmpty)
        XCTAssertNotNil(manager.controller, "strategy stays connected")

        // 同じインスタンスの一覧が送られ続ける間は描かない（clear 直後の body の再評価で戻らない）。
        manager.beginContentPass()
        manager.connect(strategy: AnyMarkerRenderingStrategy(strategy), markers: markers)
        manager.endContentPass()
        manager.flush()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(renderer?.drawn, [])

        // 作り直した state（同じ id）を送り直すと描き直される（コレクタの clear 後の再追加と同じ）。
        let resent = markers.map { MarkerState(position: $0.position, id: $0.id) }
        manager.beginContentPass()
        manager.connect(strategy: AnyMarkerRenderingStrategy(strategy), markers: resent)
        manager.endContentPass()
        await waitUntil { renderer?.drawn == ["s1", "s2"] }
        XCTAssertEqual(renderer?.drawn, ["s1", "s2"])
    }

    func testClearMarkerRenderingWithoutSupportDoesNothing() async {
        await MutableMapServiceRegistry().clearMarkerRendering()
    }
}
