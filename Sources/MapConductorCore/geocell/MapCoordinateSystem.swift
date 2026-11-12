import Foundation

/// 地図エンジンが地図を並べている座標系。**画面座標ではない。**
///
/// ``MapViewHolderProtocol/toProjectedPoint(_:)`` が返す点がどの座標系の値かを示す。
///
/// - `code` は `"EPSG:3857"` のような識別子。エンジンが独自に定義した投影で、
///   EPSG などの番号を持たないときは nil。
/// - `unit` は x / y の単位。
///
/// Mercator しか持たないエンジンと、地球儀表示中のエンジンは ``webMercator``
/// （EPSG:3857 メートル）になる。
public struct MapCoordinateSystem: Equatable, Hashable, Sendable {
    public let code: String?
    public let unit: ProjectedUnit

    public init(code: String?, unit: ProjectedUnit) {
        self.code = code
        self.unit = unit
    }

    /// EPSG:3857。x / y はメートル。
    public static let webMercator = MapCoordinateSystem(code: "EPSG:3857", unit: .meters)

    /// EPSG:4326。x が経度、y が緯度で、単位は度。
    public static let wgs84 = MapCoordinateSystem(code: "EPSG:4326", unit: .degrees)
}

/// 投影座標の x / y の単位。
public enum ProjectedUnit: String, Sendable {
    case meters
    case degrees
    /// フィートなど上の 2 つ以外、またはエンジン独自の単位。
    case other
}
