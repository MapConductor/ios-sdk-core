import Combine
import UIKit

public struct GroundImageFingerPrint: Equatable, Hashable {
    public let id: Int
    public let bounds: Int
    public let image: Int
    public let opacity: Int
    public let tileSize: Int
    public let extra: Int
}

public struct GroundImageEvent {
    public let state: GroundImageState
    public let clicked: GeoPointProtocol?

    public init(state: GroundImageState, clicked: GeoPointProtocol?) {
        self.state = state
        // 生成時に wrap して [-180,180] / [-90,90] に正規化する（日付変更線対策）。
        // 正規化をここ（イベント型＝出口）に一元化することで、どの配送経路でも wrap 漏れが起きない。
        self.clicked = clicked?.wrap()
    }
}

public typealias OnGroundImageEventHandler = (GroundImageEvent) -> Void

/// The type of ``GroundImageState/onAdded``: called with the state that reached the map.
public typealias OnGroundImageAddedHandler = (GroundImageState) -> Void

/// 地表画像。
///
/// ## URL で渡す
///
/// `GroundImageState(bounds:imageUrl:)` は画像を自分で読み込む（``ImageIcon`` の `imageUrl` と
/// 同じローダー）。読み終えるまで `image` は 1×1 の透明な画像で、読み終えたら `image` に入る
/// （ふだんの `image` の差し替えと同じく描き直される）。
///
/// - `imageUrl` を別の URL にすると、読み終えるまでは今の画像のまま、読み終えたら差し替わる。
///   読み終える前にもう一度変えたら、古い方の結果は捨てる。
/// - `image` を自分で入れると `imageUrl` は nil に戻る（URL の読み込みより後の指定が勝つ）。
/// - 失敗したときは画像を変えない（ログに URL ごと 1 度だけ出す）。
public final class GroundImageState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String

    /// Writes to the fields below are announced here rather than discovered by
    /// subscribing to each state. See ``StateMutationSignal``.
    public let mutations = StateMutationSignal()

    @Published public var bounds: GeoRectBounds { didSet { mutations.notifyMutated() } }
    @Published public var image: UIImage {
        didSet {
            if !applyingLoadedImage, imageUrl != nil { imageUrl = nil }
            mutations.notifyMutated()
        }
    }
    /// 画像を読み込む URL。nil なら `image` をそのまま使う。
    @Published public var imageUrl: URL? {
        didSet {
            if imageUrl != oldValue { loadImageUrl() }
        }
    }
    @Published public var opacity: Double { didSet { mutations.notifyMutated() } }
    @Published public var tileSize: Int { didSet { mutations.notifyMutated() } }
    @Published public var extra: Any? { didSet { mutations.notifyMutated() } }
    @Published public var onClick: OnGroundImageEventHandler? { didSet { mutations.notifyMutated() } }
    /// Called with this state each time the ground image goes from not being on the
    /// map to being on it.
    ///
    /// - Drawn natively: after the provider has created its native ground image.
    ///
    /// Not called for in-place changes, on `clear`, or when the map goes
    /// away. Called again when the ground image is removed and later added again.
    /// Always on the main actor.
    ///
    /// Like `onClick` it is not part of the id, the fingerprint, `==` or the
    /// hash, and replacing it does not redraw anything.
    public var onAdded: OnGroundImageAddedHandler?

    private var loader: RemoteImageLoader = .shared
    private var applyingLoadedImage = false

    public init(
        bounds: GeoRectBounds,
        image: UIImage,
        opacity: Double = 1.0,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil,
        onAdded: OnGroundImageAddedHandler? = nil
    ) {
        let resolvedId = id ?? GroundImageState.makeGroundImageId(
            bounds: bounds,
            imageHash: javaHash(image),
            opacity: opacity,
            tileSize: tileSize,
            extra: extra
        )
        self.id = resolvedId
        self.bounds = bounds
        self.image = image
        self.opacity = opacity
        self.tileSize = tileSize
        self.extra = extra
        self.onClick = onClick
        self.onAdded = onAdded
    }

    /// 画像を URL で渡す。読み終えるまでは透明。`file:` の URL も使える。
    public convenience init(
        bounds: GeoRectBounds,
        imageUrl: URL,
        opacity: Double = 1.0,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil,
        onAdded: OnGroundImageAddedHandler? = nil
    ) {
        self.init(
            bounds: bounds, imageUrl: imageUrl, opacity: opacity, tileSize: tileSize, id: id, extra: extra,
            onClick: onClick, onAdded: onAdded, loader: .shared
        )
    }

    /// テスト用。ローダーを差し替える。
    convenience init(
        bounds: GeoRectBounds,
        imageUrl: URL,
        opacity: Double = 1.0,
        tileSize: Int = 512,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil,
        onAdded: OnGroundImageAddedHandler? = nil,
        loader: RemoteImageLoader
    ) {
        // 決めた id が読み込みの前後で変わらないよう、画像ではなく URL から作る。
        let resolvedId = id ?? GroundImageState.makeGroundImageId(
            bounds: bounds,
            imageHash: javaHash(imageUrl.absoluteString),
            opacity: opacity,
            tileSize: tileSize,
            extra: extra
        )
        self.init(
            bounds: bounds, image: GroundImageState.placeholder, opacity: opacity, tileSize: tileSize,
            id: resolvedId, extra: extra, onClick: onClick, onAdded: onAdded
        )
        self.loader = loader
        self.imageUrl = imageUrl
    }

    /// 読み込み中の画像。
    private static let placeholder: UIImage = {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in }
    }()

    private func loadImageUrl() {
        guard let url = imageUrl else { return }
        let apply: (UIImage) -> Void = { [weak self] image in
            guard let self, self.imageUrl == url else { return }
            self.applyingLoadedImage = true
            self.image = image
            self.applyingLoadedImage = false
        }
        if case let .ready(image) = loader.status(url) {
            apply(image)
            return
        }
        loader.whenSettled(url) { image in
            if let image { apply(image) }
        }
    }

    /// `image` を変えなければ、`imageUrl` も引き継ぐ（読み込み中なら写しの方でも読み終えたら入る）。
    public func copy(
        bounds: GeoRectBounds? = nil,
        image: UIImage? = nil,
        opacity: Double? = nil,
        tileSize: Int? = nil,
        id: String? = nil,
        extra: Any? = nil,
        onClick: OnGroundImageEventHandler? = nil,
        onAdded: OnGroundImageAddedHandler? = nil
    ) -> GroundImageState {
        let copied = GroundImageState(
            bounds: bounds ?? self.bounds,
            image: image ?? self.image,
            opacity: opacity ?? self.opacity,
            tileSize: tileSize ?? self.tileSize,
            id: id ?? self.id,
            extra: extra ?? self.extra,
            onClick: onClick ?? self.onClick,
            onAdded: onAdded ?? self.onAdded
        )
        if image == nil, let imageUrl {
            copied.loader = loader
            copied.imageUrl = imageUrl
        }
        return copied
    }

    public func fingerPrint() -> GroundImageFingerPrint {
        GroundImageFingerPrint(
            id: javaHash(id),
            bounds: javaHash(bounds),
            image: javaHash(image),
            opacity: javaHash(opacity),
            tileSize: javaHash(tileSize),
            extra: javaHash(extra)
        )
    }

    public func asFlow() -> AnyPublisher<GroundImageFingerPrint, Never> {
        Publishers.CombineLatest4($bounds, $image, $opacity, $tileSize)
            .map { [id] bounds, image, opacity, tileSize in
                GroundImageFingerPrint(
                    id: javaHash(id),
                    bounds: javaHash(bounds),
                    image: javaHash(image),
                    opacity: javaHash(opacity),
                    tileSize: javaHash(tileSize),
                    extra: 0
                )
            }
            .combineLatest($extra)
            .map { finger, extra in
                GroundImageFingerPrint(
                    id: finger.id,
                    bounds: finger.bounds,
                    image: finger.image,
                    opacity: finger.opacity,
                    tileSize: finger.tileSize,
                    extra: javaHash(extra)
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public static func == (lhs: GroundImageState, rhs: GroundImageState) -> Bool {
        lhs.hashCode() == rhs.hashCode()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hashCode())
    }

    public func hashCode() -> Int {
        let finger = fingerPrint()
        var result: Int32 = Int32(truncatingIfNeeded: finger.bounds)
        result = result &* 31 &+ Int32(truncatingIfNeeded: finger.image)
        result = result &* 31 &+ Int32(truncatingIfNeeded: finger.opacity)
        result = result &* 31 &+ Int32(truncatingIfNeeded: finger.tileSize)
        result = result &* 31 &+ Int32(truncatingIfNeeded: finger.extra)
        return Int(result)
    }

    private static func makeGroundImageId(
        bounds: GeoRectBounds,
        imageHash: Int,
        opacity: Double,
        tileSize: Int,
        extra: Any?
    ) -> String {
        let hashCodes = [
            javaHash(bounds),
            imageHash,
            javaHash(opacity),
            javaHash(tileSize),
            javaHash(extra)
        ]
        return groundImageId(hashCodes: hashCodes)
    }
}

private func groundImageId(hashCodes: [Int]) -> String {
    var result: Int32 = 0
    for hash in hashCodes {
        result = result &* 31 &+ Int32(truncatingIfNeeded: hash)
    }
    return String(result)
}

private func javaHash(_ value: Double) -> Int {
    let bits = value.bitPattern
    let combined = bits ^ (bits >> 32)
    return Int(Int32(truncatingIfNeeded: combined))
}

private func javaHash(_ value: Int) -> Int {
    Int(Int32(truncatingIfNeeded: value))
}

private func javaHash(_ value: Int64) -> Int {
    let combined = value ^ (value >> 32)
    return Int(Int32(truncatingIfNeeded: combined))
}

private func javaHash(_ value: String) -> Int {
    var result: Int32 = 0
    for u in value.utf16 {
        result = result &* 31 &+ Int32(u)
    }
    return Int(result)
}

private func javaHash(_ value: Any?) -> Int {
    if value == nil { return 0 }

    if let value = value as? String {
        return javaHash(value)
    }

    if let value = value as? Bool {
        return value ? 1231 : 1237
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

    if let value = value as? NSObject {
        return value.hash
    }

    return 0
}

private func javaHash(_ bounds: GeoRectBounds) -> Int {
    var result: Int32 = 0
    if let sw = bounds.southWest {
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(sw))
    }
    if let ne = bounds.northEast {
        result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(ne))
    }
    return Int(result)
}

private func javaHash(_ point: GeoPointProtocol) -> Int {
    let latHash = Int64(point.latitude * 1e7)
    let lngHash = Int64(point.longitude * 1e7)
    let altHash = Int64((point.altitude ?? 0.0) * 1e7)

    var result: Int32 = Int32(truncatingIfNeeded: javaHash(latHash))
    result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(lngHash))
    result = result &* 31 &+ Int32(truncatingIfNeeded: javaHash(altHash))
    return Int(result)
}
