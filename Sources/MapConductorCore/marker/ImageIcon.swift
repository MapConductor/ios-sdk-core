import CoreGraphics
import UIKit

/// iOS counterpart of Android's `ImageIcon`.
///
/// This icon uses the provided image as-is (scaled to the requested size) without applying the
/// default marker/pin shape.
///
/// ## ラベル
///
/// `label` を渡すと画像に文字を添える。書き方と既定値は `ColorDefaultIcon` と同じで、
/// react-sdk の `ImageIcon` とも揃えてある。
///
/// - `left` / `right` は画像の外側に置き、縦は画像の上端・中間・下端に揃える。
/// - `center` 列の `top` / `bottom` は画像の上・下の外側に置く。
/// - `"center center"`（既定）は画像の中央に重ねる。
///
/// `labelWritingMode` に `"vertical-rl"` を渡すと縦書きになる（``ColorDefaultIcon/labelWritingMode``）。
///
/// `anchor` / `infoAnchor` の指定は、ラベルの有無によらず**画像に対する割合**。
/// 公開している `anchor` / `infoAnchor` は、ラベルで広がった全体に対する割合へ直した値。
///
/// 画像は使われたときに初めて作る。タイル描画は本体の画像と文字を別々に使うので、
/// ラベル付きのアイコンをいくつ作っても、本体の画像は元の画像ごとに 1 枚で済む。
///
/// ## URL で渡す
///
/// `ImageIcon(imageUrl:)` は画像を自分で読み込む（``GroundImageState`` の `imageUrl` と同じ
/// ローダーを使い、同じ URL は 1 度しか取りに行かない）。読み終えるまでは同じ大きさ・アンカーの
/// 透明な画像を返し、読み終えたら、このアイコンを持っているマーカーが描き直される。
/// 失敗したときは透明のまま（ログに URL ごと 1 度だけ出す）。
///
/// `hashCode()` は URL と読み込みの状態（読み込み中・完了・失敗）から作る。状態は 1 度だけ
/// 変わり、そのときマーカーの描き直しの判定に掛かる。
public final class ImageIcon: MarkerIconProtocol, TileLabelledIcon {
    public static let defaultIconSize: CGFloat = DefaultMarkerIcon.defaultIconSize
    public static let defaultAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    public static let defaultInfoAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)

    public let iconSize: CGFloat
    public let scale: CGFloat
    public let anchor: CGPoint
    public let infoAnchor: CGPoint
    public let debug: Bool

    public let label: String?
    public let labelTextColor: UIColor?
    public let labelTextSize: CGFloat
    public let labelTypeFace: UIFont
    public let labelStrokeColor: UIColor
    public let labelPosition: String
    public let labelWritingMode: String

    /// `ImageIcon(imageUrl:)` で作ったときの URL。`ImageIcon(image:)` なら nil。
    public let imageUrl: URL?

    private let source: Source
    private let requestedAnchor: CGPoint
    private let requestedInfoAnchor: CGPoint
    private let layout: DefaultIconLayout
    private let pixelScale: CGFloat
    private let labelFont: UIFont
    private let outlineStrokeWidth: CGFloat
    private let labelSize: CGSize
    private let vertical: Bool
    private let body: ByReadiness<BitmapIcon>
    private let full: ByReadiness<BitmapIcon>

    public convenience init(
        image: UIImage,
        iconSize: CGFloat = defaultIconSize,
        scale: CGFloat = 1.0,
        anchor: CGPoint = defaultAnchor,
        infoAnchor: CGPoint = defaultInfoAnchor,
        debug: Bool = false,
        label: String? = nil,
        labelTextColor: UIColor? = ColorDefaultIcon.defaultLabelTextColor,
        labelTextSize: CGFloat = ColorDefaultIcon.defaultLabelTextSize,
        labelTypeFace: UIFont = ColorDefaultIcon.defaultLabelTypeFace,
        labelStrokeColor: UIColor = ColorDefaultIcon.defaultLabelStrokeColor,
        labelPosition: String = ColorDefaultIcon.defaultLabelPosition,
        labelWritingMode: String = ColorDefaultIcon.defaultLabelWritingMode
    ) {
        self.init(
            source: .image(image), iconSize: iconSize, scale: scale, anchor: anchor, infoAnchor: infoAnchor,
            debug: debug, label: label, labelTextColor: labelTextColor, labelTextSize: labelTextSize,
            labelTypeFace: labelTypeFace, labelStrokeColor: labelStrokeColor, labelPosition: labelPosition,
            labelWritingMode: labelWritingMode
        )
    }

    /// 画像を URL で渡す。読み終えるまでは透明。読み終えたら、このアイコンを持つマーカーが
    /// 描き直される。`file:` の URL も使える。
    public convenience init(
        imageUrl: URL,
        iconSize: CGFloat = defaultIconSize,
        scale: CGFloat = 1.0,
        anchor: CGPoint = defaultAnchor,
        infoAnchor: CGPoint = defaultInfoAnchor,
        debug: Bool = false,
        label: String? = nil,
        labelTextColor: UIColor? = ColorDefaultIcon.defaultLabelTextColor,
        labelTextSize: CGFloat = ColorDefaultIcon.defaultLabelTextSize,
        labelTypeFace: UIFont = ColorDefaultIcon.defaultLabelTypeFace,
        labelStrokeColor: UIColor = ColorDefaultIcon.defaultLabelStrokeColor,
        labelPosition: String = ColorDefaultIcon.defaultLabelPosition,
        labelWritingMode: String = ColorDefaultIcon.defaultLabelWritingMode
    ) {
        self.init(
            source: .url(LoadedImage(url: imageUrl, loader: .shared)), iconSize: iconSize, scale: scale,
            anchor: anchor, infoAnchor: infoAnchor, debug: debug, label: label, labelTextColor: labelTextColor,
            labelTextSize: labelTextSize, labelTypeFace: labelTypeFace, labelStrokeColor: labelStrokeColor,
            labelPosition: labelPosition, labelWritingMode: labelWritingMode
        )
    }

    /// テスト用。ローダーを差し替える。
    convenience init(imageUrl: URL, iconSize: CGFloat = defaultIconSize, loader: RemoteImageLoader) {
        self.init(
            source: .url(LoadedImage(url: imageUrl, loader: loader)), iconSize: iconSize, scale: 1.0,
            anchor: ImageIcon.defaultAnchor, infoAnchor: ImageIcon.defaultInfoAnchor, debug: false, label: nil,
            labelTextColor: ColorDefaultIcon.defaultLabelTextColor, labelTextSize: ColorDefaultIcon.defaultLabelTextSize,
            labelTypeFace: ColorDefaultIcon.defaultLabelTypeFace, labelStrokeColor: ColorDefaultIcon.defaultLabelStrokeColor,
            labelPosition: ColorDefaultIcon.defaultLabelPosition, labelWritingMode: ColorDefaultIcon.defaultLabelWritingMode
        )
    }

    private init(
        source: Source,
        iconSize: CGFloat,
        scale: CGFloat,
        anchor: CGPoint,
        infoAnchor: CGPoint,
        debug: Bool,
        label: String?,
        labelTextColor: UIColor?,
        labelTextSize: CGFloat,
        labelTypeFace: UIFont,
        labelStrokeColor: UIColor,
        labelPosition: String,
        labelWritingMode: String
    ) {
        self.source = source
        if case let .url(loaded) = source { self.imageUrl = loaded.url } else { self.imageUrl = nil }
        self.iconSize = iconSize
        self.scale = scale
        self.debug = debug
        self.label = label
        self.labelTextColor = labelTextColor
        self.labelTextSize = labelTextSize
        self.labelTypeFace = labelTypeFace
        self.labelStrokeColor = labelStrokeColor
        self.labelPosition = labelPosition
        self.labelWritingMode = labelWritingMode
        self.requestedAnchor = anchor
        self.requestedInfoAnchor = infoAnchor
        self.pixelScale = UIScreen.main.scale

        // 配置は文字の幅を測るだけなので、ここで済ませる。画像は作らない。
        let canvasSize = iconSize * scale
        let font = labelTypeFace.withSize(labelTextSize)
        let outline = max(1.0 * scale, 2.0)
        let vertical = LabelTypesetter.isVertical(labelWritingMode)
        let labelSize = label.map {
            ColorDefaultIcon.measureLabel($0, font: font, strokeWidth: outline, vertical: vertical)
        } ?? .zero
        let layout = DefaultIconLayout.make(
            canvasSize: canvasSize,
            body: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize),
            centerY: canvasSize / 2.0,
            sideCenterY: canvasSize / 2.0,
            labelSize: labelSize,
            outlineStrokeWidth: outline,
            labelPosition: labelPosition
        )
        self.layout = layout
        self.labelFont = font
        self.outlineStrokeWidth = outline
        self.labelSize = labelSize
        self.vertical = vertical
        self.anchor = CGPoint(
            x: (layout.markerOffsetX + anchor.x * canvasSize) / layout.bitmapWidth,
            y: (layout.markerOffsetY + anchor.y * canvasSize) / layout.bitmapHeight
        )
        self.infoAnchor = CGPoint(
            x: (layout.markerOffsetX + infoAnchor.x * canvasSize) / layout.bitmapWidth,
            y: (layout.markerOffsetY + infoAnchor.y * canvasSize) / layout.bitmapHeight
        )

        if labelSize != .zero {
            LabelledIconExtent.note(size: CGSize(width: layout.bitmapWidth, height: layout.bitmapHeight), anchor: self.anchor)
        }

        let pixelScale = self.pixelScale
        let body = ByReadiness<BitmapIcon> { state in
            BitmapIcon(
                bitmap: state.1.map {
                    ImageIcon.bodyImage($0, canvasSize: canvasSize, pixelScale: pixelScale, debug: debug)
                } ?? ImageIcon.blankBody(canvasSize: canvasSize, pixelScale: pixelScale, debug: debug),
                anchor: anchor,
                size: CGSize(width: canvasSize, height: canvasSize),
                scale: scale,
                iconSize: iconSize,
                infoAnchor: infoAnchor,
                debug: debug
            )
        }
        self.body = body
        let publicAnchor = self.anchor
        let publicInfoAnchor = self.infoAnchor
        let textColor = labelTextColor ?? ColorDefaultIcon.defaultLabelTextColor
        self.full = ByReadiness<BitmapIcon> { state in
            let bodyIcon = body.get(state)
            guard let label, labelSize != .zero else { return bodyIcon }
            let size = CGSize(width: layout.bitmapWidth, height: layout.bitmapHeight)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = pixelScale
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
                bodyIcon.bitmap.draw(in: CGRect(
                    x: layout.markerOffsetX, y: layout.markerOffsetY,
                    width: canvasSize, height: canvasSize
                ))
                ColorDefaultIcon.drawLabel(
                    context: context.cgContext,
                    labelText: label,
                    labelFont: font,
                    labelTextColor: textColor,
                    labelStrokeColor: labelStrokeColor,
                    center: layout.labelCenter,
                    bitmapHeight: size.height,
                    outlineStrokeWidth: outline,
                    pixelScale: pixelScale,
                    vertical: vertical
                )
            }
            return BitmapIcon(
                bitmap: rendered,
                anchor: publicAnchor,
                size: size,
                scale: scale,
                iconSize: iconSize,
                infoAnchor: publicInfoAnchor,
                debug: debug
            )
        }
    }

    public func toBitmapIcon() -> BitmapIcon { full.get(source.current()) }

    var tileBody: BitmapIcon { body.get(source.current()) }

    /// URL の画像を読み込み中なら、読み終えたとき（失敗も含む）にメインスレッドで 1 度だけ
    /// `callback` を呼んで true を返す。読み込み中でなければ何もせず false。
    ///
    /// ``MarkerState`` がこれで描き直しのきっかけを受け取る。
    func whenImageSettles(_ callback: @escaping () -> Void) -> Bool {
        guard case let .url(loaded) = source, loaded.readiness == .pending else { return false }
        return loaded.loader.whenSettled(loaded.url) { _ in callback() }
    }

    var tileLabel: MarkerTileLabel? {
        guard let label, labelSize != .zero else { return nil }
        let canvasSize = iconSize * scale
        let anchorX = layout.markerOffsetX + requestedAnchor.x * canvasSize
        let anchorY = layout.markerOffsetY + requestedAnchor.y * canvasSize
        return MarkerTileLabel(
            text: label,
            font: labelFont,
            textColor: labelTextColor ?? ColorDefaultIcon.defaultLabelTextColor,
            strokeColor: labelStrokeColor,
            outlineStrokeWidth: outlineStrokeWidth,
            centerOffset: CGPoint(x: layout.labelCenter.x - anchorX, y: layout.labelCenter.y - anchorY),
            size: labelSize,
            vertical: vertical
        )
    }

    var layoutSize: CGSize { CGSize(width: layout.bitmapWidth, height: layout.bitmapHeight) }

    public func hashCode() -> Int {
        var result: Int
        switch source {
        case let .image(image):
            result = image.hashValue
        case let .url(loaded):
            result = loaded.url.hashValue &* 31 &+ loaded.readiness.rawValue
        }
        result = result &* 31 &+ scale.hashValue
        result = result &* 31 &+ requestedAnchor.x.hashValue
        result = result &* 31 &+ requestedAnchor.y.hashValue
        result = result &* 31 &+ iconSize.hashValue
        result = result &* 31 &+ requestedInfoAnchor.x.hashValue
        result = result &* 31 &+ requestedInfoAnchor.y.hashValue
        result = result &* 31 &+ debug.hashValue
        result = result &* 31 &+ (label?.hashValue ?? 0)
        result = result &* 31 &+ (labelTextColor?.hashValue ?? 0)
        result = result &* 31 &+ labelTextSize.hashValue
        result = result &* 31 &+ labelTypeFace.hashValue
        result = result &* 31 &+ labelStrokeColor.hashValue
        result = result &* 31 &+ labelPosition.hashValue
        result = result &* 31 &+ labelWritingMode.hashValue
        return result
    }

    public func copy(
        image: UIImage? = nil,
        iconSize: CGFloat? = nil,
        scale: CGFloat? = nil,
        anchor: CGPoint? = nil,
        infoAnchor: CGPoint? = nil,
        debug: Bool? = nil,
        label: String? = nil,
        labelTextColor: UIColor? = nil,
        labelTextSize: CGFloat? = nil,
        labelTypeFace: UIFont? = nil,
        labelStrokeColor: UIColor? = nil,
        labelPosition: String? = nil,
        labelWritingMode: String? = nil
    ) -> ImageIcon {
        ImageIcon(
            source: image.map { Source.image($0) } ?? source,
            iconSize: iconSize ?? self.iconSize,
            scale: scale ?? self.scale,
            anchor: anchor ?? self.requestedAnchor,
            infoAnchor: infoAnchor ?? self.requestedInfoAnchor,
            debug: debug ?? self.debug,
            label: label ?? self.label,
            labelTextColor: labelTextColor ?? self.labelTextColor,
            labelTextSize: labelTextSize ?? self.labelTextSize,
            labelTypeFace: labelTypeFace ?? self.labelTypeFace,
            labelStrokeColor: labelStrokeColor ?? self.labelStrokeColor,
            labelPosition: labelPosition ?? self.labelPosition,
            labelWritingMode: labelWritingMode ?? self.labelWritingMode
        )
    }

    // MARK: - 画像の出どころ

    enum Readiness: Int {
        case pending = 0
        case ready = 1
        case failed = 2
    }

    private enum Source {
        case image(UIImage)
        case url(LoadedImage)

        /// 今描く画像。読み込み中・失敗なら nil。
        func current() -> (Readiness, UIImage?) {
            switch self {
            case let .image(image): return (.ready, image)
            case let .url(loaded): return loaded.current()
            }
        }
    }

    /// URL の画像。読み終えたら自分で持つ（ローダーのキャッシュから追い出されても困らない）。
    final class LoadedImage {
        let url: URL
        let loader: RemoteImageLoader
        private let lock = NSLock()
        private var image: UIImage?
        private var failed = false

        init(url: URL, loader: RemoteImageLoader) {
            self.url = url
            self.loader = loader
            // マーカーより先に登録する。マーカーが知らせを受けたときには、もう画像を持っている。
            loader.whenSettled(url) { [weak self] image in self?.settle(image) }
        }

        var readiness: Readiness { current().0 }

        func current() -> (Readiness, UIImage?) {
            lock.lock()
            if let image { lock.unlock(); return (.ready, image) }
            if failed { lock.unlock(); return (.failed, nil) }
            lock.unlock()
            switch loader.status(url) {
            case .pending:
                return (.pending, nil)
            case let .ready(image):
                settle(image)
                return (.ready, image)
            case .failed:
                settle(nil)
                return (.failed, nil)
            }
        }

        private func settle(_ image: UIImage?) {
            lock.lock()
            defer { lock.unlock() }
            if self.image != nil || failed { return }
            if let image { self.image = image } else { failed = true }
        }
    }

    /// 画像の状態ごとに 1 度だけ作って覚える。状態は読み込み中から完了・失敗へ 1 度だけ変わる。
    final class ByReadiness<Value> {
        private let lock = NSLock()
        private var cached: (Readiness, Value)?
        private let make: ((Readiness, UIImage?)) -> Value

        init(_ make: @escaping ((Readiness, UIImage?)) -> Value) {
            self.make = make
        }

        func get(_ state: (Readiness, UIImage?)) -> Value {
            lock.lock()
            defer { lock.unlock() }
            if let cached, cached.0 == state.0 { return cached.1 }
            let made = make(state)
            cached = (state.0, made)
            return made
        }
    }

    // MARK: - 本体の画像

    /// 読み込み中・失敗の本体。同じ大きさの透明な画像。
    private static func blankBody(canvasSize: CGFloat, pixelScale: CGFloat, debug: Bool) -> UIImage {
        let size = CGSize(width: canvasSize, height: canvasSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = pixelScale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if debug {
                context.cgContext.setStrokeColor(UIColor.black.cgColor)
                context.cgContext.setLineWidth(1.0)
                context.cgContext.stroke(CGRect(origin: .zero, size: size))
            }
        }
    }

    /// 元の画像 -> 大きさごとの本体の画像。
    ///
    /// 元の画像は弱参照で、ポインタの同一性で引く。元の画像が解放されれば行ごと消えるので、
    /// 解放後に同じアドレスへ来た別の画像が古い本体を拾うことはない。
    private static let bodyCache = NSMapTable<UIImage, NSMutableDictionary>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory
    )
    private static let bodyCacheLock = NSLock()

    private static func bodyImage(_ image: UIImage, canvasSize: CGFloat, pixelScale: CGFloat, debug: Bool) -> UIImage {
        let key = "\(canvasSize)/\(pixelScale)/\(debug)" as NSString
        bodyCacheLock.lock()
        if let cached = bodyCache.object(forKey: image)?[key] as? UIImage {
            bodyCacheLock.unlock()
            return cached
        }
        bodyCacheLock.unlock()

        let size = CGSize(width: canvasSize, height: canvasSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = pixelScale
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if debug {
                context.cgContext.setStrokeColor(UIColor.black.cgColor)
                context.cgContext.setLineWidth(1.0)
                context.cgContext.stroke(CGRect(origin: .zero, size: size))
            }
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        bodyCacheLock.lock()
        defer { bodyCacheLock.unlock() }
        let sizes = bodyCache.object(forKey: image) ?? {
            let fresh = NSMutableDictionary()
            bodyCache.setObject(fresh, forKey: image)
            return fresh
        }()
        if let raced = sizes[key] as? UIImage { return raced }
        sizes[key] = rendered
        return rendered
    }
}
