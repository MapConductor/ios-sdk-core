import Foundation

/// Creates a point at the opposite meridian (180° ↔ -180°) with the same
/// latitude and altitude.
///
/// - Parameter point: Point at one meridian.
/// - Returns: Point at the opposite meridian.
func createOppositeMeridianPoint(_ point: GeoPointProtocol) -> GeoPoint {
    let oppositeLongitude = point.longitude >= 0 ? -180.0 : 180.0
    return GeoPoint(
        latitude: point.latitude,
        longitude: oppositeLongitude,
        altitude: point.altitude ?? 0.0
    )
}
