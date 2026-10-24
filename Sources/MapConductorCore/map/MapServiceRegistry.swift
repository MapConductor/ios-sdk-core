import Foundation

/// Typed service key used to register and retrieve map-scoped services (plugins).
///
/// This is the iOS counterpart of Android's `MapServiceKey<T>`. Kotlin declares keys as
/// singleton `object`s carrying the value type as a generic argument; Swift has no
/// generic protocol arguments, so keys are declared as *types* with an associated
/// `Value` — the same shape SwiftUI uses for `EnvironmentKey`:
///
/// ```swift
/// public enum MarkerRenderingSupportKey: MapServiceKey {
///     public typealias Value = AnyMarkerRenderingSupport
/// }
/// ```
///
/// `capability` を指定すると、そのキーを ``MutableMapServiceRegistry/put(_:_:)`` した時点で
/// 対応状況が自動的に ``MapCapabilityStatus/supported`` になる。プロバイダが
/// 「登録する」と「対応していると宣言する」を二重に書かなくて済むようにするため。
public protocol MapServiceKey {
    associatedtype Value

    static var capability: MapCapability? { get }
}

public extension MapServiceKey {
    static var capability: MapCapability? { nil }
}

/// Read side of a map-scoped service registry.
///
/// Providers register capabilities; add-on modules (marker clustering and friends)
/// resolve them, so a provider never has to implement a plugin's interfaces and the
/// plugin never has to know which provider it is running on.
public protocol MapServiceRegistry: AnyObject {
    func get<Key: MapServiceKey>(_ key: Key.Type) -> Key.Value?

    /// キーが登録済みか。``get(_:)`` の nil 判定と同じだが、「値が欲しい」のではなく
    /// 「対応しているかを知りたい」という意図をコード上で表せる。
    func has<Key: MapServiceKey>(_ key: Key.Type) -> Bool

    /// `capability` への対応状況。宣言が無ければ ``MapCapabilityStatus/unknown``。
    ///
    /// **``MapCapabilityStatus/unknown`` を非対応と解釈しないこと。** 初期化途中の
    /// マップも unknown を返す。
    func capabilityStatus(_ capability: MapCapability) -> MapCapabilityStatus
}

public extension MapServiceRegistry {
    func has<Key: MapServiceKey>(_ key: Key.Type) -> Bool { get(key) != nil }

    func capabilityStatus(_: MapCapability) -> MapCapabilityStatus { .unknown }
}

/// 登録の取り消し券。
///
/// プロバイダも拡張モジュールも、自分が登録したものだけを ``dispose()`` で外せる。
/// キー名をどこかにハードコードした撤収処理（この型が入る前の
/// `removeProviderRegistrations()` が固定 2 キーを列挙していた形）を不要にするためのもの。
/// 新しい capability を増やしても撤収コードを直す必要がない。
public final class MapServiceRegistration {
    private let onDispose: () -> Void

    init(_ onDispose: @escaping () -> Void) {
        self.onDispose = onDispose
    }

    public func dispose() { onDispose() }
}

/// 複数の ``MapServiceRegistration`` をまとめて破棄するための入れ物。
public final class MapServiceRegistrations {
    private let lock = NSLock()
    private var registrations: [MapServiceRegistration] = []

    public init() {}

    @discardableResult
    public func add(_ registration: MapServiceRegistration) -> MapServiceRegistration {
        lock.lock()
        registrations.append(registration)
        lock.unlock()
        return registration
    }

    /// 登録した順に関係なくすべて取り消す。二重呼び出しは安全。
    public func disposeAll() {
        lock.lock()
        let snapshot = registrations
        registrations.removeAll()
        lock.unlock()
        snapshot.forEach { $0.dispose() }
    }
}

