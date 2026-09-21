import Foundation

public protocol TileProvider: AnyObject {
    /**
     Draws a tile, or returns nil when there is nothing to draw there.

     Nil is **"this spot is empty"**, and the server answers it with a
     transparent tile — not a 404 and not a 503. A marker tile is empty only
     *now*: data is still loading, a layer is mid-switch. Answering that with
     "no tile" makes a map SDK remember a hole it never asks about again, and
     the neighbouring tiles' overhang is cut off at its edge.

     A render that cannot be completed right now should **throw** instead; the
     server turns that into a 503 the map knows to retry.
     */
    func renderTile(request: TileRequest) -> Data?

    /**
     Draws a tile, giving up if the map stops waiting for it.

     - Parameter isCancelled: asked repeatedly while the tile is drawn. A map
       that has panned away is not owed this tile, and drawing it anyway is not
       free: renderers share a fixed number of slots, so a doomed tile is drawn
       *instead of* one still on screen.

     Returning nil because the tile was abandoned is **not** the same as having
     no tile. The server must not answer a cancelled request at all: a map that
     believes a tile is missing stops asking for it and leaves whatever older
     zoom it still has on screen — which is what a patchwork of two zoom levels
     in one view looks like.

     Throwing means "not right now". A provider that never fails can stay
     non-throwing: Swift lets a non-throwing method satisfy a throwing
     requirement, so nothing already written needs to change.
     */
    func renderTile(request: TileRequest, isCancelled: () -> Bool) throws -> Data?
}

public extension TileProvider {
    /// Providers that draw fast enough not to care can ignore cancellation;
    /// this is what keeps them source-compatible.
    func renderTile(request: TileRequest, isCancelled: () -> Bool) throws -> Data? {
        renderTile(request: request)
    }
}
