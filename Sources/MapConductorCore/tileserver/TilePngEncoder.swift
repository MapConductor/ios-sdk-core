import CoreGraphics
import CTilePng
import Foundation
import UIKit

/**
 PNG encoding in Rust, for tiles the SDK rasterises itself.

 Lives in the core so an app carries one copy of the encoder rather than one per
 module that draws tiles. The tiles are ephemeral payloads for a local tile
 server, so it trades ratio for speed and produces files a few times larger —
 which never reach a network, though they do take proportionally more room in a
 tile cache.

 How much it wins depends entirely on the platform encoder it replaces. On an
 iPad Pro it is 2.3-2.6x faster than `pngData()`; on a Pixel 5a the same code is
 6-20x faster than `Bitmap.compress`, because Apple's encoder is good and
 Android's is not.

 Every failure path returns nil rather than throwing, so every caller is
 expected to have a platform fallback: a failed optimisation should cost a slow
 tile, never a broken one.
 */
public enum TilePngEncoder {

    private static let ok: Int32 = 0

    /// Scratch pixel buffer, one per calling thread.
    ///
    /// Tile rendering runs concurrently, and a tile is several megabytes of
    /// RGBA. Allocating that per call cost as much as the encoding itself:
    /// 7.9 ms per tile against 3.9 ms of actual work.
    private static let scratchKey = "com.mapconductor.tilepng.scratch"

    private static func scratch(_ byteCount: Int) -> NSMutableData {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[scratchKey] as? NSMutableData,
           existing.length >= byteCount {
            return existing
        }
        let fresh = NSMutableData(length: byteCount)!
        dictionary[scratchKey] = fresh
        return fresh
    }

    /// Encodes an image. Returns nil if the native path declined it, in which
    /// case use `UIImage.pngData()`.
    public static func encode(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let pixels = scratch(bytesPerRow * height)
        let base = pixels.mutableBytes

        // Drawn into a context we own rather than read out of the CGImage: a
        // CGImage's backing store may be any layout CoreGraphics chose, and
        // guessing at one is how a fast encoder produces wrong colours.
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // The buffer is reused, so anything the previous tile left behind has
        // to go — a partly transparent tile would otherwise show the last one
        // through its gaps.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return encode(rgba: base, width: width, height: height, premultiplied: true)
    }

    /**
     Encodes RGBA8 pixels in place.

     Set `premultiplied` when the colour channels are scaled by alpha — a
     CoreGraphics context's are, a Metal readback's usually are not. PNG stores
     straight alpha, so encoding premultiplied pixels unchanged darkens every
     partly transparent one. The buffer is un-premultiplied in place when this
     is set, so its contents are not reusable afterwards.

     - Parameter rgba: `width * height * 4` writable bytes, rows top-down.
     */
    public static func encode(
        rgba: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        premultiplied: Bool
    ) -> Data? {
        guard width > 0, height > 0 else { return nil }

        var outPointer: UnsafeMutablePointer<UInt8>?
        var outLength = 0
        let status = tile_png_encode(
            rgba.assumingMemoryBound(to: UInt8.self),
            UInt32(width),
            UInt32(height),
            premultiplied ? 1 : 0,
            &outPointer,
            &outLength
        )

        guard status == ok, let outPointer else { return nil }
        defer { tile_png_buffer_free(outPointer, outLength) }
        return Data(bytes: outPointer, count: outLength)
    }
}
