import Foundation

/// 「この宛先へのリクエストにはこのヘッダを載せる」という 1 件の規則。
public struct RasterHeaderRule: Equatable {
    /// 適用先ホスト（小文字化済み）。
    public let host: String
    /// 適用先ポート。URL に明示が無ければ `nil`。
    public let port: Int?
    /// 差し替える User-Agent。空文字・空白のみは `nil` に丸める。
    public let userAgent: String?
    /// 追加ヘッダ。
    public let extraHeaders: [String: String]

    public init(host: String, port: Int?, userAgent: String?, extraHeaders: [String: String]) {
        self.host = host.lowercased()
        self.port = port
        self.userAgent = userAgent
        self.extraHeaders = extraHeaders
    }
}

/// `RasterLayerState` の `userAgent` / `extraHeaders` を、**宛先ホスト単位**で管理する。
///
/// ## なぜホスト単位か
///
/// MapLibre 系のプロバイダはリクエスト書き換えのフックが
/// `MLNNetworkConfiguration.sharedManager`、つまり**プロセス全体に 1 つ**しかない。
/// 何も考えずにここへヘッダを差すと、ラスタレイヤ用のヘッダが**ベースマップの
/// スタイルやベクタタイルの取得にも載る**。ラスタレイヤの既定 User-Agent は
/// 空ではない（`MapConductor/RasterLayerAgent(...)`）ので、ラスタレイヤを 1 枚
/// 置いただけで地図全体の User-Agent が書き換わってしまう。
///
/// 宛先ホストで絞れば、そのラスタタイルを配信しているサーバ宛だけに載る。
///
/// ## なぜ共有シングルトンか
///
/// `ios-for-maplibre` と `ios-for-maptiler` は別パッケージだが、SPM 上は**同じ
/// MapLibre バイナリ**に解決される。つまり `MLNNetworkConfiguration.sharedManager` も
/// 1 つで、両者が別々に delegate を差すと後勝ちで一方が無効になる。規則の置き場を
/// core の ``shared`` に一本化しておけば、どちらの delegate が最終的に載っていても
/// 同じ結果になる。
///
/// フックは**バックグラウンドスレッドから呼ばれる**（MapLibre のヘッダに明記がある）ため、
/// 全アクセスをロックで守る。
public final class RasterHeaderRuleSet: @unchecked Sendable {
    /// プロバイダ横断で共有する実体。
    public static let shared = RasterHeaderRuleSet()

    private let lock = NSLock()
    /// 登録元（コントローラ）ごとの規則。コントローラが消えたら丸ごと外す。
    private var rulesByOwner: [ObjectIdentifier: [RasterHeaderRule]] = [:]

    public init() {}

