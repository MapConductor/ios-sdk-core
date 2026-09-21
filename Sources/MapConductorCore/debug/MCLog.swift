import Foundation
import os

public enum MCLog {
    private static let subsystem = "com.mapconductor"

    public static let isEnabled: Bool = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let raw = env["MAPCONDUCTOR_DEBUG_LOG"]?.lowercased() {
            return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
        }
        return false
        #else
        return false
        #endif
    }()

    private static let markerLogger = Logger(subsystem: subsystem, category: "Marker")
    private static let mapLogger = Logger(subsystem: subsystem, category: "MapView")
    private static let tileLogger = Logger(subsystem: subsystem, category: "TileServer")

    public static func marker(_ message: String) {
        guard isEnabled else { return }
        markerLogger.debug("\(message, privacy: .public)")
    }

    public static func map(_ message: String) {
        guard isEnabled else { return }
        mapLogger.debug("\(message, privacy: .public)")
    }

    /// タイルサーバの節目 -- 1 秒ごとの集計、404、abandoned、詰まり。
    ///
    /// Debug ビルドでは常に出す。「一部のタイルが出ない」「ピンチが重い」は
    /// どちらも**あとから**報告される症状で、そのときにはもう再現の環境変数を
    /// 立て直せない。行数は集計と異常だけなので秒に数行、絞る理由がない。
    /// 1 リクエスト 1 行の詳細のほうは `isEnabled` で絞る（`tileDetail`）。
    public static func tileServer(_ message: String) {
        #if DEBUG
        tileLogger.info("\(message, privacy: .public)")
        #else
        guard isEnabled else { return }
        tileLogger.debug("\(message, privacy: .public)")
        #endif
    }

    /// タイル 1 リクエスト 1 行の詳細。MAPCONDUCTOR_DEBUG_LOG=1 のときだけ。
    public static func tileDetail(_ message: String) {
        guard isEnabled else { return }
        tileLogger.debug("\(message, privacy: .public)")
    }

    private static let probeLogger = Logger(subsystem: subsystem, category: "Probe")

    /// メインスレッドを塞いだ区間の報告。呼び出し側が閾値を超えたときだけ呼ぶ。
    ///
    /// 「ピンチが重い」の類いは、重かった**その場**のログしか証拠にならない。
    /// Debug ビルドでは常時出す。閾値付きなので、健康なら 1 行も出ない。
    public static func probe(_ message: String) {
        #if DEBUG
        probeLogger.info("\(message, privacy: .public)")
        #else
        guard isEnabled else { return }
        probeLogger.debug("\(message, privacy: .public)")
        #endif
    }
}

