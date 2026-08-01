import Foundation

/// 閉じたリング（開いた頂点列として渡す）を ±180 子午線で分割する。
///
/// `splitByMeridian` は開いたパス用で、末尾→先頭のラップセグメントを見ないため、
/// 子午線を偶数回跨ぐリングでは「最初の断片」と「最後の断片」が本来ひとつながりの
/// ピースなのに別々に閉じられ、隙間（くさび）が生じる。ここでは最初の交差の直後から
/// 始まるようにリングを回転させ、ラップセグメントも含めて分割したうえで、先頭と末尾の
/// 断片を結合して正しいピース分割を返す。
///
/// 交差が無ければ入力リングをそのまま 1 断片として返す。
/// android-sdk の `splitRingByMeridian` と同一仕様。
public func splitRingByMeridian(
    _ ring: [GeoPointProtocol],
    geodesic: Bool
) -> [[GeoPointProtocol]] {
    if ring.count < 3 {
        return ring.isEmpty ? [] : [ring]
    }

    func crossesAt(_ i: Int) -> Bool {
        let a = ring[i]
        let b = ring[(i + 1) % ring.count]
        return abs(b.longitude - a.longitude) > 180.0
    }

    guard let firstCrossing = ring.indices.first(where: crossesAt) else { return [ring] }

    // 最初の交差セグメント p[k] -> p[k+1] の直後（p[k+1]）から始まるよう回転し、
    // 末尾に先頭点を足してラップセグメント（p[k] -> p[k+1]）も処理対象にする。
    let rotated = Array(ring[(firstCrossing + 1)...]) + Array(ring[...firstCrossing])
    let fragments = splitByMeridian(rotated + [rotated[0]], geodesic: geodesic)
    guard fragments.count >= 2 else { return fragments }

    // 末尾断片はラップ交差で始まった「先頭断片の続き」（同じ点から始まる）なので結合する。
    let merged = fragments[fragments.count - 1] + Array(fragments[0].dropFirst())
    return [merged] + Array(fragments[1 ..< (fragments.count - 1)])
}
