import Foundation

public protocol MapPaddingsProtocol {
    var top: Double { get }
    var left: Double { get }
    var bottom: Double { get }
    var right: Double { get }
}

/// 地図の端に空ける量（pt）。
///
/// 4 辺はそれぞれ省略できる。省略した辺は読むと 0 だが、
/// ``MapViewState/moveCameraTo(cameraPosition:durationMillis:)`` に渡したときは
/// 状態が今持っているカメラの `paddings` の同じ辺を引き継ぐ
/// （``MapCameraPosition/resolved(onto:)``）。`MapPaddings(top: 300)` は
/// 「上だけ 300 にして、ほかの辺は今のまま」という意味になる。
/// 明示された 0 は引き継がずにそのまま使う。指定されたかどうかは
/// ``isTopSpecified`` などで区別する。
open class MapPaddings: MapPaddingsProtocol {
    /// 指定されなかったときは 0。指定されたかどうかは ``isTopSpecified`` で区別する。
    public let top: Double
    /// 指定されなかったときは 0。指定されたかどうかは ``isLeftSpecified`` で区別する。
    public let left: Double
    /// 指定されなかったときは 0。指定されたかどうかは ``isBottomSpecified`` で区別する。
    public let bottom: Double
    /// 指定されなかったときは 0。指定されたかどうかは ``isRightSpecified`` で区別する。
    public let right: Double

    public let isTopSpecified: Bool
    public let isLeftSpecified: Bool
    public let isBottomSpecified: Bool
    public let isRightSpecified: Bool

    /// 4 辺すべてが明示されているか。
    public var isFullySpecified: Bool {
        isTopSpecified && isLeftSpecified && isBottomSpecified && isRightSpecified
    }

    public init(
        top: Double? = nil,
        left: Double? = nil,
        bottom: Double? = nil,
        right: Double? = nil
    ) {
        self.top = top ?? 0.0
        self.left = left ?? 0.0
        self.bottom = bottom ?? 0.0
        self.right = right ?? 0.0
        self.isTopSpecified = top != nil
        self.isLeftSpecified = left != nil
        self.isBottomSpecified = bottom != nil
        self.isRightSpecified = right != nil
    }

    public static let Zeros = MapPaddings(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)

    /// `MapPaddings` はそのまま返す（指定の有無も保たれる）。それ以外の
    /// ``MapPaddingsProtocol`` は 4 辺とも指定されたものとして写す。
    public static func from(paddings: MapPaddingsProtocol) -> MapPaddings {
        if let impl = paddings as? MapPaddings {
            return impl
        }
        return MapPaddings(
            top: paddings.top,
            left: paddings.left,
            bottom: paddings.bottom,
            right: paddings.right
        )
    }

    /// 省略された辺を `current` の同じ辺で埋める。`current` が nil なら 0。
    ///
    /// 4 辺とも指定済みなら自分自身を返す。
    public func resolved(onto current: MapPaddingsProtocol?) -> MapPaddings {
        if isFullySpecified { return self }
        return MapPaddings(
            top: isTopSpecified ? top : (current?.top ?? 0.0),
            left: isLeftSpecified ? left : (current?.left ?? 0.0),
            bottom: isBottomSpecified ? bottom : (current?.bottom ?? 0.0),
            right: isRightSpecified ? right : (current?.right ?? 0.0)
        )
    }

    public func hashCode() -> Int {
        var result = top.hashValue
        result = 31 * result + left.hashValue
        result = 31 * result + bottom.hashValue
        result = 31 * result + right.hashValue
        return result
    }
}
