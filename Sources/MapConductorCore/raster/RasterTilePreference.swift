import Foundation

/// どの大きさのタイルなら、この地図 SDK がうまく扱えるか。
///
/// タイルの一辺は本来アプリの好みで決めてよく、既定は 512。1 枚あたりの固定費
/// （ローカルタイルサーバへの往復、PNG の符号化・復号、レンダラの立ち上げ）が
/// 枚数に比例するので、同じ画面を覆うなら枚数は少ないほうが安い。
///
/// ところが SDK 側に都合があることがあり、その都合はタイルを供給する側からは
/// 見えない。実例が ArcGIS の 3D SceneView で、**タイルは 256px** という前提で
/// レベルを選ぶ。512px のタイルを渡すと 1 段深いレベルを 4 倍の枚数で取りに行く
/// （Android 実機・統一ズーム 12 で、2D は z=11、3D は z=12）。絵は正しいので
/// 気づきにくく、遅い端末ほど効く。
///
/// android-sdk の `RasterTilePreference.kt`、react-sdk の
/// `RasterTilePreference.ts` と同じもの。
public protocol RasterTilePreference {
    /// この SDK に渡してほしいタイルの一辺（ポイント）。
    var preferredTileSize: Int { get }

    /// この SDK がラスタータイルを **物理ピクセル** でレイアウトするなら true。
    ///
    /// 地図 SDK には 2 つの流儀がある。宣言された一辺をポイントとして敷くものと、
    /// 物理ピクセルとして敷くもの。後者に 2x の画面で「512」と宣言すると
    /// 256 pt しか覆わず、1 段深いズームを要求してスタイルをそこで読む —
    /// ラベルは半分、道路は倍の密度になる（web の HERE で実測）。供給側は
    /// この流儀を知りようがないので、プロバイダが言う。
    ///
    /// true のとき、供給側は ``preferredTileSize`` × scale を宣言し、描画は
    /// 同じピクセル数で行い、スタイルには ``preferredTileSize`` pt として
    /// 読ませる。既定は false。android-sdk / react-sdk の同名フィールドに対応。
    var layoutInDevicePixels: Bool { get }
}

extension RasterTilePreference {
    public var layoutInDevicePixels: Bool { false }
}

/// ``RasterTilePreference`` の登録キー。
///
/// 宣言しないプロバイダは「好みは無い」。その場合は供給側の既定が使われる。
public enum RasterTilePreferenceKey: MapServiceKey {
    public typealias Value = RasterTilePreference
}

/// 値だけを持つ既定の実装。プロバイダが 1 行で登録できるように。
public struct FixedRasterTilePreference: RasterTilePreference {
    public let preferredTileSize: Int
    public let layoutInDevicePixels: Bool

    public init(preferredTileSize: Int, layoutInDevicePixels: Bool = false) {
        self.preferredTileSize = preferredTileSize
        self.layoutInDevicePixels = layoutInDevicePixels
    }
}
