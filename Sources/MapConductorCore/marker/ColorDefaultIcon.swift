import CoreText
import UIKit

/// 単色で塗る既定アイコン（カラーフィル版の DefaultIcon）。
/// `DefaultMarkerIcon` はこれの別名。
public final class ColorDefaultIcon: MarkerIconProtocol {
    public static let defaultIconSize: CGFloat = Settings.Default.iconSize
    public static let defaultStrokeWidth: CGFloat = Settings.Default.iconStroke
    public static let defaultFillColor: UIColor = .red
    public static let defaultStrokeColor: UIColor = .white
    public static let defaultLabelTextSize: CGFloat = 18.0
    public static let defaultLabelTextColor: UIColor = .black
    public static let defaultLabelStrokeColor: UIColor = .white
    public static let defaultLabelTypeFace: UIFont = .systemFont(ofSize: 18.0)
    public static let defaultInfoAnchor = CGPoint(x: 0.5, y: 0.0)
    /// ラベルの既定位置。ピンの頭に重ねる（従来どおり）。書き方は `labelPosition` を参照。
    public static let defaultLabelPosition = "center center"


    public let scale: CGFloat
    public let anchor: CGPoint
    public let iconSize: CGFloat
    public let infoAnchor: CGPoint
    public let debug: Bool

    private let fillColor: UIColor
    private let strokeColor: UIColor
    private let strokeWidth: CGFloat
    private let label: String?
    private let labelTextColor: UIColor?
    private let labelTextSize: CGFloat
    private let labelTypeFace: UIFont
    private let labelStrokeColor: UIColor
    /// ラベルをピンに対してどこへ置くか。CSS の `background-position` と同じ書き方で、
    /// 横（left / center / right）と縦（top / center / bottom）のキーワードを空白区切りで
    /// 並べる。順序は問わず、片方だけなら残りは center。
    /// - left / right はピンの外側に置き、縦はピンの上端・上端と先端の中間・先端に揃える。
    /// - center 列の top / bottom はピンの上・下の外側に置く。
    public let labelPosition: String
    /// 指定された infoAnchor（ピン本体に対する割合）。`infoAnchor` はビットマップに対する割合へ直した値。
    private let requestedInfoAnchor: CGPoint
    private let bitmapIcon: BitmapIcon

    public init(
        fillColor: UIColor = defaultFillColor,
        strokeColor: UIColor = defaultStrokeColor,
        strokeWidth: CGFloat = defaultStrokeWidth,
        scale: CGFloat = 1.0,
        label: String? = nil,
        labelTextColor: UIColor? = defaultLabelTextColor,
        labelTextSize: CGFloat = defaultLabelTextSize,
        labelTypeFace: UIFont = defaultLabelTypeFace,
        labelStrokeColor: UIColor = defaultLabelStrokeColor,
        labelPosition: String = defaultLabelPosition,
        infoAnchor: CGPoint = defaultInfoAnchor,
        iconSize: CGFloat = defaultIconSize,
        debug: Bool = false
    ) {
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.scale = scale
        self.label = label
        self.labelTextColor = labelTextColor
        self.labelTextSize = labelTextSize
        self.labelTypeFace = labelTypeFace
        self.labelStrokeColor = labelStrokeColor
        self.labelPosition = labelPosition
        self.requestedInfoAnchor = infoAnchor
        self.iconSize = iconSize
        self.debug = debug
        let bitmapIcon = ColorDefaultIcon.makeIcon(
            iconSize: iconSize,
            scale: scale,
            fillColor: fillColor,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            label: label,
            labelTextColor: labelTextColor,
            labelTextSize: labelTextSize,
            labelTypeFace: labelTypeFace,
            labelStrokeColor: labelStrokeColor,
            labelPosition: labelPosition,
            infoAnchor: infoAnchor,
            debug: debug
        )
        // ラベルを横や上に置くとビットマップが片側へ伸びるので、どちらもレイアウトから求めた値を使う。
        self.anchor = bitmapIcon.anchor
        self.infoAnchor = bitmapIcon.infoAnchor
        self.bitmapIcon = bitmapIcon
    }

    public func toBitmapIcon() -> BitmapIcon {
        bitmapIcon
    }

