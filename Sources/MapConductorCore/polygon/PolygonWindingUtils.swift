import Foundation

/// Returns the signed area of a geographic ring using the shoelace formula (x=longitude, y=latitude).
/// Positive result = counterclockwise (CCW). Negative result = clockwise (CW).
/// Works correctly for both open rings and closed rings (where the first and last points are equal).
public func polygonSignedArea(_ ring: [GeoPointProtocol]) -> Double {
    let n = ring.count
    guard n >= 3 else { return 0.0 }
    var sum = 0.0
    for i in 0..<n {
        let a = ring[i]
        let b = ring[(i + 1) % n]
        sum += (a.longitude * b.latitude) - (b.longitude * a.latitude)
    }
    return sum / 2.0
}

/// Returns the ring with counterclockwise (CCW) winding, reversing if needed.
public func ensureCounterClockwise(_ ring: [GeoPointProtocol]) -> [GeoPointProtocol] {
    polygonSignedArea(ring) >= 0 ? ring : ring.reversed()
}

/// Returns the ring with clockwise (CW) winding, reversing if needed.
public func ensureClockwiseRing(_ ring: [GeoPointProtocol]) -> [GeoPointProtocol] {
    polygonSignedArea(ring) <= 0 ? ring : ring.reversed()
}
