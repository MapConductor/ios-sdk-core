import CoreGraphics

/// Returns the point on the 2D segment `startPoint`–`endPoint` that is closest
/// to `testPoint`. Operates in a planar (screen/world-pixel) coordinate space.
public func closestPointOnSegment(
    startPoint: CGPoint,
    endPoint: CGPoint,
    testPoint: CGPoint
) -> CGPoint {
    let segmentVectorX = endPoint.x - startPoint.x
    let segmentVectorY = endPoint.y - startPoint.y
    let pointVectorX = testPoint.x - startPoint.x
    let pointVectorY = testPoint.y - startPoint.y
    let segmentLengthSquared = segmentVectorX * segmentVectorX + segmentVectorY * segmentVectorY
    if segmentLengthSquared == 0 { return startPoint } // start and end are the same point

    // Projection ratio via dot product, clamped to the segment (0 ≤ ratio ≤ 1).
    let projectionRatio = max(0, min(1, (pointVectorX * segmentVectorX + pointVectorY * segmentVectorY) / segmentLengthSquared))

    return CGPoint(
        x: startPoint.x + projectionRatio * segmentVectorX,
        y: startPoint.y + projectionRatio * segmentVectorY
    )
}
