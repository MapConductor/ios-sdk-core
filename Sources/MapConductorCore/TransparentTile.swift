import Foundation

/// 透明なタイル 1 枚。辺の長さごとに 1 度だけ作って使い回す。
///
/// 「ここには何も無い」は本物の答えで、透明な絵で返すのが正しい。`nil` を
/// 「タイルが無い」として 404 や 503 にすると、地図 SDK はそれを覚える／
/// 引き直し続ける。前者は永久の穴になり、隣のタイルのはみ出し分だけが残るので
/// 穴の縁でアイコンが半分に切れて見える。
///
/// 置き場所が `LocalTileServer` の隣なのは、**空を絵にするのはサーバの仕事**だから。
/// 以前は `MarkerTileRenderer` が自分で透明タイルを返していて、同じことをする
/// geojson / kml / groundimage / vectortile は nil のまま 503 になっていた。
/// android-sdk-core の `TransparentTilePng` と対になっている。
/// A transparent PNG per pixel size, encoded once and kept.
///
/// What "nothing here" looks like to a map: the tile server answers an empty
/// spot with it, and a backend that asks for tiles nobody will see (ArcGIS's
/// 3D view loads every ancestor of the level on screen) is handed one instead
/// of a render.
public enum TransparentTile {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: Data] = [:]

    /// 一辺 `size` ピクセルの透明 PNG。作れなければ nil。
    public static func png(size: Int) -> Data? {
        let clamped = min(max(size, 1), maxSize)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[clamped] { return cached }
        var pixels = [UInt8](repeating: 0, count: clamped * clamped * 4)
        let png = pixels.withUnsafeMutableBytes { raw -> Data? in
            guard let base = raw.baseAddress else { return nil }
            return TilePngEncoder.encode(rgba: base, width: clamped, height: clamped, premultiplied: true)
        }
        if let png { cache[clamped] = png }
        return png
    }

    /// 4096px タイルまで。これを超える要求は壊れた URL なので、確保量が
    /// 二乗で効くこの経路では受けない。
    private static let maxSize = 4096
}
