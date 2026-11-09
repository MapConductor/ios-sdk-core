import XCTest

@testable import MapConductorCore

/// ``StrategyMarkerController/clear()`` は他のコントローラの clear() と同じく
/// 「onRemove(全部) → 空にする → onPostProcess」で、何も描かれていない状態で終わること。
///
/// 以前は `strategy.clear()` で manager を空にするだけで、onRemove も onPostProcess も
/// 呼ばなかった。GL 系の描画担当は onPostProcess で manager から描き直すので、
/// clear() の後もマーカーが地図に残る。android-sdk-core / js-sdk-core の同名テストと同じ。
final class StrategyMarkerClearOrderTests: XCTestCase {
    private let camera = MapCameraPosition(
        position: GeoPoint(latitude: 35.0, longitude: 139.0),
        zoom: 10,
        visibleRegion: VisibleRegion(bounds: GeoRectBounds(
            southWest: GeoPoint(latitude: 34.0, longitude: 138.0),
            northEast: GeoPoint(latitude: 36.0, longitude: 140.0)
        ))
    )

    private func markers() -> [MarkerState] {
        [
            MarkerState(position: GeoPoint(latitude: 35.0, longitude: 139.0), id: "m1"),
            MarkerState(position: GeoPoint(latitude: 35.1, longitude: 139.1), id: "m2"),
        ]
    }

    /// GL 系の描画担当: onRemove では地図に触らず、onPostProcess で manager の全部を描き直す。
    @MainActor
    private final class GlRenderer: MarkerOverlayRendererProtocol {
        typealias ActualMarker = String
        let manager: MarkerManager<String>
        var drawn: [String] = []
        var removed: [String] = []
        var animateStartListener: OnMarkerEventHandler?
        var animateEndListener: OnMarkerEventHandler?
        init(_ manager: MarkerManager<String>) { self.manager = manager }
        func onAdd(data: [MarkerOverlayAddParams]) async -> [String?] { data.map { $0.state.id } }
        func onChange(data: [MarkerOverlayChangeParams<String>]) async -> [String?] { data.map { $0.current.state.id } }
        func onRemove(data: [MarkerEntity<String>]) async { removed += data.map { $0.state.id } }
        func onAnimate(entity: MarkerEntity<String>) async {}
        func onPostProcess() async { drawn = manager.allEntities().map { $0.state.id }.sorted() }
    }

    /// 渡されたマーカーを全部描くストラテジ。描いた状態は manager へ直接登録する。
    private final class DrawAllStrategy: MarkerRenderingStrategyProtocol {
        typealias ActualMarker = String
        let markerManager = MarkerManager<String>()
        var cleared = 0

        func clear() {
            cleared += 1
            markerManager.clear()
        }

        func onAdd<Renderer: MarkerOverlayRendererProtocol>(
            data: [MarkerState],
            viewport _: GeoRectBounds,
            renderer: Renderer
        ) async -> Bool where Renderer.ActualMarker == String {
            for state in data {
                markerManager.registerEntity(MarkerEntity(marker: state.id, state: state, isRendered: true))
            }
            await renderer.onPostProcess()
            return true
        }

        func onUpdate<Renderer: MarkerOverlayRendererProtocol>(
            state _: MarkerState,
            viewport _: GeoRectBounds,
            renderer _: Renderer
        ) async -> Bool where Renderer.ActualMarker == String { true }

        func onCameraChanged<Renderer: MarkerOverlayRendererProtocol>(
            mapCameraPosition _: MapCameraPosition,
            renderer _: Renderer
        ) async where Renderer.ActualMarker == String {}
    }

    @MainActor
    func testClearLeavesNothingDrawnAndKeepsTheStrategyReset() async {
        let strategy = DrawAllStrategy()
        let renderer = GlRenderer(strategy.markerManager)
        let controller = StrategyMarkerController(strategy: strategy, renderer: renderer)
        await controller.onCameraChanged(mapCameraPosition: camera)
        await controller.add(data: markers())
        XCTAssertEqual(renderer.drawn, ["m1", "m2"])

        await controller.clear()

        XCTAssertEqual(renderer.removed.sorted(), ["m1", "m2"])
        XCTAssertEqual(strategy.cleared, 1)
        XCTAssertEqual(renderer.drawn, [])
    }

    @MainActor
    func testClearDropsMarkersWaitingForTheFirstCamera() async {
        let strategy = DrawAllStrategy()
        let renderer = GlRenderer(strategy.markerManager)
        let controller = StrategyMarkerController(strategy: strategy, renderer: renderer)
        await controller.add(data: markers()) // カメラ前なので保留
        await controller.clear()
        await controller.onCameraChanged(mapCameraPosition: camera)
        XCTAssertEqual(renderer.drawn, [])
    }

    @MainActor
    func testMarkersSentAgainAfterClearAreDrawnAgain() async {
        let strategy = DrawAllStrategy()
        let renderer = GlRenderer(strategy.markerManager)
        let controller = StrategyMarkerController(strategy: strategy, renderer: renderer)
        await controller.onCameraChanged(mapCameraPosition: camera)
        await controller.add(data: markers())
        await controller.clear()
        await controller.add(data: markers())
        XCTAssertEqual(renderer.drawn, ["m1", "m2"])
    }
}
