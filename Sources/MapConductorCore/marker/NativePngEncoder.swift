import CoreGraphics
import Foundation
import CTilePng
import UIKit

/**
 PNG encoding in Rust, for tiles the SDK rasterises itself.

 `UIImage.pngData()` is a large share of a marker tile once the drawing is
 aligned. This encoder trades ratio for speed — the tiles are ephemeral
 payloads for a local tile server, never a network — and produces files a few
 times larger in exchange.

 Every failure path returns nil so the caller falls back to `pngData()`. A
 bitmap in an unexpected layout, an allocation that fails, a panic in Rust: all
 of them mean a slower tile, never a broken one.
 */
enum NativePngEncoder {

    /// Status codes from the C ABI.
    ///
    /// Restated because Swift's importer keeps `TILE_PNG_OK`, which is a bare
    /// 0, but drops the error macros — their bodies start with a minus.
    /// Mirrors `tile_png.h`.
    private static let ok: Int32 = 0

    /// Scratch pixel buffer, one per rendering thread.
    ///
    /// `renderTile` runs concurrently across the tile server's threads, and a
    /// tile is several megabytes of RGBA — allocating that per call cost about
    /// as much as the encoding it is meant to speed up (7.9 ms per tile against
    /// 3.9 ms of actual work).
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

    /// Returns PNG bytes for `image`, or nil to fall back to the platform encoder.
    static func encode(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let pixels = scratch(byteCount)
        let base = pixels.mutableBytes

        // Drawn into a context we own rather than read out of the CGImage:
        // a CGImage's backing store may be any layout CoreGraphics chose, and
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

        var outPointer: UnsafeMutablePointer<UInt8>?
        var outLength = 0
        let status = tile_png_encode(
            base.assumingMemoryBound(to: UInt8.self),
            UInt32(width),
            UInt32(height),
            // premultipliedLast above, and PNG stores straight alpha: without
            // undoing it every partly transparent pixel darkens, which on
            // marker tiles is every icon edge.
            1,
            &outPointer,
            &outLength
        )

        guard status == ok, let outPointer else { return nil }
        defer { tile_png_buffer_free(outPointer, outLength) }
        return Data(bytes: outPointer, count: outLength)
    }
}
