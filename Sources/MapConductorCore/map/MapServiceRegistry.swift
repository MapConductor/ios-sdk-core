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
public protocol MapServiceKey {
    associatedtype Value
}

/// Read side of a map-scoped service registry.
///
/// Providers register capabilities; add-on modules (marker clustering and friends)
/// resolve them, so a provider never has to implement a plugin's interfaces and the
/// plugin never has to know which provider it is running on.
public protocol MapServiceRegistry: AnyObject {
    func get<Key: MapServiceKey>(_ key: Key.Type) -> Key.Value?
}

/// Registry a provider populates. One instance per map view; see ``MapViewState/serviceRegistry``.
public final class MutableMapServiceRegistry: MapServiceRegistry {
    private let lock = NSLock()
    private var services: [ObjectIdentifier: Any] = [:]

    public init() {}

    public func put<Key: MapServiceKey>(_ key: Key.Type, _ value: Key.Value) {
        lock.lock()
        defer { lock.unlock() }
        services[ObjectIdentifier(key)] = value
    }

    public func remove<Key: MapServiceKey>(_ key: Key.Type) {
        lock.lock()
        defer { lock.unlock() }
        services.removeValue(forKey: ObjectIdentifier(key))
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        services.removeAll()
    }

    public func get<Key: MapServiceKey>(_ key: Key.Type) -> Key.Value? {
        lock.lock()
        defer { lock.unlock() }
        return services[ObjectIdentifier(key)] as? Key.Value
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
    /// プロバイダが登録する capability を増やしたら、ここにも足すこと。
    func removeProviderRegistrations() {
        remove(MarkerRenderingSupportKey.self)
        remove(OverlayControllerRegistryKey.self)
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
