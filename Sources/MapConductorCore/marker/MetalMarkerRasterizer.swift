import CoreGraphics
import Metal
import UIKit

/// マーカータイルを GPU で描く。
///
/// ios-vectortile の `MetalTileRasterizer` と同じ骨格 -- オフスクリーンへ描いて
/// 読み戻し、PNG 化は core の Rust エンコーダに渡す。違うのは中身で、あちらは
/// 単色の三角形、こちらはテクスチャ付きのクアッドをインスタンスで並べる。
///
/// ## なぜ効くか
///
/// CPU 側は `CGContext.draw(image:in:)` をマーカーの数だけ呼ぶ。1 回ごとに
/// 状態を触り、クリップを評価し、ブレンドする。GPU 側は描画命令 1 つで、
/// 位置と大きさだけがインスタンスごとに変わる。実測（iPad Pro 11、768px の
/// タイルへ 17,937 個）で **351.8ms 対 3.8ms** -- 読み戻しを含めて 93 倍。
///
/// ## 前提
///
/// アイコンは種類が少なく（街路樹サンプルで 101 種）、マーカーの数だけある
/// わけではない。だから 1 枚のアトラスに詰めて、インスタンスごとには UV の
/// 矩形だけ渡せば済む。
///
/// Metal が使えないときは `nil` を返す。呼び出し側は CPU 経路へ落ちる。
final class MetalMarkerRasterizer {

    /// インスタンス 1 件。シェーダの `Instance` と同じ並び。
    struct Instance {
        /// 描画先。タイル座標（padding を含んだまま）。
        var left: Float
        var top: Float
        var width: Float
        var height: Float
        /// アトラス上の位置。0..1。
        var u0: Float
        var v0: Float
        var u1: Float
        var v1: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let queue = DispatchQueue(label: "com.mapconductor.marker.metal")

