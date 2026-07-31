import Foundation

/// Web Mercator meters-per-pixel at a given latitude and zoom.
///
/// - Parameter tileSize: Match the Android/Web Mercator convention where zoom is
///   defined against a 256px tile.
public func calculateMetersPerPixel(
    latitude: Double,
    zoom: Double,
    tileSize: Double = 256.0
) -> Double {
    // At zoom level 0 the entire equatorial circumference fits in `tileSize` pixels.
    let metersPerPixelAtEquator = Earth.circumferenceMeters / tileSize
    // Each zoom level halves the meters per pixel.
    let metersPerPixelAtZoom = metersPerPixelAtEquator / pow(2.0, zoom)
    // Mercator projection stretches at higher latitudes.
    let latitudeAdjustment = cos(deg2rad(abs(latitude)))
    return metersPerPixelAtZoom * latitudeAdjustment
}

private func deg2rad(_ degrees: Double) -> Double { degrees * .pi / 180.0 }
