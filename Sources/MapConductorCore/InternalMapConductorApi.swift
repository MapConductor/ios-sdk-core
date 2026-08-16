import Foundation

/// 地図SDKドライバー（`ios-for-*`）と拡張モジュールのための API に付ける印の取り決め。
///
/// android-sdk の `@InternalMapConductorApi`（`@RequiresOptIn` の注釈）に対応する。
/// **Swift では新しい属性を足さず、標準の `@_spi(MapConductorDriver)` を使う。**
///
/// ## なぜ印が要るか
///
/// MapConductor は「アプリ開発者向け API は凍結、ドライバー実装点は変えてよい」という
/// 方針で共通化を進めている。ところがモジュールをまたぐドライバーへ公開する API は
/// `public` にせざるを得ず、そのままではアプリ向け API と区別がつかない。
///
/// ## なぜ @_spi でよいか
///
/// `@_spi(MapConductorDriver)` を付けた宣言は
///
///  - **`.swiftinterface` に載らない**（`.private.swiftinterface` にだけ載る）。
///    つまり `scripts/api-surface.sh` が記録する公開 API サーフェスから自動的に外れ、
///    ドライバー実装点を触っても凍結ゲートが鳴らない。
///  - インポート側が `@_spi(MapConductorDriver) import MapConductorCore` と
///    明示的に書かない限り見えない。アプリが偶然使ってしまうことがない。
///
/// android は注釈を自前で読み飛ばす手当てが要ったが、iOS はコンパイラ側で済んでいる。
///
/// ## 使いどころ
///
/// ドライバーだけが実装・呼び出しする型やメンバーに付ける。例:
/// オーバーレイレンダラの契約、コントローラの基底が提供する配線用メンバー、
/// ネイティブイベントの橋渡し。
///
/// アプリ開発者が触るもの（`MarkerState` などの状態、`MapViewState`、
/// 各 `*MapView`）には**付けないこと**。
///
/// ## 使い方
///
/// ```swift
/// @_spi(MapConductorDriver)
/// public protocol SomeDriverContract { … }
/// ```
///
/// ドライバー側:
///
/// ```swift
/// @_spi(MapConductorDriver) import MapConductorCore
/// ```
///
/// ## 印を付け忘れたら
///
/// `scripts/api-surface.sh check` が差分として鳴らす。そこで初めて「これはアプリ向けか
/// ドライバー向けか」を考えることになる。鳴ったからといって黙って `dump` し直さないこと。
public enum InternalMapConductorApi {
    /// `@_spi` に渡すグループ名。文字列としてはコンパイラに渡らない（属性は
    /// リテラルしか受け付けない）が、名前を 1 箇所に書いておくための宣言。
    public static let spiGroup = "MapConductorDriver"
}
