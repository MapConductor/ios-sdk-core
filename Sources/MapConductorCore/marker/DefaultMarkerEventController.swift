import CoreGraphics
import Foundation

/// ドラッグ処理が地図ビューに要求する最小の面。
///
/// `MLNMapView` がそのまま満たす（MapLibre と MapTiler は同じ型）。
/// core が地図 SDK に依存しないよう、構造的に切り出してある。
///
/// @_spi なしの public にしてあるのは、プロバイダが自分のビューを適合させるため。
public protocol MarkerDragSurface: AnyObject {
    /// 地図のパン可否。ドラッグ中だけ切る。
    var isScrollEnabled: Bool { get set }

    /// 画面座標 → 地理座標。
    func geoPoint(atScreenPoint point: CGPoint) -> GeoPoint?
}

/// マーカーのイベント配送に必要な面。
///
/// android-sdk の `MarkerEventHostInterface`、react-sdk の `MarkerEventHost` に対応する。
/// ネイティブのマーカー型に触れずに、タップとドラッグの状態遷移だけを扱えるようにする。
public protocol MarkerEventHostProtocol: AnyObject {
    /// 画面座標にあるネイティブマーカーの id。無ければ nil。
    func markerId(atScreenPoint point: CGPoint) -> String?

    func markerState(for id: String) -> MarkerState?

    /// タイル方式で描かれたマーカーのタップ。ネイティブのシンボルが無いので別経路。
    func handleTiledMarkerTap(atScreenPoint point: CGPoint) -> Bool

    func dispatchClick(state: MarkerState)
    func dispatchDragStart(state: MarkerState)
    func dispatchDrag(state: MarkerState)
    func dispatchDragEnd(state: MarkerState)

    /// ドラッグでマーカーが動いたら吹き出しの位置も追従させる。
    func onUpdateInfoBubble(_ markerId: String)
}

/// マーカーのタップ配送とドラッグの状態遷移。
///
/// ## 何をするクラスか
///
/// ジェスチャ（ドライバー側）とマーカーコントローラ（コア側）の間に立って、
///  - タップの引き当てと配送（ネイティブシンボル → タイル方式の順）
///  - 長押しドラッグの開始・移動・終了の配送
///  - ドラッグ中のパン抑止と、**掴む前の値への復元**
/// を行う。**地図 SDK の型に一切触らない**ので、プロバイダごとに書く必要が無い。
///
/// ## 移行前
///
/// ios-for-maplibre / maptiler が 84 行ずつ持っており、**import 文以外は
/// 1 文字も違わなかった**（diff を取って確認済み）。
///
/// ## ios-for-here をここに寄せていない理由
///
/// HERE は `hitTest(at:where:)` で **「条件を満たすマーカーのうち一番近いもの」** を引く。
/// このクラスは「一番近いマーカーを引いてから clickable / draggable を見る」ので、
/// clickable なマーカーと draggable なマーカーが重なったときに選ぶものが変わる。
/// アプリから観測できる挙動差なので、HERE は自前の経路のままにしてある
/// （ios-for-tomtom のクリックカスケードを寄せなかったのと同じ判断）。
///
/// ## パン抑止は「掴む前の値へ戻す」こと
///
/// `isScrollEnabled` を無条件に `true` へ戻すと、アプリが
/// `uiSettings.scrollGesture = false` にしていた地図がドラッグ後に動くようになる。
/// 掴んだ時点の値を覚えて戻す。3 プラットフォーム共通の契約。
@MainActor
open class DefaultMarkerEventController {
    /// **強参照で持つこと。** ここは地図ビューそのものではなく、呼び出し側が
    /// `super.init` の引数として作る薄いアダプタで、他に持ち主がいない。
    /// weak にすると生成直後に解放され、`handleLongPress` が常に false を返す
    /// ——ドラッグだけが黙って死ぬ（タップは surface を使わないので気づけない）。
    /// アダプタ側が地図ビューを weak で持つので循環はしない。
    private var surface: (any MarkerDragSurface)?
    private let host: any MarkerEventHostProtocol

    private var draggingMarkerId: String?

    /// 掴む前の `isScrollEnabled`。ドラッグ終了時にこれへ戻す。
    private var scrollEnabledBeforeDrag: Bool?

    public init(surface: (any MarkerDragSurface)?, host: any MarkerEventHostProtocol) {
        self.surface = surface
        self.host = host
    }

    /// タップの引き当てと配送。当たったら true。
    ///
    /// ネイティブのシンボルマーカーを先に見て、無ければタイル方式のマーカーを
    /// 地理座標の近さで探す。
    open func handleTap(at point: CGPoint) -> Bool {
        if let markerId = host.markerId(atScreenPoint: point),
           let state = host.markerState(for: markerId),
           state.clickable {
            host.dispatchClick(state: state)
            return true
        }
        return host.handleTiledMarkerTap(atScreenPoint: point)
    }

    /// 長押しドラッグ。掴んでいる間は true を返し、ジェスチャを消費する。
    open func handleLongPress(state recognizerState: MarkerDragGestureState, at point: CGPoint) -> Bool {
        guard let surface else { return false }

        switch recognizerState {
        case .began:
            guard let markerId = host.markerId(atScreenPoint: point),
                  let state = host.markerState(for: markerId),
                  state.draggable else { return false }
            draggingMarkerId = markerId
            scrollEnabledBeforeDrag = surface.isScrollEnabled
            surface.isScrollEnabled = false
            host.dispatchDragStart(state: state)
            host.onUpdateInfoBubble(markerId)
            return true

        case .changed:
            guard let markerId = draggingMarkerId,
                  let state = host.markerState(for: markerId),
                  let position = surface.geoPoint(atScreenPoint: point) else { return false }
            state.position = position
            host.dispatchDrag(state: state)
            host.onUpdateInfoBubble(markerId)
            return true

        case .ended:
            guard let markerId = draggingMarkerId,
                  let state = host.markerState(for: markerId) else {
                restoreScroll()
                return false
            }
            // 離した点で位置を確定させてから dragEnd を配送する。
            // react-sdk の `finishDrag` と ios-for-here の `.end` が同じことをしており、
            // maplibre / maptiler だけが最後の .changed の位置のまま配送していた。
            if let position = surface.geoPoint(atScreenPoint: point) {
                state.position = position
            }
            host.dispatchDragEnd(state: state)
            restoreScroll()
            host.onUpdateInfoBubble(markerId)
            return true

        case .cancelled:
            let wasDragging = draggingMarkerId != nil
            restoreScroll()
            return wasDragging

        case .other:
            return draggingMarkerId != nil
        }
    }

    /// 地図の破棄時に呼ぶ。掴んだままになっていたパン抑止を戻す。
    open func unbind() {
        restoreScroll()
        surface = nil
    }

    private func restoreScroll() {
        surface?.isScrollEnabled = scrollEnabledBeforeDrag ?? true
        scrollEnabledBeforeDrag = nil
        draggingMarkerId = nil
    }
}

/// `UILongPressGestureRecognizer.State` のうち、ドラッグの状態遷移に必要な区別だけ。
///
/// UIKit の型をコアの契約に持ち込まないための写像。
public enum MarkerDragGestureState {
    case began
    case changed
    case ended
    case cancelled
    case other
}
