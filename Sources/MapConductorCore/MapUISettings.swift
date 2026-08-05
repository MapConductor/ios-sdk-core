import Foundation

/// Which map gestures the user is allowed to perform.
///
/// Mirrors `MapUISettings` on Android and React. Every flag defaults to `true`,
/// so the default value leaves the provider's own behaviour untouched.
///
/// Not every provider can honour every flag — some map SDKs bundle two gestures
/// into one recogniser, and a few of the web engines fake rotation and tilt
/// entirely. Setting an unsupported flag to `false` is ignored and logs a
/// one-time warning; see `MapGesture` and `MapUISettingsDiagnostics`.
public struct MapUISettings: Equatable {
    /// Pan / drag the map.
    public var scrollGesture: Bool
    /// Pinch, double-tap and scroll-wheel zoom.
    public var zoomGesture: Bool
    /// Rotate the map (change bearing).
    public var rotateGesture: Bool
    /// Tilt the map (change pitch).
    public var tiltGesture: Bool

    public init(
        scrollGesture: Bool = true,
        zoomGesture: Bool = true,
        rotateGesture: Bool = true,
        tiltGesture: Bool = true
    ) {
        self.scrollGesture = scrollGesture
        self.zoomGesture = zoomGesture
        self.rotateGesture = rotateGesture
        self.tiltGesture = tiltGesture
    }

    /// All gestures enabled — the default.
    public static let Default = MapUISettings()

    /// Every gesture disabled; the map becomes non-interactive.
    public static let None = MapUISettings(
        scrollGesture: false,
        zoomGesture: false,
        rotateGesture: false,
        tiltGesture: false
    )
}

/// The gestures `MapUISettings` can turn on and off.
public enum MapGesture: String, CaseIterable, Sendable {
    case scroll
    case zoom
    case rotate
    case tilt

    /// The `MapUISettings` property this gesture corresponds to.
    public var settingName: String { "\(rawValue)Gesture" }
}

/// Reports gesture flags a provider cannot honour.
///
/// Providers call `warnIfRequested` when a flag is set to `false` that their map
/// engine has no way to disable. Warnings are printed once per provider+gesture
/// so a SwiftUI view that re-renders on every camera move does not flood the
/// console.
public enum MapUISettingsDiagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var warned: Set<String> = []

    /// Logs once if `requested` is `false` — i.e. the app asked to disable a
    /// gesture this provider cannot disable. A `true` value needs no warning,
    /// because leaving a gesture enabled is always achievable.
    public static func warnIfRequested(
        _ requested: Bool,
        gesture: MapGesture,
        provider: String,
        reason: String
    ) {
        guard !requested else { return }
        let key = "\(provider).\(gesture.rawValue)"
        lock.lock()
        let isNew = warned.insert(key).inserted
        lock.unlock()
        guard isNew else { return }
        print("MapConductor: \(gesture.settingName) is not supported by \(provider) (\(reason)); the setting is ignored.")
    }

    /// Test hook — forget which warnings have already been printed.
    public static func resetWarnings() {
        lock.lock()
        warned.removeAll()
        lock.unlock()
    }
}
