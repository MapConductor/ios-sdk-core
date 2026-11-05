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

    private let image: UIImage
    private let requestedAnchor: CGPoint
    private let requestedInfoAnchor: CGPoint
    private let layout: DefaultIconLayout
    private let pixelScale: CGFloat
    private let labelFont: UIFont
    private let outlineStrokeWidth: CGFloat
    private let labelSize: CGSize
    private let vertical: Bool
    private let body: LazyBox<BitmapIcon>
    private let full: LazyBox<BitmapIcon>

    public init(
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
        self.image = image
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
        let body = LazyBox {
            BitmapIcon(
                bitmap: ImageIcon.bodyImage(image, canvasSize: canvasSize, pixelScale: pixelScale, debug: debug),
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
        self.full = LazyBox {
            let bodyIcon = body.get()
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

    public func toBitmapIcon() -> BitmapIcon { full.get() }

    var tileBody: BitmapIcon { body.get() }

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
        var result = image.hashValue
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
            image: image ?? self.image,
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

    // MARK: - 本体の画像

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