    public func hashCode() -> Int {
        var result = fillColor.hashValue
        result = result &* 31 &+ strokeColor.hashValue
        result = result &* 31 &+ strokeWidth.hashValue
        result = result &* 31 &+ scale.hashValue
        result = result &* 31 &+ (label?.hashValue ?? 0)
        result = result &* 31 &+ (labelTextColor?.hashValue ?? 0)
        result = result &* 31 &+ labelTextSize.hashValue
        result = result &* 31 &+ labelTypeFace.hashValue
        result = result &* 31 &+ labelStrokeColor.hashValue
        result = result &* 31 &+ labelPosition.hashValue
        result = result &* 31 &+ requestedInfoAnchor.x.hashValue
        result = result &* 31 &+ requestedInfoAnchor.y.hashValue
        result = result &* 31 &+ iconSize.hashValue
        result = result &* 31 &+ debug.hashValue
        return result
    }

    public func copy(
        fillColor: UIColor? = nil,
        strokeColor: UIColor? = nil,
        strokeWidth: CGFloat? = nil,
        scale: CGFloat? = nil,
        label: String? = nil,
        labelTextColor: UIColor? = nil,
        labelTextSize: CGFloat? = nil,
        labelTypeFace: UIFont? = nil,
        labelStrokeColor: UIColor? = nil,
        labelPosition: String? = nil,
        iconSize: CGFloat? = nil,
        debug: Bool? = nil
    ) -> ColorDefaultIcon {
        ColorDefaultIcon(
            fillColor: fillColor ?? self.fillColor,
            strokeColor: strokeColor ?? self.strokeColor,
            strokeWidth: strokeWidth ?? self.strokeWidth,
            scale: scale ?? self.scale,
            label: label ?? self.label,
            labelTextColor: labelTextColor ?? self.labelTextColor,
            labelTextSize: labelTextSize ?? self.labelTextSize,
            labelTypeFace: labelTypeFace ?? self.labelTypeFace,
            labelStrokeColor: labelStrokeColor ?? self.labelStrokeColor,
            labelPosition: labelPosition ?? self.labelPosition,
            infoAnchor: self.requestedInfoAnchor,
            iconSize: iconSize ?? self.iconSize,
            debug: debug ?? self.debug
        )
    }

