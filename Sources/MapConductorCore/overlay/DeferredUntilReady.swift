import Foundation

/// 描画側がまだ受け取れない期間、入力を**保留**する門。
///
/// スタイル差し替え型のプロバイダ（Mapbox / MapLibre / MapTiler）は、スタイルが載るまで
/// ソースもレイヤも存在しない。その間に流し込んでも描かれないうえ、件数が多いと
/// スタイル読み込みと取り込みがメインアクターを取り合って UI が固まる。
///
/// **捨てるのではなく遅らせる**のがこの型の役目。最後に渡された入力だけを覚え、
/// ``markReady()`` の時点で一度だけ流す。
///
/// ## なぜ必要か（消さないこと）
///
/// android-sdk には対応するものが無い。あちらは待ちが Mapbox / MapLibre SDK 自身の
/// `getStyle { }` コールバックにあり、重い描画がスタイル準備後へ自然に回るので、SDK 側で
/// 門番を書く必要が無いだけ。iOS の各コントローラの `add(data:)` は取り込みと描画往復を
/// 一息にやるため、呼ぶ側で待たないと同じ効果にならない。
///
/// 実際に一度この門を「android に合わせる」として撤去したところ、Bunch of Markers
/// （郵便局 2 万件超）でプロバイダを切り替えたときに **UI が 51 秒固まった**（門ありなら
/// 3.1 秒）。`LargeMarkerSwitchUITests` がこの差を固定している。
///
/// ## コア内の類似物との関係
///
/// `OverlayCollector` の `shouldApply` + `flush()`、`StrategyMarkerManager` の
/// `shouldAddMarkers` + `flush()` も同じ「準備できるまで保留して、できたら流す」形。
/// あちらは準備状態をビュー側が持つので述語を受け取る。この型は準備状態を自分で持つ
/// （コントローラでは「`onStyleLoaded` が呼ばれたか」がそのまま準備状態のため）。
@MainActor
public final class DeferredUntilReady<Input> {
    /// 受け取れる状態か。
    public private(set) var isReady = false

    /// 最後に渡された入力。準備前でも参照できる。
    public private(set) var latest: Input?

    private let apply: (Input) -> Void

    /// - Parameter apply: 準備できているときに入力を流す先。
    public init(apply: @escaping (Input) -> Void) {
        self.apply = apply
    }

    /// 入力を渡す。準備できていれば即適用、まだなら保留して ``markReady()`` を待つ。
    public func submit(_ input: Input) {
        latest = input
        guard isReady else { return }
        apply(input)
    }

    /// 準備完了。保留中の入力があれば流す。
    ///
    /// 冪等。スタイルは繰り返し読み込まれる（地図デザインの変更）ので、2 回目以降に
    /// 呼ばれても壊れないこと。流す先の `add(data:)` は差分で弾くので実質ただの走査で終わる。
    public func markReady() {
        isReady = true
        guard let latest else { return }
        apply(latest)
    }

    /// 準備前に戻し、保留も捨てる（`unbind` / 破棄時）。
    public func reset() {
        isReady = false
        latest = nil
    }
}