    /// 規則が 1 件も無いか。`true` のときフックを外してよい（既定の挙動に戻す）。
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rulesByOwner.allSatisfy { $0.value.isEmpty }
    }

    /// 登録元 1 つ分の規則を差し替える。
    public func setRules(_ rules: [RasterHeaderRule], owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        lock.lock()
        if rules.isEmpty {
            rulesByOwner.removeValue(forKey: key)
        } else {
            rulesByOwner[key] = rules
        }
        lock.unlock()
    }

    /// 登録元 1 つ分の規則を外す（`unbind` / 破棄時）。
    public func removeRules(owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        lock.lock()
        rulesByOwner.removeValue(forKey: key)
        lock.unlock()
    }

    /// `url` に適用すべきヘッダ。該当が無ければ `nil`。
    ///
    /// 同じホストに複数のラスタレイヤがあり値が食い違う場合、ヘッダ書き換えフックが
    /// プロセス全体に 1 つしかない以上どれか 1 つしか選べない。**後勝ち**にはせず、
    /// ホストとポートが一致する最初の規則を使う（順序が決まるので結果が再現する）。
    public func headers(for url: URL) -> (userAgent: String?, extraHeaders: [String: String])? {
        guard let host = url.host?.lowercased() else { return nil }
        let port = url.port

        lock.lock()
        let all = rulesByOwner.keys.sorted { $0.hashValue < $1.hashValue }.flatMap { rulesByOwner[$0] ?? [] }
        lock.unlock()

        for rule in all where rule.host == host && (rule.port == nil || rule.port == port) {
            if rule.userAgent == nil && rule.extraHeaders.isEmpty { continue }
            return (rule.userAgent, rule.extraHeaders)
        }
        return nil
    }

    /// レイヤの状態から規則を組み立てる。ヘッダ指定が無い状態は規則を作らない。
    public static func makeRules(from states: [RasterLayerState]) -> [RasterHeaderRule] {
        var rules: [RasterHeaderRule] = []
        for state in states {
            guard let url = URL(string: templateUrlString(of: state.source)),
                  let host = url.host,
                  !host.isEmpty
            else { continue }

            let trimmedAgent = state.userAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
            let userAgent = (trimmedAgent?.isEmpty == false) ? trimmedAgent : nil
            let extraHeaders = state.extraHeaders ?? [:]
            if userAgent == nil && extraHeaders.isEmpty { continue }

            rules.append(
                RasterHeaderRule(host: host, port: url.port, userAgent: userAgent, extraHeaders: extraHeaders)
            )
        }
        return rules
    }

    /// ヘッダを載せられないプロバイダが、黙って無視せずに知らせるための共通口。
    ///
    /// ネイティブ SDK がリクエストの書き換えを一切公開していないプロバイダがある
    /// （ArcGIS / TomTom / Longdo / Mapbox）。指定が効かないこと自体は仕様として
    /// ドキュメントに書くが、**実行時にも分かる**ようにしておかないと、利用者は
    /// 「認証が通らない理由」を自分のサーバ側で探すことになる。
    ///
    /// - Parameters:
    ///   - provider: プロバイダ名（ログに出す）。
    ///   - state: 対象のレイヤ。
    ///   - supportsUserAgent: `userAgent` だけは載せられるプロバイダは `true`
    ///     （GoogleMaps iOS。`extraHeaders` のみ無視される）。
    public static func warnUnsupported(
        provider: String,
        state: RasterLayerState,
        supportsUserAgent: Bool = false
    ) {
        var ignored: [String] = []
        if !supportsUserAgent {
            let ua = state.userAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ua, !ua.isEmpty, ua != RasterLayerState.defaultUserAgent {
                ignored.append("userAgent")
            }
        }
        if let headers = state.extraHeaders, !headers.isEmpty {
            ignored.append("extraHeaders")
        }
        guard !ignored.isEmpty else { return }

        // 同じレイヤで何度も出さない。`updateLayerProperties` は頻繁に走る。
        let key = "\(provider)|\(state.id)|\(ignored.joined(separator: ","))"
        warnedLock.lock()
        let isNew = warnedKeys.insert(key).inserted
        warnedLock.unlock()
        guard isNew else { return }

        NSLog(
            "[MapConductor] %@ RasterLayer: %@ is not supported on iOS and will be ignored. id=%@",
            provider,
            ignored.joined(separator: " / "),
            state.id
        )
    }

    private static let warnedLock = NSLock()
    private nonisolated(unsafe) static var warnedKeys = Set<String>()

    /// `RasterLayerSource` から、ホストを取り出せる形の URL 文字列にする。
    ///
    /// `{z}/{x}/{y}` のような差し込み記法が入ったままだと `URL(string:)` が
    /// 失敗することがあるので、最初の `{` より前で切る。ホストが取れれば十分。
    private static func templateUrlString(of source: RasterLayerSource) -> String {
        let raw: String
        switch source {
        case let .urlTemplate(template, _, _, _, _, _): raw = template
        case let .tileJson(url): raw = url
        case let .arcGisService(serviceUrl): raw = serviceUrl
        }
        guard let brace = raw.firstIndex(of: "{") else { return raw }
        return String(raw[raw.startIndex..<brace])
    }
}
