import Foundation

public enum TileServerRegistry {
    private static let lock = NSLock()
    private static var server: LocalTileServer?
    private static var forceNoStoreCache: Bool = false

    public static func get() -> LocalTileServer {
        get(forceNoStoreCache: false)
    }

    public static func get(forceNoStoreCache: Bool) -> LocalTileServer {
        lock.lock()
        defer { lock.unlock() }

        self.forceNoStoreCache = forceNoStoreCache

        if let server {
            server.setForceNoStoreCache(forceNoStoreCache)
            return server
        }

        let newServer = LocalTileServer.startServer(forceNoStoreCache: forceNoStoreCache)
        server = newServer
        return newServer
    }

    public static func setForceNoStoreCache(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        forceNoStoreCache = value
        server?.setForceNoStoreCache(value)
    }
}
