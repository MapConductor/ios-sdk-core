import Foundation

public protocol TileProvider: AnyObject {
    func renderTile(request: TileRequest) -> Data?

    /**
     Draws a tile, giving up if the map stops waiting for it.

     - Parameter isCancelled: asked repeatedly while the tile is drawn. A map
       that has panned away is not owed this tile, and drawing it anyway is not
       free: renderers share a fixed number of slots, so a doomed tile is drawn
       *instead of* one still on screen.

     Returning nil because the tile was abandoned is **not** the same as having
     no tile. The server must not answer a cancelled request with 404: a map
     that believes a tile is missing stops asking for it and leaves whatever
     older zoom it still has on screen — which is what a patchwork of two zoom
     levels in one view looks like.
     */
    func renderTile(request: TileRequest, isCancelled: () -> Bool) -> Data?
}

public extension TileProvider {
    /// Providers that draw fast enough not to care can ignore cancellation;
    /// this is what keeps them source-compatible.
    func renderTile(request: TileRequest, isCancelled: () -> Bool) -> Data? {
        renderTile(request: request)
    }
}
