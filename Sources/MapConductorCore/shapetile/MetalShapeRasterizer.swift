import CoreGraphics
import Foundation
import Metal

/// 円のタイルを GPU で描く。
///
/// ``MetalMarkerRasterizer`` と同じ骨格 -- オフスクリーンへ描いて読み戻し、
/// PNG 化は core の Rust エンコーダに渡す。違うのは中身で、あちらはアトラスを
/// 貼るクアッド、こちらは円 1 つを 1 インスタンスにして、塗りと縁を距離で描く。
///
/// ## なぜ要るか
///
/// CPU 側は円 1 つごとに `fillEllipse` と `strokeEllipse` を呼ぶ。US Antenna
/// Horizons（723,800 個）を引いたズームで見ると 1 タイルに 10 万個近く入り、
/// 1 枚に 2 秒かかっていた。ピンチのたびにそれが何枚も並び、地図が止まって見えた。
///
/// ## CPU 経路と同じ絵にするために
///
/// - 座標はタイルの画素（上が 0）。CPU 経路の点に `pixelRatio` を掛けたもの。
/// - 塗り・縁とも、画素の中心から境界までの距離で 1 px 幅のアンチエイリアス。
///   縁は輪郭に中心を合わせた幅 `strokeWidth` の帯。
/// - 1 つの円の中では塗りの上に縁を重ね、円どうしは渡した順に source-over で
///   重ねる。1 回の描画命令の中でもブレンドはインスタンスの順に行われる。
///
/// Metal が使えないときは `nil` を返す。呼び出し側は CPU 経路へ落ちる。
final class MetalShapeRasterizer {

    /// インスタンス 1 件。シェーダの `Instance` と同じ並び。
    struct Instance {
        /// 円の中心（タイルの画素）。矩形のときは左上。
        var x: Float
        var y: Float
        /// 円の半径（画素）。矩形のときは幅。
        var radius: Float
        /// 縁の幅（画素）。縁を描かないときは 0。矩形のときは高さ。
        var strokeWidth: Float
        /// 乗算済みの RGBA。
        var fill: SIMD4<Float>
        var stroke: SIMD4<Float>
        /// 0: 円、1: 矩形（1 点の塗り）。
        var kind: UInt32
        var padding0: UInt32 = 0
        var padding1: UInt32 = 0
        var padding2: UInt32 = 0
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// 空いている描画先。一辺の画素ごと。タイルは並行して頼まれるので、
    /// 描画を 1 本の列には並べず、描画先を必要なだけ持つ。
    private var idleTargets: [Int: [MTLTexture]] = [:]
    private let targetsLock = NSLock()

    /// ``MetalPathRasterizer`` も同じ関数を MSAA の描画先で使う（1 点の矩形や小さな丸、円）。
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float x;
        float y;
        float radius;
        float strokeWidth;
        float4 fill;
        float4 stroke;
        uint kind;
        uint pad0;
        uint pad1;
        uint pad2;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 pixel;
        uint iid [[flat]];
    };

    vertex VertexOut shape_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant Instance *instances [[buffer(0)]],
                                  constant float &extent [[buffer(1)]]) {
        const float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1),
                                    float2(1,0), float2(1,1), float2(0,1) };
        float2 corner = corners[vid];
        Instance inst = instances[iid];
        float2 lo, hi;
        if (inst.kind == 1) {
            lo = float2(inst.x, inst.y);
            hi = lo + float2(inst.radius, inst.strokeWidth);
        } else {
            // 縁の外側と、アンチエイリアスの 1 px ぶん広げる。
            float reach = inst.radius + inst.strokeWidth * 0.5 + 1.0;
            lo = float2(inst.x, inst.y) - reach;
            hi = float2(inst.x, inst.y) + reach;
        }
        float2 px = mix(lo, hi, corner);
        float2 unit = px / extent;
        VertexOut out;
        out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
        out.pixel = px;
        out.iid = iid;
        return out;
    }

    fragment float4 shape_fragment(VertexOut in [[stage_in]],
                                   constant Instance *instances [[buffer(0)]]) {
        Instance inst = instances[in.iid];
        if (inst.kind == 1) {
            return inst.fill;
        }
        float d = length(in.pixel - float2(inst.x, inst.y));
        float fillCoverage = clamp(inst.radius - d + 0.5, 0.0, 1.0);
        float halfWidth = inst.strokeWidth * 0.5;
        float strokeCoverage = clamp(inst.radius + halfWidth - d + 0.5, 0.0, 1.0)
                             - clamp(inst.radius - halfWidth - d + 0.5, 0.0, 1.0);
        float4 fill = inst.fill * fillCoverage;
        float4 stroke = inst.stroke * strokeCoverage;
        // 塗りの上に縁（乗算済みの source-over）。
        return stroke + fill * (1.0 - stroke.a);
    }
    """

    /// 1 つを使い回す。パイプラインの作成は重い。
    static let shared: MetalShapeRasterizer? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        return try? MetalShapeRasterizer(device: device, commandQueue: commandQueue)
    }()

    private init(device: MTLDevice, commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "shape_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "shape_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba8Unorm
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.alphaBlendOperation = .add
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// `CGColor` を乗算済みの RGBA（sRGB）にする。描かない色は nil。
    static func premultiplied(_ color: CGColor?) -> SIMD4<Float>? {
        guard let color, color.alpha > 0,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 4 else { return nil }
        let a = Float(min(max(c[3], 0), 1))
        func channel(_ v: CGFloat) -> Float { Float(min(max(v, 0), 1)) * a }
        return SIMD4<Float>(channel(c[0]), channel(c[1]), channel(c[2]), a)
    }

    /// 一辺 `pixels` のタイルに描いて PNG にする。描けなければ nil で、呼び出し側は CPU へ落ちる。
    func renderPng(instances: [Instance], pixels: Int) -> Data? {
        guard !instances.isEmpty, pixels > 0, let target = acquire(pixels) else { return nil }
        defer { release(target, pixels) }
        return draw(instances: instances, pixels: pixels, target: target)
    }

    private func acquire(_ pixels: Int) -> MTLTexture? {
        targetsLock.lock()
        if let idle = idleTargets[pixels]?.popLast() {
            targetsLock.unlock()
            return idle
        }
        targetsLock.unlock()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: pixels, height: pixels, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }

    private func release(_ target: MTLTexture, _ pixels: Int) {
        targetsLock.lock()
        idleTargets[pixels, default: []].append(target)
        targetsLock.unlock()
    }

    private func draw(instances: [Instance], pixels: Int, target: MTLTexture) -> Data? {
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

        var extent = Float(pixels)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&extent, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: instances.count)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.error == nil else { return nil }

        let bytesPerRow = pixels * 4
        var readback = [UInt8](repeating: 0, count: bytesPerRow * pixels)
        readback.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        }
        return readback.withUnsafeMutableBytes { raw -> Data? in
            guard let base = raw.baseAddress else { return nil }
            return TilePngEncoder.encode(rgba: base, width: pixels, height: pixels, premultiplied: true)
        }
    }
}
