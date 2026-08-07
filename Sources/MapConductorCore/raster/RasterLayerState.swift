import Combine

public struct RasterLayerFingerPrint: Equatable, Hashable {
    public let id: Int
    public let source: Int
    public let opacity: Int
    public let visible: Int
    public let zIndex: Int
    public let debug: Int
    public let userAgent: Int
    public let extraHeaders: Int
}

public struct RasterLayerEvent {
    public let state: RasterLayerState

    public init(state: RasterLayerState) {
        self.state = state
    }
}

public typealias OnRasterLayerEventHandler = (RasterLayerEvent) -> Void

public final class RasterLayerState: ObservableObject, Identifiable, Equatable, Hashable {
    /// `userAgent` を明示しなかったときに入る値。
    ///
    /// 定数として公開しているのは、プロバイダ側が「利用者が本当に指定したのか、
    /// 既定のまま来ただけなのか」を判断するため。HERE のようにヘッダを載せるのに
    /// 追加のコスト（ローカルプロキシ経由）が要るプロバイダは、既定値のままなら
    /// そのコストを払わない。react-sdk の `DEFAULT_RASTER_LAYER_USER_AGENT` と同じ値。
    public static let defaultUserAgent = "MapConductor/RasterLayerAgent(https://mapconductor.com)"

    public let id: String

    @Published public var source: RasterLayerSource
    @Published public var opacity: Double
    @Published public var visible: Bool
    @Published public var zIndex: Int
    @Published public var debug: Bool
    @Published public var userAgent: String?
    @Published public var extraHeaders: [String: String]?

    public init(
        source: RasterLayerSource,
        opacity: Double = 1.0,
        visible: Bool = true,
        zIndex: Int = 0,
        debug: Bool = false,
        userAgent: String = RasterLayerState.defaultUserAgent,
        extraHeaders: [String: String]? = nil,
        id: String? = nil
    ) {
        let resolvedId = id ?? RasterLayerState.makeRasterLayerId(
            source: source,
            opacity: opacity,
            visible: visible,
            debug: debug,
            extraHeaders: extraHeaders
        )
        self.id = resolvedId
        self.source = source
        self.opacity = opacity
        self.visible = visible
        self.zIndex = zIndex
        self.debug = debug
        self.userAgent = userAgent
        self.extraHeaders = extraHeaders
    }

    public func copy(
        source: RasterLayerSource? = nil,
        opacity: Double? = nil,
        visible: Bool? = nil,
        zIndex: Int? = nil,
        debug: Bool? = nil,
        userAgent: String? = nil,
        extraHeaders: [String: String]? = nil,
        id: String? = nil
    ) -> RasterLayerState {
        RasterLayerState(
            source: source ?? self.source,
            opacity: opacity ?? self.opacity,
            visible: visible ?? self.visible,
            zIndex: zIndex ?? self.zIndex,
            debug: debug ?? self.debug,
            userAgent: userAgent ??
                self.userAgent ?? RasterLayerState.defaultUserAgent,
            extraHeaders: extraHeaders ?? self.extraHeaders,
            id: id ?? self.id
        )
    }

    public func fingerPrint() -> RasterLayerFingerPrint {
        RasterLayerFingerPrint(
            id: javaHash(id),
            source: javaHash(source),
            opacity: javaHash(opacity),
            visible: javaHash(visible),
            zIndex: Int(Int32(truncatingIfNeeded: zIndex)),
            debug: javaHash(debug),
            userAgent: javaHash(userAgent),
            extraHeaders: javaHash(extraHeaders)
        )
    }

    public func asFlow() -> AnyPublisher<RasterLayerFingerPrint, Never> {
        Publishers
            .CombineLatest3($source, $opacity, $visible)
            .combineLatest(Publishers.CombineLatest($zIndex, $debug))
            .map { [id] combined, zDebug in
                let (source, opacity, visible) = combined
                let (zIndex, debug) = zDebug
                return RasterLayerFingerPrint(
                    id: javaHash(id),
                    source: javaHash(source),
                    opacity: javaHash(opacity),
                    visible: javaHash(visible),
                    zIndex: Int(Int32(truncatingIfNeeded: zIndex)),
                    debug: javaHash(debug),
                    userAgent: 0,
                    extraHeaders: 0
                )
            }
            .combineLatest($userAgent)
            .map { finger, userAgent in
                RasterLayerFingerPrint(
                    id: finger.id,
                    source: finger.source,
                    opacity: finger.opacity,
                    visible: finger.visible,
                    zIndex: finger.zIndex,
                    debug: finger.debug,
                    userAgent: javaHash(userAgent),
                    extraHeaders: 0
                )
            }
            .combineLatest($extraHeaders)
            .map { finger, extraHeaders in
                RasterLayerFingerPrint(
                    id: finger.id,
                    source: finger.source,
                    opacity: finger.opacity,
                    visible: finger.visible,
                    zIndex: finger.zIndex,
                    debug: finger.debug,
                    userAgent: finger.userAgent,
                    extraHeaders: javaHash(extraHeaders)
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
        // android-sdk と同じフィールド集合: source, opacity, visible, zIndex, debug,
        // extraHeaders, userAgent（zIndex/debug を含める。以前は除外していたため
        // zIndex や debug のみ異なるレイヤーが等価扱いになっていた）。
        var result: Int32 = Int32(truncatingIfNeeded: javaHash(source))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(opacity))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(visible))
        result = result &* 31 &+ Int32(truncatingIfNeeded: zIndex)
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(debug))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(extraHeaders))
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(userAgent))
        return Int(result)
    }

    private static func makeRasterLayerId(
        source: RasterLayerSource,
        opacity: Double,
        visible: Bool,
        debug: Bool,
        extraHeaders: [String: String]?
    ) -> String {
        // android-sdk / react-sdk と同じフィールド集合・順序: source, opacity, visible,
        // debug, extraHeaders（userAgent は id に含めない）。
        let hashCodes = [
            javaHash(source),
            javaHash(opacity),
            javaHash(visible),
            javaHash(debug),
            javaHash(extraHeaders)
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
    for unit in value.utf16 {
        result = result &* 31 &+ Int32(truncatingIfNeeded: unit)
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

private func javaHash(_ source: RasterLayerSource) -> Int {
    switch source {
    case let .urlTemplate(template, tileSize, minZoom, maxZoom, attributionRules, scheme):
        let hashCodes = [
            javaHash("urlTemplate"),
            javaHash(template),
            javaHash(tileSize),
            javaHash(minZoom),
            javaHash(maxZoom),
            javaHash(attributionRules.map { rule in
                [
                    javaHash(rule.attribution),
                    javaHash(rule.minZoom),
                    javaHash(rule.maxZoom),
                    javaHash(rule.bounds?.southWest?.latitude),
                    javaHash(rule.bounds?.southWest?.longitude),
                    javaHash(rule.bounds?.northEast?.latitude),
                    javaHash(rule.bounds?.northEast?.longitude)
                ]
            }.flatMap { $0 }),
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

private func javaHash(_ value: Double?) -> Int {
    guard let value else { return 0 }
    return javaHash(value)
}

private func javaHash(_ values: [Int]) -> Int {
    listHashCode(values)
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
