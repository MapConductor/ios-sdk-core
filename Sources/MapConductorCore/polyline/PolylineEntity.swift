import Foundation


public protocol PolylineEntityProtocol {
    associatedtype ActualPolyline
    var polyline: ActualPolyline? { get set }
    var state: PolylineState { get }
    var fingerPrint: PolylineFingerPrint { get }
}

public final class PolylineEntity<ActualPolyline>: PolylineEntityProtocol {
    public var polyline: ActualPolyline?
    public let state: PolylineState
    public let fingerPrint: PolylineFingerPrint

    /// Where a tap can possibly hit the line and how wide it is, read once here
    /// so a tap need not read every state.
    let hitBounds: PolylineHitBounds

    public init(
        polyline: ActualPolyline?,
        state: PolylineState
    ) {
        self.polyline = polyline
        self.state = state
        self.fingerPrint = state.fingerPrint()
        self.hitBounds = PolylineHitBounds(state)
    }
}

/// A polyline's vertex box and stroke width, for skipping lines a tap cannot hit.
struct PolylineHitBounds {
    let minLat: Double
    let maxLat: Double
    /// Nil when the longitudes cannot be compared directly (a geodesic or very wide line);
    /// such a line is always tested.
    let lng: (min: Double, max: Double)?
    /// On screen, in points.
    let strokeWidth: Double

    init(_ state: PolylineState) {
        strokeWidth = state.strokeWidth
        let points = state.points
        guard !state.geodesic, !points.isEmpty else {
            // A geodesic segment bulges past its vertices' latitudes.
            minLat = -.infinity
            maxLat = .infinity
            lng = nil
            return
        }
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLng = Double.infinity, maxLng = -Double.infinity
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLng = min(minLng, p.longitude); maxLng = max(maxLng, p.longitude)
        }
        self.minLat = minLat
        self.maxLat = maxLat
        self.lng = maxLng - minLng < 180 ? (minLng, maxLng) : nil
    }

    /// False only when the point is certainly farther than `meters` from every vertex box.
    func mayContain(latitude: Double, longitude: Double, meters: Double) -> Bool {
        guard let lng else { return true }
        // A degree of latitude is at least 110.5 km; pad a little more for rounding.
        let latPad = meters / 110_000 + 1e-9
        if latitude < minLat - latPad || latitude > maxLat + latPad { return false }
        let cosLat = cos(min(89.9, max(abs(minLat), abs(maxLat)) + latPad) * .pi / 180)
        let lngPad = latPad / max(cosLat, 1e-6)
        let lo = lng.min - lngPad, hi = lng.max + lngPad
        if longitude >= lo && longitude <= hi { return true }
        if longitude - 360 >= lo && longitude - 360 <= hi { return true }
        return longitude + 360 >= lo && longitude + 360 <= hi
    }
}