/// Registry a provider populates. One instance per map view; see ``MapViewState/serviceRegistry``.
public final class MutableMapServiceRegistry: MapServiceRegistry {
    /// 「いま入っているのは自分が入れたものか」を判定するための連番。
    ///
    /// Swift には Kotlin の `ConcurrentHashMap.remove(key, value)` に当たるものが無く、
    /// `Key.Value` は Equatable とは限らない（構造体も入る）。値そのものを比べる代わりに
    /// 登録ごとの連番を突き合わせる。
    private struct Entry {
        let value: Any
        let token: UInt64
    }

    private let lock = NSLock()
    private var services: [ObjectIdentifier: Entry] = [:]
    private var capabilities: [MapCapability: MapCapabilityStatus] = [:]
    private var nextToken: UInt64 = 0

    public init() {}

    /// サービスを登録する。
    ///
    /// 取り消し券が欲しい場合は ``register(_:_:)`` を使う。
    public func put<Key: MapServiceKey>(_ key: Key.Type, _ value: Key.Value) {
        _ = register(key, value)
    }

    /// サービスを登録し、取り消し券を返す。
    ///
    /// `key` が ``MapServiceKey/capability`` を持つ場合、その capability を
    /// ``MapCapabilityStatus/supported`` として宣言する。取り消すと宣言も戻る。
    @discardableResult
    public func register<Key: MapServiceKey>(
        _ key: Key.Type,
        _ value: Key.Value
    ) -> MapServiceRegistration {
        let identifier = ObjectIdentifier(key)
        let capability = Key.capability
        lock.lock()
        nextToken += 1
        let token = nextToken
        services[identifier] = Entry(value: value, token: token)
        let previousStatus = capability.map { capabilities.updateValue(.supported, forKey: $0) } ?? nil
        lock.unlock()

        return MapServiceRegistration { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            // 自分が入れた値がまだ残っているときだけ外す（後から別の実装で
            // 上書きされていた場合にそれを消してしまわないように）。
            if self.services[identifier]?.token == token {
                self.services.removeValue(forKey: identifier)
            }
            guard let capability else { return }
            if let previousStatus {
                self.capabilities[capability] = previousStatus
            } else if self.capabilities[capability] == .supported {
                self.capabilities.removeValue(forKey: capability)
            }
        }
    }

