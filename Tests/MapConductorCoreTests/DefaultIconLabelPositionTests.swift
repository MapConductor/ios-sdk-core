import UIKit
import XCTest

@testable import MapConductorCore

/// 既定アイコンの `labelPosition` がビットマップの寸法とアンカーをどう変えるか。
///
/// react-sdk の `DefaultIconLabelPosition.test.mjs`、android-sdk の
/// `DefaultIconLabelPositionTest` と同じ規則を見る。ラベルをピンの横や上に置くと
/// ビットマップはその側へだけ伸び、アンカー（ピン先端）が (0.5, 1) からずれる。
final class DefaultIconLabelPositionTests: XCTestCase {
    private let label = "信州大学"

    private func tip(_ icon: ColorDefaultIcon) -> (x: CGFloat, y: CGFloat, size: CGSize) {
        let bitmap = icon.toBitmapIcon()
        return (bitmap.anchor.x * bitmap.size.width, bitmap.anchor.y * bitmap.size.height, bitmap.size)
    }

    func testParseLabelPosition() {
        XCTAssertTrue(DefaultIconLayout.parseLabelPosition(ColorDefaultIcon.defaultLabelPosition) == (0, 0))
        XCTAssertTrue(DefaultIconLayout.parseLabelPosition("right center") == (1, 0))
        XCTAssertTrue(DefaultIconLayout.parseLabelPosition("top right") == (1, -1))
        XCTAssertTrue(DefaultIconLayout.parseLabelPosition("bottom") == (0, 1))
        XCTAssertTrue(DefaultIconLayout.parseLabelPosition(" LEFT  middle ") == (-1, 0))
    }

    func testDefaultKeepsCenteredLayout() {
        let icon = ColorDefaultIcon(label: label)
        XCTAssertEqual(icon.anchor, CGPoint(x: 0.5, y: 1.0))
        XCTAssertEqual(icon.toBitmapIcon().size.height, icon.iconSize)
        XCTAssertEqual(icon.infoAnchor, ColorDefaultIcon.defaultInfoAnchor)
    }

    func testRightCenterGrowsOnlyToTheRight() {
        let icon = ColorDefaultIcon(label: label, labelPosition: "right center")
        let t = tip(icon)
        XCTAssertEqual(t.size.height, icon.iconSize)
        XCTAssertEqual(t.x, icon.iconSize / 2.0, accuracy: 0.001)
        XCTAssertEqual(t.y, t.size.height, accuracy: 0.001)
        XCTAssertLessThan(t.x, t.size.width / 2.0)
        XCTAssertEqual(icon.anchor, icon.toBitmapIcon().anchor)
    }

    func testLeftIsNearlyMirrorOfRight() {
        // ピン形は外接箱の中で 0.25 単位だけ右に寄っているので、1pt までの差は許す。
        let right = tip(ColorDefaultIcon(label: label, labelPosition: "right"))
        let left = tip(ColorDefaultIcon(label: label, labelPosition: "left"))
        XCTAssertEqual(left.size.width, right.size.width, accuracy: 1.0)
        XCTAssertEqual(left.x, left.size.width - right.x, accuracy: 1.0)
    }

    func testCenterTopGrowsUpwardsAndBubbleStaysOnPin() {
        let icon = ColorDefaultIcon(label: label, labelPosition: "center top")
        let t = tip(icon)
        XCTAssertGreaterThan(t.size.height, icon.iconSize)
        XCTAssertEqual(t.y, t.size.height, accuracy: 0.001)
        XCTAssertEqual(icon.infoAnchor.y * t.size.height, t.size.height - icon.iconSize, accuracy: 0.001)
    }

    func testCopyKeepsPositionAndRequestedInfoAnchor() {
        let icon = ColorDefaultIcon(label: label, labelPosition: "right center")
        let copied = icon.copy(fillColor: .green)
        XCTAssertEqual(copied.labelPosition, "right center")
        XCTAssertEqual(copied.infoAnchor, icon.infoAnchor)
        XCTAssertNotEqual(icon.hashCode(), ColorDefaultIcon(label: label).hashCode())
    }

    func testImageDefaultIconUsesSameLayout() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let color = ColorDefaultIcon(label: label, labelPosition: "left bottom").toBitmapIcon()
        let imaged = ImageDefaultIcon(backgroundImage: image, label: label, labelPosition: "left bottom").toBitmapIcon()
        XCTAssertEqual(imaged.size, color.size)
        XCTAssertEqual(imaged.anchor, color.anchor)
    }

    func testHitTestCoversLabelBesideThePin() {
        // ラベルを右に置いたとき、ラベルの上をタップしても当たる（正方形で判定すると外れる）。
        let icon = ColorDefaultIcon(label: label, labelPosition: "right center")
        let state = MarkerState(position: GeoPoint(latitude: 0, longitude: 0), icon: icon)
        let bitmap = icon.toBitmapIcon()
        let labelX = bitmap.size.width * (1 - bitmap.anchor.x) - 4
        let markerScreen = CGPoint(x: 100, y: 100)
        let onLabel = CGPoint(x: markerScreen.x + labelX, y: markerScreen.y - icon.iconSize * 0.65)
        XCTAssertTrue(MarkerHitTest.hitsIcon(touchScreen: onLabel, markerScreen: markerScreen, state: state))
        // 左側（ラベルの無い側）はピンの外へ大きく広がらない。
        let farLeft = CGPoint(x: markerScreen.x - icon.iconSize - Settings.Default.tapTolerance - 1, y: markerScreen.y - 10)
        XCTAssertFalse(MarkerHitTest.hitsIcon(touchScreen: farLeft, markerScreen: markerScreen, state: state))
    }
}
