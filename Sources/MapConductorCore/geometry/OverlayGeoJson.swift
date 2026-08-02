import Foundation

/// WebView 系ドライバー（MapTiler／Longdo 等）向けの GeoJSON Feature 文字列ビルダー。
///
/// 座標は経度・緯度の順。properties は常に空オブジェクトで、数値座標のみを扱うため
/// エスケープは不要。出力形式は android-sdk / react-sdk の実装と互換。
public enum OverlayGeoJson {
    /// MultiLineString の Feature を生成する。セグメントが空なら nil。
    public static func multiLineStringFeature(_ segments: [[GeoPointProtocol]]) -> String? {
        if segments.isEmpty { return nil }
        let coordinates = segments.map { segment in
            "[" + segment.map { "[\($0.longitude),\($0.latitude)]" }.joined(separator: ",") + "]"
        }.joined(separator: ",")
        return "{\"type\":\"Feature\",\"geometry\":"
            + "{\"type\":\"MultiLineString\",\"coordinates\":[\(coordinates)]},\"properties\":{}}"
    }

    /// Polygon（外周 1 つ＋穴）または MultiPolygon（外周複数、穴なし）の Feature を生成する。
    /// 各リングは自動的に閉じる。外周が空なら nil。
    public static func polygonFeature(_ rings: PolygonRings) -> String? {
        let outerRings = rings.outerRings
        if outerRings.isEmpty { return nil }
        if outerRings.count == 1 {
            var ringJsons = [ringToJson(outerRings[0])]
            for hole in rings.holeRings { ringJsons.append(ringToJson(hole)) }
            let coordinates = "[" + ringJsons.joined(separator: ",") + "]"
            return "{\"type\":\"Feature\",\"geometry\":"
                + "{\"type\":\"Polygon\",\"coordinates\":\(coordinates)},\"properties\":{}}"
        }
        let polygons = outerRings.map { "[\(ringToJson($0))]" }.joined(separator: ",")
        return "{\"type\":\"Feature\",\"geometry\":"
            + "{\"type\":\"MultiPolygon\",\"coordinates\":[\(polygons)]},\"properties\":{}}"
    }

    /// 穴のないリング列（円の分割結果等）を Polygon／MultiPolygon の Feature へ変換する。
    public static func ringsFeature(_ rings: [[GeoPointProtocol]]) -> String? {
        polygonFeature(PolygonRings(outerRings: rings, holeRings: []))
    }

    private static func ringToJson(_ ring: [GeoPointProtocol]) -> String {
        "[" + closeRing(ring).map { "[\($0.longitude),\($0.latitude)]" }.joined(separator: ",") + "]"
    }
}