    private let tileSize: Int
    private var target: MTLTexture?

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float4 rect;   // left, top, width, height（タイル座標）
        float4 uv;     // u0, v0, u1, v1
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut marker_vertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   constant Instance *instances [[buffer(0)]],
                                   constant float2 &extent [[buffer(1)]],
                                   constant float &padding [[buffer(2)]]) {
        // クアッドは頂点 id から組み立てる。頂点バッファは持たない。
        const float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1),
                                    float2(1,0), float2(1,1), float2(0,1) };
        float2 corner = corners[vid];
        Instance inst = instances[iid];

        // CPU 経路は canvas を -padding だけずらして描く。同じ位置に出す。
        float2 px = inst.rect.xy + corner * inst.rect.zw - padding;
        float2 unit = px / extent;

        VertexOut out;
        out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
        out.uv = mix(inst.uv.xy, inst.uv.zw, corner);
        return out;
    }

    fragment float4 marker_fragment(VertexOut in [[stage_in]],
                                    texture2d<float> atlas [[texture(0)]],
                                    sampler smp [[sampler(0)]]) {
        return atlas.sample(smp, in.uv);
    }
    """

    /// Metal が使えなければ nil。シミュレータの一部や、パイプラインを拒む端末。
    /// 呼び出し側は失敗ではなく CPU 経路として扱う。
    static func createOrNull(tileSize: Int) -> MetalMarkerRasterizer? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        do {
            return try MetalMarkerRasterizer(device: device, commandQueue: commandQueue, tileSize: tileSize)
        } catch {
            return nil
        }
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue, tileSize: Int) throws {
        self.device = device
        self.commandQueue = commandQueue
        self.tileSize = tileSize

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "marker_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "marker_fragment")

        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba8Unorm
        attachment.isBlendingEnabled = true
        // アトラスは乗算済みアルファで積むので、source は one。
        attachment.rgbBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.alphaBlendOperation = .add
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        // CPU 経路は interpolationQuality = .none。同じ絵にするため最近傍。
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalMarkerError.unavailable
        }
        self.sampler = sampler
    }

    private enum MetalMarkerError: Error { case unavailable }

    /// 別々の CGImage をひとつのアトラスへ詰め、UV を返す。
    ///
    /// アイコンは種類が少ないので、正方に近い格子に等間隔で並べるだけで足りる。
    /// 詰め方を凝っても、ここは 1 タイルに数十枚しか入らない。
    func makeAtlas(_ images: [CGImage]) -> (texture: MTLTexture, uv: [CGRect])? {
        guard !images.isEmpty else { return nil }
        let cellWidth = images.map(\.width).max() ?? 1
        let cellHeight = images.map(\.height).max() ?? 1
        let columns = Int(ceil(sqrt(Double(images.count))))
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let width = columns * cellWidth
        let height = rows * cellHeight

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var uv: [CGRect] = []
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            for (at, image) in images.enumerated() {
                let column = at % columns
                let row = at / columns
                let rect = CGRect(x: column * cellWidth, y: row * cellHeight,
                                  width: image.width, height: image.height)
                context.draw(image, in: rect)
                /*
                 v は**下から**測る。

                 `CGContext(data:)` の原点は左下で、「行 r」に置いたつもりの
                 アイコンはメモリ上では行 rows-1-r に居る。テクスチャはメモリを
                 そのまま積むので、上基準の v を渡すと**1 行反転ぶん別のアイコン**を
                 サンプルする -- 単体テストでは 3x3 の行 0 と行 2 がそっくり
                 入れ替わり、反転先が最終行の空セルに落ちたアイコンは絵ごと
                 消えた。実機では「タイル右端のマーカーが消える」「1 つの丸に
                 2 色」という継ぎ目の割れとして見えていた。アイコン自体は
                 CG がイメージも同じ向きで描くため二重反転で正立しており、
                 ずれるのは行の割り当てだけ。

                 半テクセルの内側詰めは最近傍サンプリングが隣のセルの端を
                 拾わないための保険。
                 */
                let insetX = 0.5 / Double(width)
                let insetY = 0.5 / Double(height)
                let flippedY = Double(height) - rect.maxY
                uv.append(CGRect(
                    x: rect.minX / Double(width) + insetX,
                    y: flippedY / Double(height) + insetY,
                    width: rect.width / Double(width) - 2 * insetX,
                    height: rect.height / Double(height) - 2 * insetY
                ))
            }
        }
        guard uv.count == images.count else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: bytesPerRow)
        return (texture, uv)
    }

    /// 描いて PNG にする。描けなければ nil で、呼び出し側は CPU へ落ちる。
    func renderPng(instances: [Instance], atlas: MTLTexture, paddingPx: Int) -> Data? {
        guard !instances.isEmpty else { return nil }
        return queue.sync { draw(instances: instances, atlas: atlas, paddingPx: paddingPx) }
    }

    private func draw(instances: [Instance], atlas: MTLTexture, paddingPx: Int) -> Data? {
        let target: MTLTexture
        if let existing = self.target {
            target = existing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: tileSize, height: tileSize, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let fresh = device.makeTexture(descriptor: descriptor) else { return nil }
            self.target = fresh
            target = fresh
        }

        guard let instanceBuffer = device.makeBuffer(
            bytes: instances,
            length: MemoryLayout<Instance>.stride * instances.count,
            options: .storageModeShared
        ) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var extent = SIMD2<Float>(Float(tileSize), Float(tileSize))
        var padding = Float(paddingPx)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&extent, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setVertexBytes(&padding, length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: instances.count)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.error == nil else { return nil }

        let bytesPerRow = tileSize * 4
        var readback = [UInt8](repeating: 0, count: bytesPerRow * tileSize)
        readback.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, tileSize, tileSize), mipmapLevel: 0)
        }
        return readback.withUnsafeMutableBytes { raw -> Data? in
            guard let base = raw.baseAddress else { return nil }
            // ブレンドは乗算済みアルファのまま積むので、CPU 経路と同じ扱い。
            return TilePngEncoder.encode(rgba: base, width: tileSize, height: tileSize,
                                         premultiplied: true)
        }
    }
}
