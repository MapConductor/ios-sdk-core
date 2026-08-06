import Foundation

/// 型引数を落とした ``OverlayControllerProtocol``。
///
/// `OverlayControllerProtocol` は `StateType` / `EntityType` / `EventType` の 3 つの
/// associatedtype を持つため、そのままでは 1 つの配列に入れられない。レジストリが実際に
/// 呼ぶメンバだけを非ジェネリックに切り出したもので、android-sdk の
/// `OverlayControllerInterface<*, *>`（スター射影）、react-sdk の `OverlayControllerLike`
/// に対応する。
///
/// `OverlayControllerProtocol` がこれを継承しているので、既存のコントローラは
/// 何も書き足さずにそのまま登録できる。
public protocol AnyOverlayController: AnyObject {
    var zIndex: Int { get }
    func onCameraChanged(mapCameraPosition: MapCameraPosition) async
    func destroy()
}

/// 1 つの地図に紐づくオーバーレイコントローラの登録簿。
///
/// android-sdk では `BaseMapViewController` がこの役割を持ち、カメラ変更を登録済みの
/// オーバーレイへ伝播させる。iOS には相当する基底クラスが無いので、各プロバイダの
/// コントローラがこのクラスを 1 つ保持し、``MapViewControllerProtocol`` の
/// `registerOverlayController(_:)` などがそこへ委譲する。
///
/// 拡張モジュール（ヒートマップ、マーカークラスタリング等）はこれに登録することで、
/// 地図コントローラのリスナー（単一スロット）を奪い合わずにカメラ変更を受け取れる。
public final class OverlayControllerRegistry {
    private let lock = NSLock()
    private var controllers: [ObjectIdentifier: any AnyOverlayController] = [:]

    public init() {}

    /// 登録する。同じインスタンスを 2 回登録しても 1 つとして扱う。
    public func register(_ controller: any AnyOverlayController) {
        lock.lock()
        defer { lock.unlock() }
        controllers[ObjectIdentifier(controller)] = controller
    }

    /// 登録を取り消す。未登録のものを渡しても何も起きない。
    public func unregister(_ controller: any AnyOverlayController) {
        lock.lock()
        defer { lock.unlock() }
        controllers.removeValue(forKey: ObjectIdentifier(controller))
    }

    /// 登録済みのコントローラを zIndex の昇順で返す。
    public func all() -> [any AnyOverlayController] {
        lock.lock()
        defer { lock.unlock() }
        return controllers.values.sorted { $0.zIndex < $1.zIndex }
    }

    /// カメラ変更を登録済みの全コントローラへ伝播する。
    ///
    /// 各プロバイダの `notifyCameraMoveEnd(_:)` から呼ぶ。`onCameraChanged` は `async` だが
    /// 呼び出し側は同期のイベントハンドラなので、android-sdk の `coroutine.launch` /
    /// react-sdk の `void controller.onCameraChanged(...)` と同じく投げっぱなしにする。
    /// 1 つのコントローラが重い処理をしても他の配送やマップのイベント処理を止めない。
    public func dispatchCameraChanged(_ mapCameraPosition: MapCameraPosition) {
        for controller in all() {
            Task { await controller.onCameraChanged(mapCameraPosition: mapCameraPosition) }
        }
    }

    /// 登録済みの全コントローラを破棄して登録簿を空にする。
    /// 地図の破棄・プロバイダ切り替え時に呼ぶ。
    public func destroyAll() {
        lock.lock()
        let snapshot = controllers.values
        controllers.removeAll()
        lock.unlock()
        for controller in snapshot {
            controller.destroy()
        }
    }
}

/// ``OverlayControllerRegistry`` をサービスレジストリから引くためのキー。
///
/// iOS の地図コンテンツは `MapViewContent` という**値**であってビュー階層ではないため、
/// `HeatmapOverlay` のようなコンテンツ項目は SwiftUI の Environment からコントローラを
/// 受け取れない。既に確立している ``MapServiceRegistryScope`` に載せることで、
/// 拡張モジュールが `MapServiceRegistryScope.current.get(OverlayControllerRegistryKey.self)`
/// で登録簿へ到達できるようにする。
///
/// android-sdk では `LocalMapViewController.current` からコントローラを直接取れるため、
/// このキーに相当するものは無い。
public enum OverlayControllerRegistryKey: MapServiceKey {
    public typealias Value = OverlayControllerRegistry
}
