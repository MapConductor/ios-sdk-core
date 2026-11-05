import CoreText
import UIKit

/// タイルに描くとき、アイコン本体とは別に描くラベル。
///
/// ## なぜ分けるか
///
/// ラベルを焼き込んだビットマップは、文字列と置き場所の組の数だけ要る。
/// 街路樹のように「樹種 × 向き」でラベルを付け替えると、そのたびに画像を作り、
/// タイルのアトラスにも別の絵として積むことになる。本体（点やピン）だけを
/// アトラスに入れ、文字はタイルを描くときに直接描けば、画像は本体の種類だけで済む。
///
/// ネイティブマーカーとして描くときは、従来どおり焼き込んだビットマップ
/// （`toBitmapIcon()`）を使う。どちらも配置は `DefaultIconLayout` の同じ計算から出す。
struct MarkerTileLabel {
    let text: String
    /// 大きさはアイコンの `scale` 込み。タイルではさらに描画倍率を掛ける。
    let font: UIFont
    let textColor: UIColor
    let strokeColor: UIColor
    let outlineStrokeWidth: CGFloat
    /// ラベルの中心の、アンカー点からのずれ（pt）。
    let centerOffset: CGPoint
    /// 縁取り込みの大きさ（pt）。
    let size: CGSize
    /// 縦書きか。``LabelTypesetter`` を参照。
    let vertical: Bool

    /// 上が原点の座標系（タイル描画の context）で、中心 (`centerX`, `centerY`) に描く。
    ///
    /// 書き出し位置は整数の画素に揃える。タイルの原点も整数の画素なので、
    /// 境界をまたぐラベルは両側のタイルが同じ画素から描き、継ぎ目で字が割れない。
    func draw(in context: CGContext, centerX: CGFloat, centerY: CGFloat, scale: CGFloat) {
        LabelTypesetter.draw(
            text,
            in: context,
            centerX: centerX,
            centerY: centerY,
            font: font.withSize(font.pointSize * scale),
            textColor: textColor,
            strokeColor: strokeColor,
            outlineStrokeWidth: outlineStrokeWidth * scale,
            vertical: vertical,
            pixelScale: 1
        )
    }
}

/// 本体とラベルを分けて渡せるアイコン。
///
/// タイル描画は `tileBody` をアトラスに入れ、`tileLabel` をタイルに直接描く。
/// どちらも焼き込みのビットマップを作らずに得られるので、ラベル付きのアイコンを
/// 大量に作っても、ネイティブマーカーとして描かれない限り画像は増えない。
protocol TileLabelledIcon: MarkerIconProtocol {
    /// ラベルを除いた本体。アンカーは本体に対する割合。
    var tileBody: BitmapIcon { get }
    var tileLabel: MarkerTileLabel? { get }
    /// ラベル込みの全体の大きさ（pt）。`anchor` はこれに対する割合。
    var layoutSize: CGSize { get }
}

/// 一度だけ作って覚える値。タイルは複数のスレッドから同時に描かれるので鍵を掛ける。
final class LazyBox<Value> {
    private let lock = NSLock()
    private var value: Value?
    private let make: () -> Value

    init(_ make: @escaping () -> Value) {
        self.make = make
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let made = make()
        value = made
        return made
    }
}

/// ラベルの文字の測り方と描き方。焼き込み（``ColorDefaultIcon`` / ``ImageIcon``）とタイル
/// （``MarkerTileLabel``）の両方がここを通るので、どちらで描いても同じ字面になる。
///
/// ## 縦書き
///
/// `labelWritingMode` は CSS の `writing-mode` と同じ書き方で、`vertical-rl` / `vertical-lr` を
/// 縦書きとして扱う（1 行しかないので左右の違いは出ない）。それ以外は横書き。
///
/// 縦書きは CoreText の縦組み用の字形（`verticalGlyphForm`）で 1 行を組み、文字の進む向きが
/// 下になるように回して描く。長音の「ー」は縦棒に、小書きの「ョ」は縦書きの位置になる。
/// 横の通りに沿って並ぶ街路樹のように、横書きでは幅を取りすぎて並ばないラベルに使う。
enum LabelTypesetter {
    static let horizontal = "horizontal-tb"

    static func isVertical(_ writingMode: String) -> Bool {
        let mode = writingMode.trimmingCharacters(in: .whitespaces).lowercased()
        return mode == "vertical-rl" || mode == "vertical-lr"
    }

