public protocol PolygonEntityProtocol {
    associatedtype ActualPolygon
    var polygon: ActualPolygon? { get set }
    var state: PolygonState { get }
    var fingerPrint: PolygonFingerPrint { get }
}

public final class PolygonEntity<ActualPolygon>: PolygonEntityProtocol {
    public var polygon: ActualPolygon?
    public let state: PolygonState
    public let fingerPrint: PolygonFingerPrint

    /// The outline's latitude range and, when it spans less than half the world,
    /// its longitude range; read once here so a tap need not read every state.
    let hitBounds: PolygonHitBounds

    public init(polygon: ActualPolygon?, state: PolygonState) {
        self.polygon = polygon
        self.state = state
        self.fingerPrint = state.fingerPrint()
        self.hitBounds = PolygonHitBounds(state)
    }
}

/// Where a tap can possibly hit a polygon, for skipping the rest cheaply.
struct PolygonHitBounds {
    let minLat: Double
    let maxLat: Double
    /// Nil when the longitudes cannot be compared directly (a geodesic or very wide polygon).
    let lng: (min: Double, max: Double)?

    init(_ state: PolygonState) {
        let points = state.points
        guard !state.geodesic, !points.isEmpty else {
            // A geodesic edge bulges past its vertices' latitudes; test it every time.
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

    /// False only when the point is certainly outside (with the hit test's own tolerance).
    func mayContain(latitude: Double, longitude: Double) -> Bool {
        let eps = 1e-6
        if latitude < minLat - eps || latitude > maxLat + eps { return false }
        guard let lng else { return true }
        for x in [longitude, longitude - 360, longitude + 360] where x >= lng.min - eps && x <= lng.max + eps {
            return true
        }
        return false
    }
}