    private static func makeIcon(
        iconSize: CGFloat,
        scale: CGFloat,
        fillColor: UIColor,
        strokeColor: UIColor,
        strokeWidth: CGFloat,
        label: String?,
        labelTextColor: UIColor?,
        labelTextSize: CGFloat,
        labelTypeFace: UIFont,
        labelStrokeColor: UIColor,
        labelPosition: String,
        infoAnchor: CGPoint,
        debug: Bool
    ) -> BitmapIcon {
        let canvasSize = iconSize * scale
        let resolvedFont = labelTypeFace.withSize(labelTextSize)
        let outlineStrokeWidth = max(1.0 * scale, 2.0)

        var labelSize: CGSize = .zero
        if let label {
            labelSize = measureLabel(label, font: resolvedFont, strokeWidth: outlineStrokeWidth)
        }

        let layout = DefaultIconLayout.make(
            canvasSize: canvasSize,
            iconScale: scale,
            strokeWidth: strokeWidth,
            labelSize: labelSize,
            outlineStrokeWidth: outlineStrokeWidth,
            labelPosition: labelPosition
        )
        let bitmapWidth = layout.bitmapWidth
        let bitmapHeight = layout.bitmapHeight

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: bitmapWidth, height: bitmapHeight), format: format)
        let image = renderer.image { context in
            if debug {
                context.cgContext.setStrokeColor(UIColor.black.cgColor)
                context.cgContext.setLineWidth(1.0)
                context.cgContext.stroke(CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))
            }

            let path = createMarkerPath(
                canvasSize: canvasSize,
                iconScale: scale,
                strokeWidth: strokeWidth,
                horizontalOffset: layout.markerOffsetX,
                verticalOffset: layout.markerOffsetY
            )

            context.cgContext.setFillColor(fillColor.cgColor)
            context.cgContext.addPath(path.cgPath)
            context.cgContext.fillPath()

            context.cgContext.setStrokeColor(strokeColor.cgColor)
            context.cgContext.setLineWidth(strokeWidth * scale)
            context.cgContext.setLineJoin(.round)
            context.cgContext.setLineCap(.round)
            context.cgContext.addPath(path.cgPath)
            context.cgContext.strokePath()

            if let label, labelSize != .zero {
                drawLabel(
                    context: context.cgContext,
                    labelText: label,
                    labelFont: resolvedFont,
                    labelTextColor: labelTextColor ?? defaultLabelTextColor,
                    labelStrokeColor: labelStrokeColor,
                    center: layout.labelCenter,
                    bitmapHeight: bitmapHeight,
                    outlineStrokeWidth: outlineStrokeWidth,
                    pixelScale: format.scale
                )
            }
        }
        return BitmapIcon(
            bitmap: image,
            anchor: layout.anchor,
            size: CGSize(width: bitmapWidth, height: bitmapHeight),
            scale: scale,
            iconSize: iconSize,
            infoAnchor: layout.infoAnchor(for: infoAnchor)
        )
    }

    internal static func measureLabel(_ label: String, font: UIFont, strokeWidth: CGFloat) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent
        let padding = strokeWidth * 2.0
        return CGSize(width: width + padding, height: height + padding)
    }

    internal static func drawLabel(
        context: CGContext,
        labelText: String,
        labelFont: UIFont,
        labelTextColor: UIColor,
        labelStrokeColor: UIColor,
        center: CGPoint,
        bitmapHeight: CGFloat,
        outlineStrokeWidth: CGFloat,
        pixelScale: CGFloat
    ) {
        // DefaultIconLayout が決めたラベルの中心。既定ではマーカーの円形部分の中心。
        let markerCenterX = center.x
        let markerCenterY = center.y

        let baseAttributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let baseLine = CTLineCreateWithAttributedString(NSAttributedString(string: labelText, attributes: baseAttributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(baseLine, &ascent, &descent, &leading))
        let baselineY = markerCenterY + (ascent - descent) / 2.0

        let drawX = alignToPixel(markerCenterX - lineWidth / 2.0, scale: pixelScale)
        let drawBaselineY = alignToPixel(baselineY, scale: pixelScale)
        let strokePercent = (outlineStrokeWidth / max(labelFont.pointSize, 1.0)) * 100.0

        context.saveGState()
        context.textMatrix = .identity
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)

        context.translateBy(x: 0, y: bitmapHeight)
        context.scaleBy(x: 1.0, y: -1.0)

        let flippedBaselineY = bitmapHeight - drawBaselineY
        context.textPosition = CGPoint(x: drawX, y: flippedBaselineY)

        let strokeAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .strokeColor: labelStrokeColor,
            .strokeWidth: strokePercent,
            .foregroundColor: labelStrokeColor
        ]
        let fillAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelTextColor
        ]

        let strokeLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: labelText, attributes: strokeAttributes)
        )
        CTLineDraw(strokeLine, context)

        context.textPosition = CGPoint(x: drawX, y: flippedBaselineY)
        let fillLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: labelText, attributes: fillAttributes)
        )
        CTLineDraw(fillLine, context)

        context.restoreGState()
    }

    internal static func alignToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    static func createMarkerPath(
        canvasSize: CGFloat,
        iconScale: CGFloat,
        strokeWidth: CGFloat,
        horizontalOffset: CGFloat = 0.0,
        verticalOffset: CGFloat = 0.0
    ) -> UIBezierPath {
        let metrics = markerPathMetrics(canvasSize: canvasSize, iconScale: iconScale, strokeWidth: strokeWidth)
        let markerScale = metrics.markerScale
        let offsetX = metrics.offsetX + horizontalOffset
        let offsetY = metrics.offsetY + verticalOffset

        let path = UIBezierPath()
        var current = CGPoint(
            x: 12.0 * markerScale + offsetX,
            y: 0.0 * markerScale + offsetY
        )
        path.move(to: current)

        func rCubicTo(_ dx1: CGFloat, _ dy1: CGFloat, _ dx2: CGFloat, _ dy2: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
            let control1 = CGPoint(x: current.x + dx1, y: current.y + dy1)
            let control2 = CGPoint(x: current.x + dx2, y: current.y + dy2)
            let end = CGPoint(x: current.x + dx, y: current.y + dy)
            path.addCurve(to: end, controlPoint1: control1, controlPoint2: control2)
            current = end
        }

        func rLineTo(_ dx: CGFloat, _ dy: CGFloat) {
            let end = CGPoint(x: current.x + dx, y: current.y + dy)
            path.addLine(to: end)
            current = end
        }

        rCubicTo(
            -4.4183 * markerScale,
            2.3685e-15 * markerScale,
            -8.0 * markerScale,
            3.5817 * markerScale,
            -8.0 * markerScale,
            8.0 * markerScale
        )

        rCubicTo(
            0.0 * markerScale,
            1.421 * markerScale,
            0.3816 * markerScale,
            2.75 * markerScale,
            1.0312 * markerScale,
            3.906 * markerScale
        )

        rCubicTo(
            0.1079 * markerScale,
            0.192 * markerScale,
            0.221 * markerScale,
            0.381 * markerScale,
            0.3438 * markerScale,
            0.563 * markerScale
        )

        rLineTo(6.625 * markerScale, 11.531 * markerScale)
        rLineTo(6.625 * markerScale, -11.531 * markerScale)

        rCubicTo(
            0.102 * markerScale,
            -0.151 * markerScale,
            0.19 * markerScale,
            -0.311 * markerScale,
            0.281 * markerScale,
            -0.469 * markerScale
        )

        rLineTo(0.063 * markerScale, -0.094 * markerScale)

        rCubicTo(
            0.649 * markerScale,
            -1.156 * markerScale,
            1.031 * markerScale,
            -2.485 * markerScale,
            1.031 * markerScale,
            -3.906 * markerScale
        )

        rCubicTo(
            0.0 * markerScale,
            -4.4183 * markerScale,
            -3.582 * markerScale,
            -8.0 * markerScale,
            -8.0 * markerScale,
            -8.0 * markerScale
        )

        path.close()
        return path
    }

    /// ピン形を canvasSize の正方形へ収めたときの倍率と原点（パス外接箱の左上）。
    /// `createMarkerPath` と、ラベルをピンの輪郭に沿わせる `DefaultIconLayout` が共有する。
    static func markerPathMetrics(
        canvasSize: CGFloat,
        iconScale: CGFloat,
        strokeWidth: CGFloat
    ) -> (markerScale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        let originalSize = CGSize(width: 23.5, height: 25.6)

        let scaledStrokeWidth = strokeWidth * iconScale
        let epsilon: CGFloat = 0.75
        let padding = max((scaledStrokeWidth / 2.0) - epsilon, 0.0)
        let availableWidth = canvasSize - (padding * 2.0)
        let availableHeight = canvasSize - padding

        let markerScale = min(
            availableWidth / originalSize.width,
            availableHeight / originalSize.height
        )

        let scaledWidth = originalSize.width * markerScale
        let scaledHeight = originalSize.height * markerScale
        let offsetX = (canvasSize - scaledWidth) / 2.0
        let offsetY = (canvasSize - scaledHeight + (strokeWidth * markerScale)) / 2.0
        return (markerScale, offsetX, offsetY)
    }
}

