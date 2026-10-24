import Foundation

/// 「同じマーカー一覧の再送」を入口で見抜く門番。
///
/// SwiftUI はカメラが動くたびに map view の body を再評価し、そのたびに
/// `updateContent` が各プロバイダの `syncMarkers` へ**全マーカー**を運んでくる。
/// ピンチ中はそれが連続する。一覧そのものは変わっていないのに、各コントローラは
/// 毎回 id の Set を 2 つ作り、辞書を組み直し、`hasEntity` をマーカーの数だけ
/// 呼んでいた（= ロックをマーカーの数だけ取っていた）。東京の街路樹 144,183 本
/// では 1 回あたり数百 ms がメインスレッドに乗り、ピンチが 0.3〜0.8 秒刻みで
/// 凍る -- 実機の画面収録で操作時間の 89% が凍結だった。Android は camera の
/// 変化で content の再構築が走らないため、この経路自体が無い。iOS だけ重い、
/// の実体がこれ。
///
/// 比べるのは**参照だけ**。順序込みの同一性が一致すれば、購読も辞書も既に
/// 正しく、位置などの変化は各 state の購読が届ける。O(n) だがアロケーションが
/// 無いので 144k 件で 1ms 未満。9 本のプロバイダコントローラがすべて同じ
/// `syncMarkers` の形を持つので、判定だけをここに共通化する。
///
/// スレッドは呼び出し側（メインアクター）に従う。自前のロックは持たない。
@_spi(MapConductorDriver)
public struct MarkerListIdentity {
    private var lastSynced: [ObjectIdentifier] = []

    public init() {}

    /// 一覧が前回と同一（同じ state インスタンスが同じ順で同じ数）なら false。
    /// 変わっていれば覚え直して true。
    ///
    /// 名前は「処理すべきか」。false のときに呼び出し側がやってよいのは、
    /// 一覧と無関係な O(1) の後始末（サーバ再起動の検知など）だけ。
    public mutating func shouldProcess(_ markers: [Marker]) -> Bool {
        if markers.count == lastSynced.count, !markers.isEmpty {
            var identical = true
            for (at, marker) in markers.enumerated()
            where lastSynced[at] != ObjectIdentifier(marker.state) {
                identical = false
                break
            }
            if identical { return false }
        }
        lastSynced = markers.map { ObjectIdentifier($0.state) }
        return true
    }
}
