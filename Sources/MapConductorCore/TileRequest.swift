public struct TileRequest: Hashable {
    public let x: Int
    public let y: Int
    public let z: Int
    public let pixelRatio: Int
    /// Render a coarser vector level within the same target grid.
    public let sourceZoomOffset: Int

    public init(x: Int, y: Int, z: Int, pixelRatio: Int = 1, sourceZoomOffset: Int = 0) {
        self.x = x
        self.y = y
        self.z = z
        self.pixelRatio = pixelRatio
        self.sourceZoomOffset = max(0, min(8, sourceZoomOffset))
    }
}
