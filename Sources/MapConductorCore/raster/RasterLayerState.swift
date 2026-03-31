import Combine

public struct RasterLayerFingerPrint: Equatable, Hashable {
    public let id: Int
    public let source: Int
    public let opacity: Int
    public let visible: Int
    public let userAgent: Int
    public let extraHeaders: Int
    public let extra: Int
}

public struct RasterLayerEvent {
    public let state: RasterLayerState

    public init(state: RasterLayerState) {
        self.state = state
    }
}

public typealias OnRasterLayerEventHandler = (RasterLayerEvent) -> Void

public final class RasterLayerState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String

    @Published public var source: RasterSource
    @Published public var opacity: Double
    @Published public var visible: Bool
    @Published public var userAgent: String?
    @Published public var extraHeaders: [String: String]?
    @Published public var extra: Any?

    public init(
        source: RasterSource,
        opacity: Double = 1.0,
        visible: Bool = true,
        userAgent: String? = nil,
        extraHeaders: [String: String]? = nil,
        id: String? = nil,
        extra: Any? = nil
    ) {
        let resolvedId = id ?? RasterLayerState.makeRasterLayerId(
            source: source,
            opacity: opacity,
            visible: visible,
            userAgent: userAgent,
            extraHeaders: extraHeaders,
            extra: extra
        )
        self.id = resolvedId
        self.source = source
        self.opacity = opacity
        self.visible = visible
        self.userAgent = userAgent
        self.extraHeaders = extraHeaders
        self.extra = extra
    }

    public func copy(
        source: RasterSource? = nil,
        opacity: Double? = nil,
        visible: Bool? = nil,
        userAgent: String? = nil,
        extraHeaders: [String: String]? = nil,
        id: String? = nil,
        extra: Any? = nil
    ) -> RasterLayerState {
        RasterLayerState(
            source: source ?? self.source,
            opacity: opacity ?? self.opacity,
            visible: visible ?? self.visible,
            userAgent: userAgent ?? self.userAgent,
            extraHeaders: extraHeaders ?? self.extraHeaders,
            id: id ?? self.id,
            extra: extra ?? self.extra
        )
    }

    public func fingerPrint() -> RasterLayerFingerPrint {
        RasterLayerFingerPrint(
            id: javaHash(id),
            source: javaHash(source),
            opacity: javaHash(opacity),
            visible: javaHash(visible),
            userAgent: javaHash(userAgent),
            extraHeaders: javaHash(extraHeaders),
            extra: javaHash(extra)
        )
    }

    public func asFlow() -> AnyPublisher<RasterLayerFingerPrint, Never> {
        Publishers
            .CombineLatest3($source, $opacity, $visible)
            .combineLatest($userAgent)
            .combineLatest($extraHeaders)
            .map { [id] combined, extraHeaders in
                let ((source, opacity, visible), userAgent) = combined
                return RasterLayerFingerPrint(
                    id: javaHash(id),
                    source: javaHash(source),
                    opacity: javaHash(opacity),
                    visible: javaHash(visible),
                    userAgent: javaHash(userAgent),
                    extraHeaders: javaHash(extraHeaders),
                    extra: 0
                )
            }
            .combineLatest($extra)
            .map { finger, extra in
                RasterLayerFingerPrint(
                    id: finger.id,
                    source: finger.source,
                    opacity: finger.opacity,
                    visible: finger.visible,
                    userAgent: finger.userAgent,
                    extraHeaders: finger.extraHeaders,
                    extra: javaHash(extra)
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public static func == (lhs: RasterLayerState, rhs: RasterLayerState) -> Bool {
        lhs.hashCode() == rhs.hashCode()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hashCode())
    }

    public func hashCode() -> Int {
        var result: Int32 = Int32(truncatingIfNeeded: javaHash(source))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(opacity))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(visible))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(userAgent))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(extraHeaders))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(extra))
        return Int(result)
    }

    private static func makeRasterLayerId(
        source: RasterSource,
        opacity: Double,
        visible: Bool,
        userAgent: String?,
        extraHeaders: [String: String]?,
        extra: Any?
    ) -> String {
        let hashCodes = [
            javaHash(source),
            javaHash(opacity),
            javaHash(visible),
            javaHash(userAgent),
            javaHash(extraHeaders),
            javaHash(extra)
        ]
        return rasterLayerId(hashCodes: hashCodes)
    }
}

private func rasterLayerId(hashCodes: [Int]) -> String {
    var result: Int32 = 0
    for hash in hashCodes {
        result = result &* 31 &+ Int32(truncatingIfNeeded: hash)
    }
    return String(result)
}

private func javaHash(_ value: Bool) -> Int {
    value ? 1231 : 1237
}

private func javaHash(_ value: Double) -> Int {
    let bits = value.bitPattern
    let combined = bits ^ (bits >> 32)
    return Int(Int32(truncatingIfNeeded: combined))
}

private func javaHash(_ value: String) -> Int {
    var result: Int32 = 0
    for scalar in value.unicodeScalars {
        result = result &* 31 &+ Int32(truncatingIfNeeded: scalar.value)
    }
    return Int(result)
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
        let combined = value ^ (value >> 32)
        return Int(Int32(truncatingIfNeeded: combined))
    }

    if let value = value as? UInt64 {
        let combined = value ^ (value >> 32)
        return Int(Int32(truncatingIfNeeded: combined))
    }

    if let value = value as? AnyHashable {
        return value.hashValue
    }

    return 0
}

private func javaHash(_ source: RasterSource) -> Int {
    switch source {
    case let .urlTemplate(template, tileSize, minZoom, maxZoom, attribution, scheme):
        let hashCodes = [
            javaHash("urlTemplate"),
            javaHash(template),
            javaHash(tileSize),
            javaHash(minZoom),
            javaHash(maxZoom),
            javaHash(attribution),
            javaHash(scheme.rawValue)
        ]
        return listHashCode(hashCodes)
    case let .tileJson(url):
        return listHashCode([javaHash("tileJson"), javaHash(url)])
    case let .arcGisService(serviceUrl):
        return listHashCode([javaHash("arcGisService"), javaHash(serviceUrl)])
    }
}

private func javaHash(_ value: Int?) -> Int {
    guard let value else { return 0 }
    return Int(Int32(truncatingIfNeeded: value))
}

private func javaHash(_ value: String?) -> Int {
    guard let value else { return 0 }
    return javaHash(value)
}

private func javaHash(_ value: [String: String]?) -> Int {
    guard let value else { return 0 }

    // Java Map#hashCode: sum(entry.hashCode), where entryHash = keyHash ^ valueHash.
    // Use wrapping arithmetic to match Java's overflow behavior.
    var result: Int32 = 0
    for (key, val) in value {
        let entry = javaHash(key) ^ javaHash(val)
        result = result &+ Int32(truncatingIfNeeded: entry)
    }
    return Int(result)
}

private func listHashCode(_ values: [Int]) -> Int {
    var result: Int32 = 0
    for value in values {
        result = result &* 31 &+ Int32(truncatingIfNeeded: value)
    }
    return Int(result)
}
