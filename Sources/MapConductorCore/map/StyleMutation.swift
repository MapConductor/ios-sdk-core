import Foundation

/**
 One change to one layer of a vector style the map has already loaded.

 This is what lets a style be adjusted without being reloaded. Handing a map
 a new style document is the obvious way to change how it looks, and on every
 provider it is the expensive way: the renderer drops its tiles, re-reads the
 document, re-tessellates, and the overlays the app added have to be put
 back. A paint property set in place costs none of that.

 Mutations are produced by the vector style compiler from the same evaluation
 that produces the adjusted document, so the two can never disagree about
 what the style should look like. A provider that can take them declares
 ``VectorStyleMutationSupport``.

 ## Why the values are JSON text

 A style property's value is anything the style spec allows: a string, a
 number, or an expression tree. Each provider needs it in its own form --
 MapLibre here wants an `NSExpression`, MapLibre on Android a Gson tree,
 MapLibre in a browser the plain parsed value -- so there is no shared typed
 representation that saves anyone a conversion. Text is the one form all
 three can start from, it is what crossed the FFI boundary anyway, and it is
 `Sendable`, which `Any` is not.

 `"null"` means the property had no value, which is also how a renderer is
 told to go back to the spec default.

 android-sdk-core and js-sdk-core carry the same type.
 */
public enum StyleMutation: Equatable, Sendable {
    case setPaint(layerId: String, key: String, value: String, previous: String)
    case setLayout(layerId: String, key: String, value: String, previous: String)
    case setFilter(layerId: String, value: String, previous: String)
    case setZoomRange(
        layerId: String,
        minZoom: Double?,
        maxZoom: Double?,
        previousMinZoom: Double?,
        previousMaxZoom: Double?
    )
    /**
     Adds a layer the style did not have.

     Used for one thing: a background under a style that has none, so that
     "everything else muted" looks the same whether the style is drawn by the
     map or rasterised into tiles over another basemap. Without it the raster
     path leaves the gaps transparent and the two disagree.
     */
    case addLayer(layerId: String, layer: String, beforeId: String?)
    case removeLayer(layerId: String)

    /// The layer this acts on. Every mutation names one.
    public var layerId: String {
        switch self {
        case let .setPaint(layerId, _, _, _),
             let .setLayout(layerId, _, _, _),
             let .setFilter(layerId, _, _),
             let .setZoomRange(layerId, _, _, _, _),
             let .removeLayer(layerId),
             let .addLayer(layerId, _, _):
            return layerId
        }
    }

    /**
     What this mutation occupies, for working out which of two sets of
     mutations replace each other. Two mutations with the same target are the
     same change with different values.
     */
    public var target: String {
        switch self {
        case let .setPaint(layerId, key, _, _): return "paint|\(layerId)|\(key)"
        case let .setLayout(layerId, key, _, _): return "layout|\(layerId)|\(key)"
        case let .setFilter(layerId, _, _): return "filter|\(layerId)"
        case let .setZoomRange(layerId, _, _, _, _): return "zoom|\(layerId)"
        case let .addLayer(layerId, _, _): return "add|\(layerId)"
        case let .removeLayer(layerId): return "add|\(layerId)"
        }
    }

    /**
     What this mutation changes, named the way the style spec names it.

     For telling an app *what* a renderer would not do. The layer is the
     wrong thing to name on its own: when a backend has no property for a
     spec key, the same key fails on every layer that uses it, so a list of
     layers is hundreds of names for one cause while the key is the cause.
     */
    public var propertyName: String {
        switch self {
        case let .setPaint(_, key, _, _), let .setLayout(_, key, _, _): return key
        case .setFilter: return "filter"
        case .setZoomRange: return "zoom range"
        case .addLayer, .removeLayer: return "layer"
        }
    }

    /// The mutation that puts back what was there, or nil when there is nothing to put back.
    public func reversed() -> StyleMutation? {
        switch self {
        case let .setPaint(layerId, key, value, previous):
            return .setPaint(layerId: layerId, key: key, value: previous, previous: value)
        case let .setLayout(layerId, key, value, previous):
            return .setLayout(layerId: layerId, key: key, value: previous, previous: value)
        case let .setFilter(layerId, value, previous):
            return .setFilter(layerId: layerId, value: previous, previous: value)
        case let .setZoomRange(layerId, minZoom, maxZoom, previousMin, previousMax):
            return .setZoomRange(
                layerId: layerId,
                minZoom: previousMin,
                maxZoom: previousMax,
                previousMinZoom: minZoom,
                previousMaxZoom: maxZoom
            )
        case let .addLayer(layerId, _, _):
            return .removeLayer(layerId: layerId)
        case .removeLayer:
            return nil
        }
    }

    /**
     Reads the compiler's `mutations` array.

     An entry this version does not know is skipped rather than fatal: the
     array is produced by the native library this host shipped with, so an
     unknown op means the two went out of step, and dropping one change is
     better than losing every change.
     */
    public static func parseList(_ json: String) -> [StyleMutation] {
        guard
            let data = json.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap(parse)
    }

    private static func parse(_ obj: [String: Any]) -> StyleMutation? {
        let layerId = obj["layerId"] as? String
        switch obj["op"] as? String {
        case "setPaint":
            guard let layerId, let key = obj["key"] as? String else { return nil }
            return .setPaint(
                layerId: layerId, key: key,
                value: jsonText(of: obj["value"]), previous: jsonText(of: obj["previous"])
            )
        case "setLayout":
            guard let layerId, let key = obj["key"] as? String else { return nil }
            return .setLayout(
                layerId: layerId, key: key,
                value: jsonText(of: obj["value"]), previous: jsonText(of: obj["previous"])
            )
        case "setFilter":
            guard let layerId else { return nil }
            return .setFilter(
                layerId: layerId,
                value: jsonText(of: obj["value"]), previous: jsonText(of: obj["previous"])
            )
        case "setZoomRange":
            guard let layerId else { return nil }
            return .setZoomRange(
                layerId: layerId,
                minZoom: obj["minZoom"] as? Double,
                maxZoom: obj["maxZoom"] as? Double,
                previousMinZoom: obj["previousMinZoom"] as? Double,
                previousMaxZoom: obj["previousMaxZoom"] as? Double
            )
        case "addLayer":
            guard let layerId, obj["layer"] is [String: Any] else { return nil }
            return .addLayer(
                layerId: layerId, layer: jsonText(of: obj["layer"]),
                beforeId: obj["beforeId"] as? String
            )
        case "removeLayer":
            return layerId.map { .removeLayer(layerId: $0) }
        default:
            return nil
        }
    }


    /**
     A JSON node as the text that would produce it.

     `JSONSerialization` refuses a bare string or number as a top-level
     value on older systems, so the simple cases are written directly rather
     than asking it.
     */
    public static func jsonText(of value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return "null"
        case let text as String:
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        case let flag as Bool where type(of: value!) == type(of: NSNumber(value: true)):
            return flag ? "true" : "false"
        case let number as NSNumber:
            // `true` and `false` arrive as NSNumber too; the case above
            // catches them by their boxed type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        default:
            guard
                let value,
                JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                let text = String(data: data, encoding: .utf8)
            else { return "null" }
            return text
        }
    }
}
