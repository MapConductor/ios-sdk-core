import CoreGraphics
import SwiftUI

/// Draws the default bubble chrome — background, border, corner radius and tail.
///
/// The parameters mirror `DrawInfoBubble` in `android-sdk-compose` one for one, so the
/// same bubble is described the same way on both platforms.
public struct DefaultInfoBubbleView: View {
    private let bubbleColor: Color
    private let borderColor: Color
    private let contentPadding: CGFloat
    private let cornerRadius: CGFloat
    private let tailSize: CGFloat
    private let content: AnyView

    public init(
        bubbleColor: Color = .white,
        borderColor: Color = .black,
        contentPadding: CGFloat = 8.0,
        cornerRadius: CGFloat = 4.0,
        tailSize: CGFloat = 8.0,
        content: AnyView
    ) {
        self.bubbleColor = bubbleColor
        self.borderColor = borderColor
        self.contentPadding = contentPadding
        self.cornerRadius = cornerRadius
        self.tailSize = tailSize
        self.content = content
    }

    public var body: some View {
        ZStack {
            InfoBubbleShape(cornerRadius: cornerRadius, tailSize: tailSize)
                .fill(bubbleColor)
                .overlay(
                    InfoBubbleShape(cornerRadius: cornerRadius, tailSize: tailSize)
                        .stroke(borderColor, lineWidth: 2.0)
                )

            content
                .padding(.init(
                    top: contentPadding,
                    leading: contentPadding,
                    bottom: contentPadding + tailSize,
                    trailing: contentPadding
                ))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .fixedSize()
    }
}

private struct InfoBubbleShape: Shape {
    let cornerRadius: CGFloat
    let tailSize: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let corner = cornerRadius
        let tail = tailSize

        var path = Path()
        path.move(to: CGPoint(x: 2 * corner, y: 0))
        path.addLine(to: CGPoint(x: width - 2 * corner, y: 0))
        path.addArc(
            center: CGPoint(x: width - corner, y: corner),
            radius: corner,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: width, y: height - tail - 2 * corner))
        path.addArc(
            center: CGPoint(x: width - corner, y: height - tail - corner),
            radius: corner,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: width / 2 + tail / 2, y: height - tail))
        path.addLine(to: CGPoint(x: width / 2, y: height))
        path.addLine(to: CGPoint(x: width / 2 - tail / 2, y: height - tail))
        path.addLine(to: CGPoint(x: 2 * corner, y: height - tail))
        path.addArc(
            center: CGPoint(x: corner, y: height - tail - corner),
            radius: corner,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: 0, y: 2 * corner))
        path.addArc(
            center: CGPoint(x: corner, y: corner),
            radius: corner,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
