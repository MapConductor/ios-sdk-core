import Foundation

/// Expands `bounds` outward by `margin` (a fraction of each axis span) on all
/// sides, returning a new bounds centered on the same point.
public func expandBounds(
    bounds: GeoRectBounds,
    margin: Double
) -> GeoRectBounds {
    if bounds.isEmpty { return bounds }

    guard let span = bounds.toSpan(), let center = bounds.center else { return bounds }

    let latMargin = span.latitude * margin / 2.0
    let lngMargin = span.longitude * margin / 2.0

    let expandedBounds = GeoRectBounds()
    expandedBounds.extend(
        point: GeoPoint(
            latitude: center.latitude - span.latitude / 2.0 - latMargin,
            longitude: center.longitude - span.longitude / 2.0 - lngMargin
        )
    )
    expandedBounds.extend(
        point: GeoPoint(
            latitude: center.latitude + span.latitude / 2.0 + latMargin,
            longitude: center.longitude + span.longitude / 2.0 + lngMargin
        )
    )

    return expandedBounds
}
