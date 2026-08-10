import Foundation

/// オーバーレイの種別。
///
/// クリックカスケード（``OverlayHitResolver``）と適合テスト
/// （`MapDriverConformance.checkOverlaySlots`）が、登録済みの
/// ``AnyOverlayController`` を振り分けるのに使う。
///
/// Swift のジェネリクスは型消去されるので状態の型では判別できない。かといって
/// メタタイプを持たせると、状態型がプロバイダ固有になったときに破綻する。
/// 種別という別の軸で持つ。
///
/// **描画順（zIndex）とは別軸**であることに注意。現状 polygon(3) > groundImage(2) だが、
/// クリックの探索は groundImage が先。
///
/// android-sdk / react-sdk にも同名・同じ並びで置く。
public enum OverlayKind: String, CaseIterable, Sendable {
    case marker
    case circle
    case groundImage
    case polyline
    case polygon
    case rasterLayer
}

/// クリックカスケードとスロット解決に参加するオーバーレイコントローラ。
///
/// ## なぜ ``AnyOverlayController`` に省略可能で置かないか
///
/// 既定値を持たせると**宣言を忘れてもコンパイルが通り**、そのコントローラが
/// カスケードからも `hasXxx` からも黙って漏れる。android-sdk では実際に
/// `MapLibrePolygonConductor` / `MapboxPolygonConductor` がそれで、
/// `hasPolygon` が常に false になりポリゴン単体の状態更新が捨てられていた
/// （ビルドも API チェックも既存のユニットテストも緑のまま）。
///
/// `kind` を**必須メンバ**にして、宣言忘れをコンパイルエラーにする。
/// カメラ購読のためだけに登録する拡張モジュール（ヒートマップなど）は
/// これに準拠しないので、スロットに巻き込まれない。
///
/// - Note: `resolveTap` は Step 6（クリックカスケード）でここへ足す。
public protocol SlottedOverlayController: AnyOverlayController {
    var kind: OverlayKind { get }

    /// この id のオーバーレイを保持しているか。`hasXxx` 相当の判定に使う。
    func hasId(_ id: String) -> Bool
}

public extension OverlayControllerRegistry {
    /// 登録済みのうちスロットに参加しているものだけ。
    func slotted() -> [any SlottedOverlayController] {
        all().compactMap { $0 as? any SlottedOverlayController }
    }

    /// この種別の**主**コントローラ（zIndex 昇順で最初のもの）。
    ///
    /// クラスタリングは同じ marker 種別で追加のコントローラを登録するが、
    /// composition の受け口は 1 つでよい（追加分はクラスタリング側が自分で駆動する）。
    func primary(_ kind: OverlayKind) -> (any SlottedOverlayController)? {
        slotted().first { $0.kind == kind }
    }

    /// この種別に登録されたすべてのコントローラ。
    func controllers(of kind: OverlayKind) -> [any SlottedOverlayController] {
        slotted().filter { $0.kind == kind }
    }

    /// `kind` のいずれかのコントローラがこの id を持っているか。
    func hasOverlay(_ kind: OverlayKind, id: String) -> Bool {
        controllers(of: kind).contains { $0.hasId(id) }
    }
}
