import Foundation

/// ``OverlayHitResolver/resolve(_:position:order:)`` が返す「当たり」。
///
/// 配送は ``dispatch()`` を呼ぶまで起きない。解決した時点では何の副作用も無い。
public final class OverlayHit {
    /// 当たったオーバーレイの種別。
    public let kind: OverlayKind

    /// アプリへ渡すクリック座標。
    ///
    /// ポリラインだけ「線上の最近傍点」で、他はタップ点そのもの。
    /// `[-180,180]` への正規化は各イベント型の生成時に行われる。
    public let clicked: GeoPointProtocol

    private let deliver: () -> Void

    public init(kind: OverlayKind, clicked: GeoPointProtocol, deliver: @escaping () -> Void) {
        self.kind = kind
        self.clicked = clicked
        self.deliver = deliver
    }

    /// `state.onClick` と非推奨のコントローラリスナーへ配送する。
    public func dispatch() { deliver() }
}

/// タップ座標から「どのオーバーレイに当たったか」を、正準順で 1 つだけ決める。
///
/// 9 プロバイダが同じ 20〜40 行のカスケードを各自持っていたものの集約。
/// **しかも順序が揃っていなかった**（ios-for-maplibre は
/// circle → polyline → polygon → groundImage、android の正準は
/// circle → groundImage → polyline → polygon）。ここで 1 本にする。
///
/// ## 決めているのは「順序」と「先勝ち」だけ
///
/// 当たり判定そのものは各 Manager（``PolygonManager`` 等）が既にコアで持っている。
/// 重複していたのは常に**それを呼ぶ配線**の側なので、ここで畳む。
///
/// ## ポリラインだけ配送座標がタップ点ではない
///
/// ポリラインは「線上の最近傍点」を ``OverlayHit/clicked`` にする。線の上をきっかり
/// タップすることはないので、タップ点をそのまま返すと線から外れた座標がアプリへ渡る。
/// 3 プラットフォーム共通の既存契約。
public enum OverlayHitResolver {
    /// マーカーを除いた正準順。
    ///
    /// マーカーがここに無いのは「順序の外」という意味ではなく、
    /// **判定手段が違う**（地理座標ではなく画面座標での矩形判定）ため。
    /// 実際の全体順序は marker → circle → groundImage → polyline → polygon → map。
    public static let canonicalOrder: [OverlayKind] = [
        .circle,
        .groundImage,
        .polyline,
        .polygon,
    ]

    /// `order` の種別順に登録済みコントローラを試し、最初に `probe` が非 nil を返したものを返す。
    ///
    /// 同じ種別に複数のコントローラが登録されていることがある（マーカークラスタリングは
    /// marker 種別で追加登録する）ので、種別の中では zIndex 昇順に見る。
    ///
    /// スロットに参加していないコントローラ（カメラ購読のためだけに登録する拡張モジュール等）は
    /// 種別を持たないので対象外。
    public static func firstHit<T>(
        _ controllers: [any AnyOverlayController],
        order: [OverlayKind] = canonicalOrder,
        probe: (any SlottedOverlayController) -> T?
    ) -> T? {
        let slotted = controllers.compactMap { $0 as? any SlottedOverlayController }
        for kind in order {
            for controller in slotted where controller.kind == kind {
                if let hit = probe(controller) { return hit }
            }
        }
        return nil
    }

    /// `position` のタップが当たったオーバーレイを 1 つ返す。当たらなければ nil。
    ///
    /// 種別ごとの当たり判定と配送方法は各コントローラの
    /// ``SlottedOverlayController/resolveTap(position:)`` が持つ。ここは順序だけを決める。
    public static func resolve(
        _ controllers: [any AnyOverlayController],
        position: GeoPointProtocol,
        order: [OverlayKind] = canonicalOrder
    ) -> OverlayHit? {
        firstHit(controllers, order: order) { $0.resolveTap(position: position) }
    }
}

public extension OverlayControllerRegistry {
    /// オーバーレイ（マーカー以外）のタップを、正準順に 1 つだけ配送する。
    ///
    /// マーカーを含まないので、ネイティブのオーバーレイクリックリスナーから
    /// 呼ぶこともできる（ネイティブのリスナーを**発火のきっかけ**としてのみ使い、
    /// どのエンティティかの判定はここへ委ねる形）。
    ///
    /// - Returns: 何かに当たって配送したら true。
    @discardableResult
    func dispatchOverlayTap(
        position: GeoPointProtocol,
        order: [OverlayKind] = OverlayHitResolver.canonicalOrder
    ) -> Bool {
        guard let hit = OverlayHitResolver.resolve(all(), position: position, order: order) else { return false }
        hit.dispatch()
        return true
    }
}

public extension MapViewControllerProtocol {
    /// オーバーレイのタップを、正準順に 1 つだけ配送する。
    ///
    /// android-sdk / react-sdk の `BaseMapViewController.dispatchOverlayTap` に対応する。
    /// iOS には共通の基底コントローラが無いので、登録簿の拡張として提供する。
    @discardableResult
    func dispatchOverlayTap(position: GeoPointProtocol) -> Bool {
        overlayControllers.dispatchOverlayTap(position: position)
    }
}