/// 既定アイコンのビットマップ内でのマーカー本体とラベルの配置。
///
/// android-sdk / react-sdk の `computeLayout` と同じ計算。`labelPosition` が中央なら従来どおり
/// ラベルを円形部分の中心に重ね、ビットマップを左右対称に広げる。中央以外なら
/// ラベルをピンの輪郭の外側へ置き、ビットマップをその側へだけ伸ばす。
struct DefaultIconLayout {
    let canvasSize: CGFloat
    let bitmapWidth: CGFloat
    let bitmapHeight: CGFloat
    let markerOffsetX: CGFloat
    let markerOffsetY: CGFloat
    let labelCenter: CGPoint

    /// ピン先端の位置（ビットマップに対する割合）。
    var anchor: CGPoint {
        CGPoint(
            x: (markerOffsetX + canvasSize / 2.0) / bitmapWidth,
            y: (markerOffsetY + canvasSize) / bitmapHeight
        )
    }

    /// ピン本体に対する割合で指定された infoAnchor を、ビットマップに対する割合へ直す。
    func infoAnchor(for requested: CGPoint) -> CGPoint {
        CGPoint(
            x: (markerOffsetX + requested.x * canvasSize) / bitmapWidth,
            y: (markerOffsetY + requested.y * canvasSize) / bitmapHeight
        )
    }

