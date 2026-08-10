import Foundation

/// プロバイダが応えられなかった要求を報告する。
///
/// ``MapUISettingsDiagnostics/warnIfRequested(_:gesture:provider:reason:)`` を
/// 全 capability へ一般化したもの。元の実装が持っていた 2 つの正しい判断を
/// そのまま引き継いでいる:
///
///  1. **アプリが実際にその機能を要求したときだけ報告する。** 起動時に非対応一覧を
///     吐くとノイズになって読まれない。
///  2. **provider + capability + level ごとに 1 回だけ。** SwiftUI がカメラ移動の
///     たびに再評価してもコンソールが溢れない。
///
/// 出力先は ``sink`` で差し替えられる。テストからは sink を置き換えて検証する。
public enum MapDiagnostics {
    /// 報告の出力先。
    public typealias Sink = @Sendable (String) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _sink: Sink = { print("MapConductor: \($0)") }
    nonisolated(unsafe) private static var reported: Set<String> = []

    /// 既定はコンソール出力。テストや独自ロガーに差し替えられる。
    public static var sink: Sink {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _sink
        }
        set {
            lock.lock()
            _sink = newValue
            lock.unlock()
        }
    }

    /// 要求に応えられなかったことを 1 回だけ報告する。
    ///
    /// - Parameter subject: ログに出す名前。既定は ``MapCapability/id``。要求と設定名が
    ///   食い違う場合（ジェスチャ設定など）に上書きする。
    /// - Returns: 実際に報告したら true（同じ内容の 2 回目以降は false）。
    @discardableResult
    public static func report(
        capability: MapCapability,
        level: MapDiagnosticLevel,
        provider: String,
        reason: String,
        subject: String? = nil
    ) -> Bool {
        let key = "\(provider).\(capability.rawValue).\(level.rawValue)"
        lock.lock()
        let isNew = reported.insert(key).inserted
        let sink = _sink
        lock.unlock()
        guard isNew else { return false }
        sink("\(subject ?? capability.id) \(level.phrase) \(provider) (\(reason)); \(level.consequence)")
        return true
    }

    /// `requested` が true のとき（＝アプリがその機能を実際に要求したとき）だけ報告する。
    ///
    /// 要求していない機能について警告しても行動につながらないので黙る。
    @discardableResult
    public static func reportIfRequested(
        _ requested: Bool,
        capability: MapCapability,
        level: MapDiagnosticLevel,
        provider: String,
        reason: String,
        subject: String? = nil
    ) -> Bool {
        guard requested else { return false }
        return report(
            capability: capability,
            level: level,
            provider: provider,
            reason: reason,
            subject: subject
        )
    }

    /// テスト用フック — どの報告を済ませたかを忘れる。
    public static func resetWarnings() {
        lock.lock()
        reported.removeAll()
        lock.unlock()
    }
}

/// 要求に応えられなかった度合い。``MapCapabilityStatus`` と対応するが、
/// こちらは「いま起きた 1 回の出来事」を表す。
public enum MapDiagnosticLevel: String, Sendable {
    /// 出せない。
    case unsupported
    /// 出るが別物になる。
    case degraded
    /// 数値が近似になる。
    case approximated
    /// 要求を捨てた。
    case ignored

    var phrase: String {
        switch self {
        case .unsupported: return "is not supported by"
        case .degraded: return "is only partially supported by"
        case .approximated: return "is approximated by"
        case .ignored: return "cannot be changed on"
        }
    }

    var consequence: String {
        switch self {
        case .unsupported: return "the request is ignored."
        case .degraded: return "the result differs from other providers."
        case .approximated: return "values may differ slightly from other providers."
        case .ignored: return "the setting is ignored."
        }
    }
}
