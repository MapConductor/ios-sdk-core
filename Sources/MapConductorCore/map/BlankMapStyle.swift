import Foundation

/// A MapLibre-style map with nothing in it but a background.
///
/// What a provider shows for "no basemap" when it is built on MapLibre or takes
/// a MapLibre style URL (Mapbox, MapTiler, TomTom). A map that draws its whole
/// viewport itself -- vector tiles rendered on the device, say -- fetches and
/// paints the basemap under it for nobody; this is the style that fetches
/// nothing. android-sdk-core and js-sdk-core carry the same style.
public enum BlankMapStyle {
    /// The one colour the style has.
    public static let backgroundColor = "#f2efe9"

    public static let json = """
    {"version":8,"name":"blank","sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#f2efe9"}}]}
    """

    /// The style as a file, for SDKs that only take a URL.
    ///
    /// Written once into Caches; the vendor SDKs read `file:` URLs but none
    /// of them read `data:` ones, and a Swift package cannot rely on a bundled
    /// resource reaching every distribution (CocoaPods source pods, prebuilt
    /// frameworks).
    public static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("mapconductor-blank-style.json")
        if (try? Data(contentsOf: url)) != json.data(using: .utf8) {
            try? json.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        return url
    }()
}