    /// 縁取り込みの大きさ（pt）。縦書きなら幅は 1 文字ぶん、高さが文字列の長さになる。
    static func measure(_ text: String, font: UIFont, strokeWidth: CGFloat, vertical: Bool) -> CGSize {
        let padding = strokeWidth * 2.0
        let line = makeLine(text, attributes: [.font: font], vertical: vertical)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let length = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard vertical else {
            return CGSize(width: length + padding, height: ascent + descent + padding)
        }
        // 縦組みの字形は行の中心線に沿って並ぶので、列の幅は字面の外接矩形から取る。
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return CGSize(width: ceil(glyphs.height) + padding, height: length + padding)
    }

    /// 上が原点の context に、中心 (`centerX`, `centerY`) で描く。`font` と `outlineStrokeWidth` は
    /// context の単位で渡す。書き出し位置は `pixelScale` の画素に揃える。
    static func draw(
        _ text: String,
        in context: CGContext,
        centerX: CGFloat,
        centerY: CGFloat,
        font: UIFont,
        textColor: UIColor,
        strokeColor: UIColor,
        outlineStrokeWidth: CGFloat,
        vertical: Bool,
        pixelScale: CGFloat
    ) {
        func align(_ value: CGFloat) -> CGFloat {
            guard pixelScale > 0 else { return value }
            return (value * pixelScale).rounded() / pixelScale
        }
        let strokePercent = (outlineStrokeWidth / max(font.pointSize, 1.0)) * 100.0
        let stroke = makeLine(text, attributes: [
            .font: font,
            .strokeColor: strokeColor,
            .strokeWidth: strokePercent,
            .foregroundColor: strokeColor,
        ], vertical: vertical)
        let fill = makeLine(text, attributes: [.font: font, .foregroundColor: textColor], vertical: vertical)

        context.saveGState()
        context.textMatrix = .identity
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setShouldAntialias(true)
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)

        let origin: CGPoint
        if vertical {
            // 中心へ寄せてから、CoreText の向き（上が正）に戻し、文字の進む向きが下になるよう回す。
            // 回したあとの行の座標で、字面の外接矩形の中心が原点に来るように置く。
            context.translateBy(x: align(centerX), y: align(centerY))
            context.scaleBy(x: 1, y: -1)
            context.rotate(by: -.pi / 2)
            let glyphs = CTLineGetBoundsWithOptions(fill, .useGlyphPathBounds)
            origin = CGPoint(x: -glyphs.midX, y: -glyphs.midY)
        } else {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(fill, &ascent, &descent, &leading))
            // context は上が原点。CoreText は下が原点で字を積むので、ここだけ戻す。
            context.translateBy(x: align(centerX - width / 2.0), y: align(centerY + (ascent - descent) / 2.0))
            context.scaleBy(x: 1, y: -1)
            origin = .zero
        }

        context.textPosition = origin
        CTLineDraw(stroke, context)
        context.textPosition = origin
        CTLineDraw(fill, context)
        context.restoreGState()
    }

    private static func makeLine(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        vertical: Bool
    ) -> CTLine {
        var attributes = attributes
        if vertical { attributes[.verticalGlyphForm] = true }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}

/// ラベル付きのアイコンのはみ出し量（アンカーからいちばん遠い辺まで、pt）の、プロセス全体での最大。
///
/// ``ColorDefaultIcon`` と ``ImageIcon`` は作った時点で配置を計算するので、ここへ記録する。
/// タイル描画は、隣のタイルからはみ出してくるラベルを取りこぼさないよう、この値で探す範囲を
/// 広げる（``MarkerTileRenderer`` の `queryHalfExtentPx`）。マーカーに付ける前にアイコンは
/// 作られるので、タイルが描き直される時点ではもう記録されている。
///
/// 小さくはならない。大きなラベルを一度作ると、以後は少し広めに探す。
enum LabelledIconExtent {
    private static let lock = NSLock()
    private static var current: Double = 0

    static var maxPt: Double {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    static func note(size: CGSize, anchor: CGPoint) {
        let w = Double(size.width)
        let h = Double(size.height)
        let ax = Double(anchor.x)
        let ay = Double(anchor.y)
        let extent = max(max(w * ax, w * (1 - ax)), max(h * ay, h * (1 - ay)))
        lock.lock()
        if extent > current { current = extent }
        lock.unlock()
    }
}
