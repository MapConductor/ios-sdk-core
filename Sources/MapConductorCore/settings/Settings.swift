import CoreGraphics
import Foundation

/// Marker icon sizes shared by the bundled icon renderers.
///
/// Mirrors `com.mapconductor.settings.MarkerIconSize` (Android) and
/// `MarkerIconSize` in `@mapconductor/js-sdk-core` (React).
public enum MarkerIconSize {
    public static let Small: CGFloat = 32.0
    public static let Regular: CGFloat = 48.0
    public static let Large: CGFloat = 60.0
}

/// SDK-wide tuning constants.
///
/// Mirrors `com.mapconductor.settings.Settings` (Android) and `Settings` in
/// `@mapconductor/js-sdk-core` (React); member names and values are kept in sync
/// across the three platforms so that behaviour is portable.
///
/// Lengths are expressed in points on iOS, where Android uses `dp` and React uses
/// CSS pixels. Durations are in milliseconds on all three platforms.
public struct Settings {
    /// Slop added around an element's bounds when hit-testing a tap.
    public let tapTolerance: CGFloat
    /// Duration of `MarkerAnimation.drop`, in milliseconds.
    public let markerDropAnimateDuration: Int
    /// Duration of `MarkerAnimation.bounce`, in milliseconds.
    public let markerBounceAnimateDuration: Int
    /// Default width/height of a bundled marker icon.
    public let iconSize: CGFloat
    /// Default outline width of a bundled marker icon.
    public let iconStroke: CGFloat
    /// Window used to coalesce bursts of state-change events before re-rendering,
    /// in milliseconds.
    public let composeEventDebounce: Int

    public init(
        tapTolerance: CGFloat,
        markerDropAnimateDuration: Int,
        markerBounceAnimateDuration: Int,
        iconSize: CGFloat,
        iconStroke: CGFloat,
        composeEventDebounce: Int
    ) {
        self.tapTolerance = tapTolerance
        self.markerDropAnimateDuration = markerDropAnimateDuration
        self.markerBounceAnimateDuration = markerBounceAnimateDuration
        self.iconSize = iconSize
        self.iconStroke = iconStroke
        self.composeEventDebounce = composeEventDebounce
    }

    public static let Default = Settings(
        tapTolerance: 14.0,
        markerDropAnimateDuration: 300,
        markerBounceAnimateDuration: 2000,
        iconSize: MarkerIconSize.Regular,
        iconStroke: 1.0,
        composeEventDebounce: 5
    )
}

extension Settings {
    /// `markerDropAnimateDuration` as a `TimeInterval`, for the UIKit/Core Animation
    /// APIs the renderers drive.
    public var markerDropAnimateInterval: TimeInterval {
        TimeInterval(markerDropAnimateDuration) / 1000.0
    }

    /// `markerBounceAnimateDuration` as a `TimeInterval`.
    public var markerBounceAnimateInterval: TimeInterval {
        TimeInterval(markerBounceAnimateDuration) / 1000.0
    }
}
