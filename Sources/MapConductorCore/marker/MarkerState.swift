import Combine
import Foundation

public enum MarkerAnimation {
    case Drop
    case Bounce
}

public struct MarkerFingerPrint: Equatable, Hashable {
    public let id: Int
    public let icon: Int?
    public let clickable: Int
    public let draggable: Int
    public let latitude: Int
    public let longitude: Int
    public let zIndex: Int?
    public let animation: Int?
}

public typealias OnMarkerEventHandler = (MarkerState) -> Void

public final class MarkerState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String
    public var extra: Any?

    @Published public var icon: (any MarkerIconProtocol)?
    @Published public var clickable: Bool
    @Published public var draggable: Bool
    @Published public var zIndex: Int?
    @Published public var onClick: OnMarkerEventHandler?
    @Published public var onDragStart: OnMarkerEventHandler?
    @Published public var onDrag: OnMarkerEventHandler?
    @Published public var onDragEnd: OnMarkerEventHandler?
    @Published public var onAnimateStart: OnMarkerEventHandler?
    @Published public var onAnimateEnd: OnMarkerEventHandler?
    @Published public var position: GeoPoint

    @Published private var internalAnimation: MarkerAnimation?

    public init(
        position: GeoPoint,
        id: String? = nil,
        extra: Any? = nil,
        icon: (any MarkerIconProtocol)? = nil,
        animation: MarkerAnimation? = nil,
        clickable: Bool = true,
        draggable: Bool = false,
        zIndex: Int? = nil,
        onClick: OnMarkerEventHandler? = nil,
        onDragStart: OnMarkerEventHandler? = nil,
        onDrag: OnMarkerEventHandler? = nil,
        onDragEnd: OnMarkerEventHandler? = nil,
        onAnimateStart: OnMarkerEventHandler? = nil,
        onAnimateEnd: OnMarkerEventHandler? = nil
    ) {
        let resolvedId = id ?? MarkerState.makeMarkerId(
            position: position,
            extra: extra,
            icon: icon,
            clickable: clickable,
            draggable: draggable,
            animation: animation
        )

        self.id = resolvedId
        self.extra = extra
        self.icon = icon
        self.clickable = clickable
        self.draggable = draggable
        self.zIndex = zIndex
        self.onClick = onClick
        self.onDragStart = onDragStart
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
        self.onAnimateStart = onAnimateStart
        self.onAnimateEnd = onAnimateEnd
        self.internalAnimation = animation
        self.position = position
    }

    public convenience init(
        position: GeoPoint,
        id: String? = nil,
        extra: Any? = nil,
        icon: DefaultMarkerIcon,
        animation: MarkerAnimation? = nil,
        clickable: Bool = true,
        draggable: Bool = false,
        zIndex: Int? = nil,
        onClick: OnMarkerEventHandler? = nil,
        onDragStart: OnMarkerEventHandler? = nil,
        onDrag: OnMarkerEventHandler? = nil,
        onDragEnd: OnMarkerEventHandler? = nil,
        onAnimateStart: OnMarkerEventHandler? = nil,
        onAnimateEnd: OnMarkerEventHandler? = nil
    ) {
        let resolvedIcon: (any MarkerIconProtocol)? = icon
        self.init(
            position: position,
            id: id,
            extra: extra,
            icon: resolvedIcon,
            animation: animation,
            clickable: clickable,
            draggable: draggable,
            zIndex: zIndex,
            onClick: onClick,
            onDragStart: onDragStart,
            onDrag: onDrag,
            onDragEnd: onDragEnd,
            onAnimateStart: onAnimateStart,
            onAnimateEnd: onAnimateEnd
        )
    }

    public func animate(_ animation: MarkerAnimation?) {
        MCLog.marker("MarkerState.animate id=\(id) from=\(describeAnimation(internalAnimation)) to=\(describeAnimation(animation))")
        internalAnimation = animation
    }

    public func getAnimation() -> MarkerAnimation? {
        internalAnimation
    }

    /// Copies this state, carrying every property over unless overridden.
    ///
    /// `animation` is copied like everything else. It used to be hard-coded to
    /// `nil` here, so `marker.copy(position:)` on a bouncing marker returned a
    /// still one. Nothing about a copy implies "stop animating", and
    /// android-sdk / react-sdk both carry it over.
    ///
    /// The double optional is the same trick `zIndex` uses: `nil` means "not
    /// passed, keep mine", `.some(nil)` means "explicitly clear the animation".
    public func copy(
        id: String? = nil,
        position: GeoPoint? = nil,
        extra: Any? = nil,
        icon: (any MarkerIconProtocol)? = nil,
        animation: MarkerAnimation?? = nil,
        clickable: Bool? = nil,
        draggable: Bool? = nil,
        zIndex: Int?? = nil,
        onClick: OnMarkerEventHandler? = nil,
        onDragStart: OnMarkerEventHandler? = nil,
        onDrag: OnMarkerEventHandler? = nil,
        onDragEnd: OnMarkerEventHandler? = nil,
        onAnimateStart: OnMarkerEventHandler? = nil,
        onAnimateEnd: OnMarkerEventHandler? = nil
    ) -> MarkerState {
        // 各プロパティを個別の変数に展開する
        // これによりコンパイラの型推論の負荷を分散させます
        let finalId = id ?? self.id
        let finalPosition = position ?? self.position
        let finalExtra = extra ?? self.extra
        let finalIcon = icon ?? self.icon
        let finalAnimation = animation ?? self.internalAnimation
        let finalClickable = clickable ?? self.clickable
        let finalDraggable = draggable ?? self.draggable
        let finalZIndex = zIndex ?? self.zIndex
        let finalOnClick = onClick ?? self.onClick
        let finalOnDragStart = onDragStart ?? self.onDragStart
        let finalOnDrag = onDrag ?? self.onDrag
        let finalOnDragEnd = onDragEnd ?? self.onDragEnd
        let finalOnAnimateStart = onAnimateStart ?? self.onAnimateStart
        let finalOnAnimateEnd = onAnimateEnd ?? self.onAnimateEnd

        // 最終的にそれらを使ってインスタンスを生成
        return MarkerState(
            position: finalPosition,
            id: finalId,
            extra: finalExtra,
            icon: finalIcon,
            animation: finalAnimation,
            clickable: finalClickable,
            draggable: finalDraggable,
            zIndex: finalZIndex,
            onClick: finalOnClick,
            onDragStart: finalOnDragStart,
            onDrag: finalOnDrag,
            onDragEnd: finalOnDragEnd,
            onAnimateStart: finalOnAnimateStart,
            onAnimateEnd: finalOnAnimateEnd
        )
    }


    public static func == (lhs: MarkerState, rhs: MarkerState) -> Bool {
        lhs.hashCode() == rhs.hashCode()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hashCode())
    }

    public func hashCode() -> Int {
        // Kotlin/Java Int hash uses 32-bit overflow semantics; use wrapping math to match and
        // avoid Swift Debug overflow traps.
        var result: Int32 = Int32(truncatingIfNeeded: javaHash(extra))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(clickable))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(draggable))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(position.latitude))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(position.longitude))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(position.altitude ?? 0.0))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(icon))
        // android-sdk / react-sdk と同じく zIndex も含める（Kotlin の `Int?.hashCode()`
        // に合わせ nil は 0）。以前は除外しており zIndex のみ異なるマーカーが等価だった。
        result = result &* 31 &+ Int32(truncatingIfNeeded: zIndex ?? 0)
        return Int(result)
    }

    public func fingerPrint() -> MarkerFingerPrint {
        MarkerFingerPrint(
            id: javaHash(id),
            icon: javaHash(icon),
            clickable: javaHash(clickable),
            draggable: javaHash(draggable),
            latitude: javaHash(position.latitude),
            longitude: javaHash(position.longitude),
            zIndex: zIndex.map { Int(Int32(truncatingIfNeeded: $0)) },
            // Android uses `internalAnimation?.hashCode() ?: 1`. Kotlin's enum hashCode is
            // identity-based, so it never collides with `1` in practice. Swift's `hashValue`
            // can collide (e.g. `.Bounce` being `1`), so use stable, non-colliding values.
            animation: javaHashAnimationForFingerPrint(internalAnimation)
        )
    }

    public func asFlow() -> AnyPublisher<MarkerFingerPrint, Never> {
        let combined = Publishers.CombineLatest(
            Publishers.CombineLatest4($icon, $clickable, $draggable, $position),
            $internalAnimation
        )
        return combined
            // `@Published` emits in `willSet`, so reading properties from `self` here can be
            // one-step behind (e.g. the first animation tap being ignored). Build the
            // fingerprint from the emitted values instead.
            .map { [id] tuple, animation in
                let (icon, clickable, draggable, position) = tuple
                return MarkerFingerPrint(
                    id: javaHash(id),
                    icon: javaHash(icon),
                    clickable: javaHash(clickable),
                    draggable: javaHash(draggable),
                    latitude: javaHash(position.latitude),
                    longitude: javaHash(position.longitude),
                    zIndex: nil,
                    animation: javaHashAnimationForFingerPrint(animation)
                )
            }
            .combineLatest($zIndex)
            .map { finger, zIndex in
                MarkerFingerPrint(
                    id: finger.id,
                    icon: finger.icon,
                    clickable: finger.clickable,
                    draggable: finger.draggable,
                    latitude: finger.latitude,
                    longitude: finger.longitude,
                    zIndex: zIndex.map { Int(Int32(truncatingIfNeeded: $0)) },
                    animation: finger.animation
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func makeMarkerId(
        position: GeoPointProtocol,
        extra: Any?,
        icon: (any MarkerIconProtocol)?,
        clickable: Bool,
        draggable: Bool,
        animation: MarkerAnimation?
    ) -> String {
        let hashCodes = [
            javaHash(position),
            javaHash(extra),
            javaHash(icon),
            javaHash(clickable),
            javaHash(draggable),
            javaHashAnimationForId(animation)
        ]
        return markerId(hashCodes: hashCodes)
    }

    private static func markerId(hashCodes: [Int]) -> String {
        var result: Int32 = 0
        for hash in hashCodes {
            result = result &* 31 &+ Int32(truncatingIfNeeded: hash)
        }
        return String(result)
    }
}

private func javaHash(_ value: Bool) -> Int {
    value ? 1231 : 1237
}

private func javaHash(_ value: Double) -> Int {
    let bits = value.bitPattern
    let combined = bits ^ (bits >> 32)
    return Int(Int32(truncatingIfNeeded: combined))
}

private func javaHash(_ value: Int64) -> Int {
    let combined = value ^ (value >> 32)
    return Int(Int32(truncatingIfNeeded: combined))
}

private func javaHash(_ value: UInt64) -> Int {
    let combined = value ^ (value >> 32)
    return Int(Int32(truncatingIfNeeded: combined))
}

private func javaHash(_ value: String) -> Int {
    var result: Int32 = 0
    for unit in value.utf16 {
        result = result &* 31 &+ Int32(truncatingIfNeeded: unit)
    }
    return Int(result)
}

private func javaHash(_ icon: (any MarkerIconProtocol)?) -> Int {
    guard let icon else { return 0 }
    return icon.hashCode()
}

private func javaHash(_ value: Any?) -> Int {
    if value == nil { return 0 }

    if let value = value as? String {
        return javaHash(value)
    }

    if let value = value as? Bool {
        return javaHash(value)
    }

    if let value = value as? Double {
        return javaHash(value)
    }

    if let value = value as? Float {
        return javaHash(Double(value))
    }

    if let value = value as? Int {
        return Int(Int32(truncatingIfNeeded: value))
    }

    if let value = value as? Int64 {
        return javaHash(value)
    }

    if let value = value as? UInt64 {
        return javaHash(value)
    }

    if let value = value as? AnyHashable {
        return value.hashValue
    }

    if let value = value as? NSObject {
        return value.hash
    }

    return 0
}

private func javaHash(_ position: GeoPointProtocol) -> Int {
    let latHash = Int64(position.latitude * 1e7)
    let lngHash = Int64(position.longitude * 1e7)
    let altHash = Int64((position.altitude ?? 0.0) * 1e7)

    var result: Int32 = Int32(truncatingIfNeeded: javaHash(latHash))
    result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(lngHash))
    result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(altHash))
    return Int(result)
}

private func javaHashAnimationForId(_ animation: MarkerAnimation?) -> Int {
    // Android uses `animation?.hashCode() ?: 0` for markerId.
    guard let animation else { return 0 }
    switch animation {
    case .Drop: return 2
    case .Bounce: return 3
    }
}

private func javaHashAnimationForFingerPrint(_ animation: MarkerAnimation?) -> Int {
    // Android uses `internalAnimation?.hashCode() ?: 1` for fingerPrint.
    guard let animation else { return 1 }
    switch animation {
    case .Drop: return 2
    case .Bounce: return 3
    }
}

private func describeAnimation(_ animation: MarkerAnimation?) -> String {
    guard let animation else { return "nil" }
    switch animation {
    case .Drop: return "Drop"
    case .Bounce: return "Bounce"
    }
}
