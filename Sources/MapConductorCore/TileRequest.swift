public struct TileRequest: Hashable {
    public let x: Int
    public let y: Int
    public let z: Int
    public let pixelRatio: Int

    public init(x: Int, y: Int, z: Int, pixelRatio: Int = 1) {
        self.x = x
        self.y = y
        self.z = z
        self.pixelRatio = pixelRatio
    }
}