    /// 登録済みのサービスを1件だけ取り消す。未登録のキーを渡しても何も起きない。
    ///
    /// ``clear()`` がレジストリ全体を空にするのに対し、こちらは他の capability を残したまま
    /// 1つだけ取り下げたいプラグイン向け。
    public func remove<Key: MapServiceKey>(_ key: Key.Type) {
        lock.lock()
        defer { lock.unlock() }
        services.removeValue(forKey: ObjectIdentifier(key))
        if let capability = Key.capability, capabilities[capability] == .supported {
            capabilities.removeValue(forKey: capability)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        services.removeAll()
        capabilities.removeAll()
    }

    /// 対応状況を明示的に宣言する。
    ///
    /// 「まだ登録されていない」と「この SDK では原理的にできない」を区別するために使う。
    /// 例: ios-for-longdo は WebView ブリッジに同期の座標変換が無いので
    /// `declareUnsupported(.screenProjectionSync, "Longdo JS bridge has no synchronous unproject")`。
    @discardableResult
    public func declare(
        _ capability: MapCapability,
        _ status: MapCapabilityStatus
    ) -> MapServiceRegistration {
        lock.lock()
        let previous = capabilities.updateValue(status, forKey: capability)
        lock.unlock()

        return MapServiceRegistration { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if let previous {
                self.capabilities[capability] = previous
            } else if self.capabilities[capability] == status {
                self.capabilities.removeValue(forKey: capability)
            }
        }
    }

    /// ``declare(_:_:)`` の短縮形。
    @discardableResult
    public func declareUnsupported(
        _ capability: MapCapability,
        _ reason: String
    ) -> MapServiceRegistration {
        declare(capability, .unsupported(reason))
    }

    /// 宣言済みの capability を列挙する（診断・適合テスト用）。
    public func declaredCapabilities() -> [MapCapability: MapCapabilityStatus] {
        lock.lock()
        defer { lock.unlock() }
        return capabilities
    }

    public func capabilityStatus(_ capability: MapCapability) -> MapCapabilityStatus {
        lock.lock()
        defer { lock.unlock() }
        return capabilities[capability] ?? .unknown
    }

    public func get<Key: MapServiceKey>(_ key: Key.Type) -> Key.Value? {
        lock.lock()
        defer { lock.unlock() }
        return services[ObjectIdentifier(key)]?.value as? Key.Value
    }
}

public extension MutableMapServiceRegistry {
    /// プロバイダがこのマップに登録した capability をまとめて取り下げる。
    ///
    /// レジストリの持ち主は state で、ビューより長生きする。ビューが消えるときに取り下げないと、
    /// 破棄済みのコントローラを掴んだままの capability が残る。
    ///
    /// ``clear()`` ではなく ``remove(_:)`` を並べているのは、拡張モジュールが同じマップへ
    /// 登録した他の capability を巻き添えにしないため。android-sdk の `MapViewBase` の
    /// `DisposableEffect`、react-sdk の `useMarkerRenderingSupport` のクリーンアップと同じ位置づけで、
    /// 各プロバイダの `unbind()` から呼ぶ。
    ///
    /// - Note: 新しく登録するものは ``register(_:_:)`` が返す ``MapServiceRegistration`` を
    ///   ``MapServiceRegistrations`` に溜めて `disposeAll()` すること。キー名を
    ///   ここへ書き足す必要がなくなる。このメソッドは移行が済むまでの互換のために残してある。
    func removeProviderRegistrations() {
        remove(MarkerRenderingSupportKey.self)
        remove(OverlayControllerRegistryKey.self)
        // ArcGIS の 3D と 2D は同じ state を共有できる（サンプルがそうしている）。
        // 3D だけが「タイルは 256pt」を宣言するので、外し忘れると 2D に切り替えた
        // あとも 256 が残り、2D は同じ画面を 4 倍の枚数で覆うことになる。
        remove(RasterTilePreferenceKey.self)
        remove(VectorStyleSupportKey.self)
    }
}

/// Registry that never resolves anything — the value ``MapServiceRegistryScope/current``
/// reports outside of any map. Mirrors Android's `EmptyMapServiceRegistry`.
public final class EmptyMapServiceRegistry: MapServiceRegistry {
    public static let shared = EmptyMapServiceRegistry()

    private init() {}

    public func get<Key: MapServiceKey>(_: Key.Type) -> Key.Value? { nil }
}

/// The registry currently in scope, as seen from inside a map's content builder.
///
/// This is the iOS counterpart of Android's `LocalMapServiceRegistry` CompositionLocal.
/// It is *not* a SwiftUI `Environment` value: map content is a `MapViewContent` **value**
/// assembled by ``MapViewContentBuilder``, not a SwiftUI view hierarchy, so overlay items
/// such as `MarkerClusterGroup` are never placed in the view tree and can never read an
/// `@Environment`. What they do share with Compose is that the content closure is invoked
/// *inside* the provider's `body` — so a main-actor dynamic scope around that call gives
/// exactly the CompositionLocal semantics: the value is visible for the duration of the
/// content build and nowhere else.
///
/// Providers wrap their content evaluation:
///
/// ```swift
/// let mapContent = MapServiceRegistryScope.with(state.serviceRegistry) { content() }
/// ```
@MainActor
public enum MapServiceRegistryScope {
    private static var stack: [MapServiceRegistry] = []

    /// The innermost registry in scope, or an empty one when built outside a map.
    public static var current: MapServiceRegistry {
        stack.last ?? EmptyMapServiceRegistry.shared
    }

    /// Evaluates `body` with `registry` installed as ``current``.
    public static func with<Result>(
        _ registry: MapServiceRegistry,
        _ body: () -> Result
    ) -> Result {
        stack.append(registry)
        defer { stack.removeLast() }
        return body()
    }
}
