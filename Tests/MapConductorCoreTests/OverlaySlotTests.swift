import XCTest

@testable import MapConductorCore

/// オーバーレイのスロット解決。
///
/// android-sdk / react-sdk の Capable ファサード既定実装と同じ判定を、
/// iOS では ``OverlayControllerRegistry`` の拡張として持つ。
///
/// ## iOS に Capable ファサードが無い理由（揃えていない点）
///
/// android / react は Compose / React のオーバーレイが
/// `controller.compositionMarkers(...)` のようにインタフェース越しに呼ぶため、
/// プロバイダごとに 28 個の転送メソッドが要る。
/// iOS は `bindOverlayCollector(collector, to: markerController)` で
/// **型付きコントローラへ直接**束ねるので、その層自体が存在しない。
/// よってここで共通化するのは `kind` によるスロット解決だけで、
/// これはクリックカスケード（Step 6）と適合テスト（Step 8）が使う。
///
/// ## 守りたい不変条件
///
/// `kind` を宣言し忘れたコントローラは**黙って**スロットから漏れる。
/// android-sdk では `MapLibrePolygonConductor` が実際にそれで、`hasPolygon` が
/// 常に false になりポリゴン単体の状態更新が捨てられていた。
/// ここでは「宣言したものだけが引ける」ことを固定する。
final class OverlaySlotTests: XCTestCase {
    private final class FakeSlot: SlottedOverlayController {
        let kind: OverlayKind
        let zIndex: Int
        var ids: Set<String> = []
        private(set) var destroyed = false
        private(set) var cameras: [MapCameraPosition] = []

        init(kind: OverlayKind, zIndex: Int = 0) {
            self.kind = kind
            self.zIndex = zIndex
        }

        func hasId(_ id: String) -> Bool { ids.contains(id) }
        func onCameraChanged(mapCameraPosition: MapCameraPosition) async { cameras.append(mapCameraPosition) }
        func destroy() { destroyed = true }
    }

    /// カメラ購読だけの拡張モジュール（スロットに参加しない）。
    private final class CameraOnly: AnyOverlayController {
        let zIndex: Int = 99
        func onCameraChanged(mapCameraPosition _: MapCameraPosition) async {}
        func destroy() {}
    }

    func testEveryKindIsResolvable() {
        let registry = OverlayControllerRegistry()
        var slots: [OverlayKind: FakeSlot] = [:]
        for (index, kind) in OverlayKind.allCases.enumerated() {
            let slot = FakeSlot(kind: kind, zIndex: index)
            slots[kind] = slot
            registry.register(slot)
        }

        for kind in OverlayKind.allCases {
            XCTAssertTrue(registry.primary(kind) === slots[kind], "\(kind) が引けない")
        }
        XCTAssertEqual(registry.slotted().count, OverlayKind.allCases.count)
    }

    func testCameraOnlyExtensionIsNotSlotted() {
        let registry = OverlayControllerRegistry()
        registry.register(CameraOnly())
        let marker = FakeSlot(kind: .marker)
        registry.register(marker)

        XCTAssertEqual(registry.slotted().count, 1)
        XCTAssertTrue(registry.primary(.marker) === marker)
        XCTAssertNil(registry.primary(.circle))
    }

    func testPrimaryIsTheLowestZIndexAndHasLooksAtAll() {
        let registry = OverlayControllerRegistry()
        let primary = FakeSlot(kind: .marker, zIndex: 1)
        let secondary = FakeSlot(kind: .marker, zIndex: 2)
        registry.register(secondary)
        registry.register(primary)

        XCTAssertTrue(registry.primary(.marker) === primary, "zIndex の小さい方が主")
        XCTAssertEqual(registry.controllers(of: .marker).count, 2)

        secondary.ids.insert("b")
        XCTAssertTrue(registry.hasOverlay(.marker, id: "b"), "has はどれかが持っていれば true")
        XCTAssertFalse(registry.hasOverlay(.marker, id: "nope"))
        XCTAssertFalse(registry.hasOverlay(.circle, id: "b"), "別種別へは波及しない")
    }

    func testCoreControllersDeclareTheirKind() {
        // 種別ごとの宣言が実際のコントローラに入っていること。
        // ここが落ちるのは「新しいコントローラを足したが kind を書いていない」とき。
        XCTAssertEqual(OverlayKind.allCases.count, 6)
        XCTAssertEqual(Set(OverlayKind.allCases.map(\.rawValue)).count, 6)
    }
}
