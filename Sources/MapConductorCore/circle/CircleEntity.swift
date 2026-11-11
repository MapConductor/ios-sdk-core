public protocol CircleEntityProtocol {
    associatedtype ActualCircle
    var circle: ActualCircle? { get set }
    var state: CircleState { get }
    var fingerPrint: CircleFingerPrint { get }
}

public final class CircleEntity<ActualCircle>: CircleEntityProtocol {
    public var circle: ActualCircle?
    public let state: CircleState
    public let fingerPrint: CircleFingerPrint
    private let appliedRevision: UInt64

    func changeMask(_ next: CircleState) -> UInt16 {
        if next === state {
            return next.revision == appliedRevision ? 0 : next.changedFields & 0x1ff
        }
        let current = next.fingerPrint(), previous = fingerPrint
        var mask: UInt16 = 0
        if current.center != previous.center { mask |= 1 }
        if current.radiusMeters != previous.radiusMeters { mask |= 2 }
        if current.geodesic != previous.geodesic { mask |= 4 }
        if current.clickable != previous.clickable { mask |= 8 }
        if current.strokeColor != previous.strokeColor { mask |= 16 }
        if current.strokeWidth != previous.strokeWidth { mask |= 32 }
        if current.fillColor != previous.fillColor { mask |= 64 }
        if current.extra != previous.extra { mask |= 128 }
        if current.zIndex != previous.zIndex { mask |= 256 }
        return mask
    }

    /// What a tap needs, read once here so a tap need not read every state.
    let hit: CircleHitValues

    public init(circle: ActualCircle?, state: CircleState) {
        self.circle = circle
        self.state = state
        self.fingerPrint = state.fingerPrint()
        self.appliedRevision = state.revision
        self.hit = CircleHitValues(state)
    }
}

/// A circle's centre, radius, outline width, effective zIndex and clickability, as plain values.
struct CircleHitValues {
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    /// On screen, in points.
    let strokeWidth: Double
    /// ``CircleTileSet/effectiveZIndex(_:)``.
    let zIndex: Int
    let clickable: Bool

    init(_ state: CircleState) {
        let center = state.center
        latitude = center.latitude
        longitude = center.longitude
        radiusMeters = state.radiusMeters
        strokeWidth = state.strokeWidth
        zIndex = state.zIndex ?? CircleTileSet.automaticZIndex(center)
        clickable = state.clickable
    }
}