    /// `labelPosition` を横・縦それぞれ -1 / 0 / 1 に読み替える。CSS の background-position と
    /// 同じく、キーワードの順序は問わず、片方だけなら残りは center。読めない値は中央扱い。
    static func parseLabelPosition(_ position: String) -> (h: Int, v: Int) {
        var h = 0
        var v = 0
        for word in position.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            switch word {
            case "left": h = -1
            case "right": h = 1
            case "top": v = -1
            case "bottom": v = 1
            default: break
            }
        }
        return (h, v)
    }

    /// `labelSize` はアウトライン込みのラベル寸法（ラベルが無ければ .zero）。
    static func make(
        canvasSize: CGFloat,
        iconScale: CGFloat,
        strokeWidth: CGFloat,
        labelSize: CGSize,
        outlineStrokeWidth: CGFloat,
        labelPosition: String
    ) -> DefaultIconLayout {
        // 円形部分の中心
        let headCenterY = canvasSize * 0.35
        let padding = canvasSize * 0.1

        guard labelSize != .zero else {
            return DefaultIconLayout(
                canvasSize: canvasSize,
                bitmapWidth: canvasSize,
                bitmapHeight: canvasSize,
                markerOffsetX: 0,
                markerOffsetY: 0,
                labelCenter: CGPoint(x: canvasSize / 2.0, y: headCenterY)
            )
        }

        let (h, v) = parseLabelPosition(labelPosition)
        // ピンの見えている輪郭（設計座標で x: 4〜20, y: 0〜24）。外接箱より細いので、
        // ラベルを横に置くときはこちらに沿わせる。
        let metrics = DefaultMarkerIcon.markerPathMetrics(
            canvasSize: canvasSize,
            iconScale: iconScale,
            strokeWidth: strokeWidth
        )
        let s = metrics.markerScale
        let pinLeft = metrics.offsetX + 4.0 * s
        let pinRight = metrics.offsetX + 20.0 * s
        let pinTop = metrics.offsetY
        let pinBottom = metrics.offsetY + 24.0 * s
        let gap = max(outlineStrokeWidth, canvasSize * 0.05)
        let labelWidth = labelSize.width
        let labelHeight = labelSize.height

        // マーカー本体の左上を原点とした座標でラベルの中心を決める。
        let cx: CGFloat
        if h < 0 {
            cx = pinLeft - gap - labelWidth / 2.0
        } else if h > 0 {
            cx = pinRight + gap + labelWidth / 2.0
        } else {
            cx = canvasSize / 2.0
        }

        var cy = headCenterY
        if h != 0 {
            // 横に置くときは、縦はピンの上端・上端と先端の中間・先端に揃える。
            // center を頭の中心にすると、ピン全体の中央より上に見える。
            if v < 0 { cy = pinTop + labelHeight / 2.0 }
            if v > 0 { cy = pinBottom - labelHeight / 2.0 }
            if v == 0 { cy = (pinTop + pinBottom) / 2.0 }
        } else {
            // 中央列の top / bottom はピンと重ならないよう上下の外側に置く。
            if v < 0 { cy = pinTop - gap - labelHeight / 2.0 }
            if v > 0 { cy = pinBottom + gap + labelHeight / 2.0 }
        }

        let bitmapWidth: CGFloat
        let markerOffsetX: CGFloat
        if h == 0 {
            // 中央なら従来どおり（出力を変えない）。
            bitmapWidth = max(canvasSize, labelWidth + padding)
            markerOffsetX = (bitmapWidth - canvasSize) / 2.0
        } else {
            let minX = min(0, cx - labelWidth / 2.0 - padding / 2.0)
            let maxX = max(canvasSize, cx + labelWidth / 2.0 + padding / 2.0)
            bitmapWidth = (maxX - minX).rounded(.up)
            markerOffsetX = -minX
        }

        let minY = min(0, cy - labelHeight / 2.0)
        let maxY = max(canvasSize, cy + labelHeight / 2.0)
        let markerOffsetY = (-minY).rounded(.up)
        let bitmapHeight = markerOffsetY + maxY.rounded(.up)

        return DefaultIconLayout(
            canvasSize: canvasSize,
            bitmapWidth: bitmapWidth,
            bitmapHeight: bitmapHeight,
            markerOffsetX: markerOffsetX,
            markerOffsetY: markerOffsetY,
            labelCenter: CGPoint(x: markerOffsetX + cx, y: markerOffsetY + cy)
        )
    }
}

/// 歴史的経緯で使われてきた `ColorDefaultIcon` の別名。
/// android-sdk の `typealias DefaultMarkerIcon = ColorDefaultIcon` と同じ位置づけ。
public typealias DefaultMarkerIcon = ColorDefaultIcon
