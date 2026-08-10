import Foundation

/// 同期の座標変換を要求する機能が、それを使えないプロバイダ上で動くときに
/// 「黙って無反応」にならないようにするための入口。
///
/// ## なぜ要るか
///
/// ``MapViewHolderProtocol/toScreenOffset(position:)`` /
/// ``MapViewHolderProtocol/fromScreenOffsetSync(offset:)`` が nil を返す理由は 2 つある。
///
///  1. その点が画面外・地表外（正常。毎フレーム起きる）
///  2. **そのプロバイダが同期変換を持たない**（恒久的）
///
/// 呼び出し側は nil からこの 2 つを区別できない。2 の場合、機能が一切動かないのに
/// 何のログも出ないことになる。区別できるのは
/// ``MapCapability/screenProjectionSync`` の宣言だけなので、ここで見る。
///
/// ## Unsupported は「機能が動かない」ときだけ宣言すること
///
/// ホルダーの API が同期変換を持たないことと、機能が動かないことは**別**。
/// ios-for-longdo は同期変換を持たないが、オーバーレイの配置は Longdo の
/// JS ブリッジを使う独自経路で行っており、InfoBubble もマーカーも実際に動く。
/// だから Longdo の宣言は ``MapCapabilityStatus/degraded(_:)`` であって
/// `unsupported` ではない。
///
/// ここで見るのは**機能を落としてよいか**なので、`unsupported` と明示されたときだけ
/// 落とす。`degraded` / `approximated` は動かす。
///
/// ## Unknown を非対応と断定しない
///
/// 宣言が無い（``MapCapabilityStatus/unknown``）＝「まだ宣言していない」であって
/// 「使えない」ではない。地図の初期化途中もここに入る。**報告するのは
/// `unsupported` と明示されているときだけ**にして、未宣言のプロバイダを誤って告発しない。
public enum ScreenProjectionRequirement {
    /// 同期投影が使えるか。使えないと**分かっている**ときだけ 1 回報告して `false` を返す。
    ///
    /// - Parameters:
    ///   - registry: 地図の ``MapServiceRegistry``。
    ///   - provider: ログに出すプロバイダ名。
    ///   - feature: ログに出す機能名（"InfoBubble" など）。何が動かないのかを
    ///     読み手に伝えるため、capability の id ではなくこちらを出す。
    /// - Returns: 使える見込みがあれば `true`。`false` なら呼び出し側は機能を落とす。
    @discardableResult
    public static func check(
        registry: MapServiceRegistry,
        provider: String,
        feature: String
    ) -> Bool {
        let status = registry.capabilityStatus(.screenProjectionSync)
        guard status.isKnownUnsupported else { return true }
        MapDiagnostics.report(
            capability: .screenProjectionSync,
            level: .unsupported,
            provider: provider,
            reason: status.reason ?? "this provider has no synchronous coordinate conversion",
            subject: feature
        )
        return false
    }
}
