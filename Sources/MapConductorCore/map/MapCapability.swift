import Foundation

/// プロバイダが対応できる機能の識別子。
///
/// 型付きの ``MapServiceKey`` が「どう実装するか」を運ぶのに対し、こちらは
/// 「対応しているか」だけを表す安定した ID。アプリ開発者に型キーを触らせずに
/// 対応状況を問い合わせられるようにするために分けてある。
///
/// 値を持つ capability（例: 穴を何個描けるか）は型付きキーで別途登録すること。
/// ここは真偽ではなく ``MapCapabilityStatus`` の 4 段階で表現する。
///
/// android-sdk / react-sdk にも同名・同じ `id` で置く。`id` は永続化やログに出るため、
/// case の名前を変えても `id` は変えないこと。
public enum MapCapability: String, CaseIterable, Sendable {
    // オーバーレイ
    case marker
    case polyline
    case polygon
    case circle
    case groundImage
    case rasterLayer

    /// 穴付きポリゴンを描けるか。何個描けるかは別途 ``MapServiceKey`` で値を登録する。
    case polygonHoles

    /// オーバーレイをタップに対して透過させられるか。
    ///
    /// MapConductor は原則としてクリックを地図クリックで受け、コアがヒットテストして
    /// 配送する。そのためにはネイティブのオーバーレイがタップを消費しないよう
    /// 「透過」に設定できる必要がある。できない SDK ではネイティブのクリック
    /// リスナーを使わざるを得ない。
    ///
    /// この capability が ``MapCapabilityStatus/unsupported(_:)`` のプロバイダは、
    /// ネイティブのクリックリスナー経由でイベントを受ける。判定自体はコアが行うので、
    /// アプリから見た挙動は揃う。
    case clickPassthrough

    // 操作
    case markerDrag

    // カメラ
    case cameraTilt
    case cameraRotate
    case cameraRestriction

    /// 緯度経度と画面座標を **同期的に** 相互変換できるか。
    ///
    /// InfoBubble・マーカーアニメーション・タイル方式マーカーのヒットテストが
    /// これを要求する。WebView ブリッジ経由のプロバイダ（ios-for-longdo）は
    /// 同期 API を持たないため対応できない。
    case screenProjectionSync

    // ジェスチャ（``MapGesture`` と 1 対 1）
    case gestureScroll
    case gestureZoom
    case gestureRotate
    case gestureTilt

    /// 永続化やログに出る安定した ID。
    public var id: String { rawValue }

    public static func fromId(_ id: String) -> MapCapability? { MapCapability(rawValue: id) }
}

public extension MapGesture {
    /// この ``MapGesture`` に対応する ``MapCapability``。
    var capability: MapCapability {
        switch self {
        case .scroll: return .gestureScroll
        case .zoom: return .gestureZoom
        case .rotate: return .gestureRotate
        case .tilt: return .gestureTilt
        }
    }
}

/// ある ``MapCapability`` にプロバイダがどこまで応えられるか。
///
/// 「未宣言（``unknown``）」と「恒久的に非対応（``unsupported(_:)``）」を区別できることが重要。
/// 区別が無いと、地図の初期化が終わっていないだけの状態と、その SDK では原理的に
/// できないことが同じに見えてしまう。
public enum MapCapabilityStatus: Equatable, Sendable {
    /// 期待どおりに動く。
    case supported

    /// 動くが結果が別物になる。例: HERE の穴付きポリゴンは塗りが和集合になる。
    case degraded(String)

    /// 動くが数値が近似。例: 円を多角形で近似する、ズーム換算に較正誤差がある。
    case approximated(String)

    /// この SDK では実現できない。
    case unsupported(String)

    /// まだ宣言されていない。初期化途中か、プロバイダが宣言を書いていないかのどちらか。
    ///
    /// **``unsupported(_:)`` と同じに扱わないこと。** 非対応と断定してよいのは
    /// `unsupported` のときだけ。
    case unknown

    /// 理由。``supported`` と ``unknown`` は nil。
    public var reason: String? {
        switch self {
        case .supported, .unknown: return nil
        case let .degraded(reason), let .approximated(reason), let .unsupported(reason): return reason
        }
    }

    /// 完全に期待どおりか（``supported`` のみ true）。
    public var isFullySupported: Bool {
        if case .supported = self { return true }
        return false
    }

    /// 何らかの形で機能するか（``degraded(_:)`` / ``approximated(_:)`` を含む）。
    public var isUsable: Bool {
        switch self {
        case .supported, .degraded, .approximated: return true
        case .unsupported, .unknown: return false
        }
    }

    /// 宣言されていて、かつ使えないと分かっているか。
    public var isKnownUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}
