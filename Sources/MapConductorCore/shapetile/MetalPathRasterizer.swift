import CoreGraphics
import Foundation
import Metal

/// ポリゴンとポリラインのタイルを GPU で描く。
///
/// 円（``MetalShapeRasterizer``）と違って、1 つを 1 インスタンスでは描けない。
/// CPU 経路（`CGContext`）と同じ絵にするために要るのは 3 つ:
///
/// - **nonzero の塗り。** 外周と穴は逆向きに巻いてあり、重なった穴の和も
///   計算せずに抜ける（``ShapeTileRenderer`` の説明）。GPU では stencil-then-cover:
///   各リングを 1 点から張った三角形の扇で、表は +1・裏は -1 をステンシルに積み、
///   図形の外接矩形を「ステンシルが 0 でない所」だけ塗って 0 に戻す。
/// - **丸い角と端の線。** 線分ごとの四角形と、頂点ごとの円を、ステンシルに
///   「1 にする」で書き、外接矩形を 1 回だけ塗る。半透明の線でも継ぎ目が
///   2 度塗りにならない（CGContext の `strokePath` と同じ）。
/// - **アンチエイリアス。** 4x の MSAA。ステンシルもサンプルごとに持つので、
///   縁は塗られたサンプルの割合になる。
///
/// ## 順番
///
/// 図形は渡した順に重なる。1 つずつ描くと命令が図形の数の 4 倍になるので、
/// **外接矩形が重ならない図形をまとめて** 1 組の命令で描く（``Scene/Batch``）。
/// 重ならない図形どうしの順番は絵に出ない。重なる図形が来たら組を閉じる。
/// 組の中では 塗り → 円 → 線 の順で、1 つの図形の縁は塗りの上に乗る。
///
/// ## ポリライン
///
/// 道路は外接矩形が重なり合うので、上の組がほぼ 1 本ずつに割れる（4 万本で 4 万組）。
/// そこでポリラインは別の道で描く: 線ごとに 1〜255 の番号を振り、フラグメントシェーダが
/// その番号をステンシルの参照値として書く（stencil feedback）。「ステンシルが自分の番号で
/// ない所だけ塗って、自分の番号にする」ので、同じ線の継ぎ目や交差は 1 度しか塗らず、
/// 線どうしは渡した順に重なる。これが 1 回の描画命令で済む。255 本ごとにステンシルを
/// 消して番号を振り直す（``Scene/lineGroups``）。
///
/// stencil feedback の無い GPU（シミュレータなど）では、同じことを 1 本ずつの描画命令で
/// する: 参照値をその線の番号にして描く（``Scene/lines``）。命令は線の本数だけになるが、
/// 絵は同じ。
///
/// ## 並行
///
/// タイルは何枚も同時に頼まれる。描画先は使い回しの組を必要なだけ持ち、
/// 描画を 1 本の列には並べない（並べると 1 枚 10 ms の描画が 300 ms 待つ）。
///
/// Metal が使えないときは `nil` を返す。呼び出し側は CPU 経路へ落ちる。
final class MetalPathRasterizer {

    /// 外接矩形と色。ステンシルを通った所だけを塗る。
    struct Cover {
        /// 左・上・右・下（タイルの画素）。
        var rect: SIMD4<Float>
        /// 乗算済みの RGBA。
        var color: SIMD4<Float>
    }

    /// ポリラインの頂点。シェーダの `LineVertex` と同じ並び。
    struct LineVertex {
        var position: SIMD2<Float>
        /// 線の番号（1〜255）。ステンシルに書く。
        var id: UInt32
        var padding: UInt32 = 0
        /// 乗算済みの RGBA。
        var color: SIMD4<Float>
    }

    /// 1 タイル分の描画。頂点・矩形・円を 1 本ずつのバッファに並べ、組ごとに範囲で指す。
    struct Scene {
        struct Batch {
            var fill = 0..<0
            var fillCovers = 0..<0
            var circles = 0..<0
            var stroke = 0..<0
            var strokeCovers = 0..<0
        }

        /// 塗りの扇（三角形のリスト）。
        var fillVertices: [SIMD2<Float>] = []
        /// 線の四角形と、角・端の円（三角形のリスト）。
        var strokeVertices: [SIMD2<Float>] = []
        var fillCovers: [Cover] = []
        var strokeCovers: [Cover] = []
        /// 1 点の矩形や小さな丸、円（距離で描く）。
        var circles: [MetalShapeRasterizer.Instance] = []
        var batches: [Batch] = []
        /// ポリラインと、1 点に縮んだ線の丸（三角形のリスト）。
        var lineVertices: [LineVertex] = []
        /// 255 本ずつの区切り。区切りの前でステンシルを消す。
        var lineGroups: [Range<Int>] = []
        /// 1 本ずつの頂点の範囲と番号。stencil feedback の無い GPU で使う。
        var lines: [(vertices: Range<Int>, id: UInt32)] = []

        var isEmpty: Bool { fillCovers.isEmpty && strokeCovers.isEmpty && circles.isEmpty && lineVertices.isEmpty }
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let stencilPipeline: MTLRenderPipelineState
    private let coverPipeline: MTLRenderPipelineState
    private let circlePipeline: MTLRenderPipelineState
    private let fillStencil: MTLDepthStencilState
    private let strokeStencil: MTLDepthStencilState
    private let coverStencil: MTLDepthStencilState
    private let noStencil: MTLDepthStencilState
    /// stencil feedback で番号をシェーダから書く。無い GPU では nil。
    private let linePipeline: MTLRenderPipelineState?
    /// 番号を参照値で渡す（1 本ずつ描く）。
    private let lineByReferencePipeline: MTLRenderPipelineState
    private let lineStencil: MTLDepthStencilState
    private let clearStencil: MTLDepthStencilState
    private typealias Targets = (msaa: MTLTexture, stencil: MTLTexture, resolved: MTLTexture)
    /// 空いている描画先。一辺の画素ごと。
    private var idleTargets: [Int: [Targets]] = [:]
    private let targetsLock = NSLock()

    /// ポリラインをまとめて描けるか（stencil feedback、Apple GPU 5 以降）。
    /// 偽でも描けるが、1 本ずつの命令になる。
    var drawsLinesTogether: Bool { linePipeline != nil }

    static let sampleCount = 4

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    vertex float4 path_vertex(uint vid [[vertex_id]],
                              constant float2 *points [[buffer(0)]],
                              constant float &extent [[buffer(1)]]) {
        float2 unit = points[vid] / extent;
        return float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
    }

    struct Cover {
        float4 rect;
        float4 color;
    };

    struct CoverOut {
        float4 position [[position]];
        float4 color [[flat]];
    };

    vertex CoverOut cover_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 constant Cover *covers [[buffer(0)]],
                                 constant float &extent [[buffer(1)]]) {
        const float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1),
                                    float2(1,0), float2(1,1), float2(0,1) };
        Cover cover = covers[iid];
        float2 px = mix(cover.rect.xy, cover.rect.zw, corners[vid]);
        float2 unit = px / extent;
        CoverOut out;
        out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
        out.color = cover.color;
        return out;
    }

    fragment float4 cover_fragment(CoverOut in [[stage_in]]) {
        return in.color;
    }
    """

    private static let lineShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LineVertex {
        float2 position;
        uint id;
        uint pad;
        float4 color;
    };

    struct LineOut {
        float4 position [[position]];
        float4 color [[flat]];
        uint id [[flat]];
    };

    vertex LineOut line_vertex(uint vid [[vertex_id]],
                               constant LineVertex *vertices [[buffer(0)]],
                               constant float &extent [[buffer(1)]]) {
        LineVertex v = vertices[vid];
        float2 unit = v.position / extent;
        LineOut out;
        out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
        out.color = v.color;
        out.id = v.id;
        return out;
    }

    struct LineFragment {
        float4 color [[color(0)]];
        uint stencil [[stencil]];
    };

    fragment LineFragment line_fragment(LineOut in [[stage_in]]) {
        LineFragment out;
        out.color = in.color;
        out.stencil = in.id;
        return out;
    }
    """

    /// 番号を参照値で渡すほう。頂点は同じ ``LineVertex``。
    private static let lineByReferenceShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LineVertex {
        float2 position;
        uint id;
        uint pad;
        float4 color;
    };

    struct LineOut {
        float4 position [[position]];
        float4 color [[flat]];
    };

    vertex LineOut line_vertex(uint vid [[vertex_id]],
                               constant LineVertex *vertices [[buffer(0)]],
                               constant float &extent [[buffer(1)]]) {
        LineVertex v = vertices[vid];
        float2 unit = v.position / extent;
        LineOut out;
        out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 line_fragment(LineOut in [[stage_in]]) {
        return in.color;
    }
    """

    static let shared: MetalPathRasterizer? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              device.supportsTextureSampleCount(sampleCount) else { return nil }
        return try? MetalPathRasterizer(device: device, commandQueue: commandQueue)
    }()

    private init(device: MTLDevice, commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let circleLibrary = try device.makeLibrary(source: MetalShapeRasterizer.shaderSource, options: nil)

        func pipeline(vertex: String, fragment: String?, library: MTLLibrary, writesColor: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
            descriptor.rasterSampleCount = Self.sampleCount
            descriptor.stencilAttachmentPixelFormat = .stencil8
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .rgba8Unorm
            if writesColor {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.alphaBlendOperation = .add
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            } else {
                attachment.writeMask = []
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        stencilPipeline = try pipeline(vertex: "path_vertex", fragment: nil, library: library, writesColor: false)
        coverPipeline = try pipeline(vertex: "cover_vertex", fragment: "cover_fragment", library: library, writesColor: true)
        circlePipeline = try pipeline(vertex: "shape_vertex", fragment: "shape_fragment", library: circleLibrary, writesColor: true)
        let byReferenceLibrary = try device.makeLibrary(source: Self.lineByReferenceShaderSource, options: nil)
        lineByReferencePipeline = try pipeline(vertex: "line_vertex", fragment: "line_fragment", library: byReferenceLibrary, writesColor: true)
        if device.supportsFamily(.apple5), let lineLibrary = try? device.makeLibrary(source: Self.lineShaderSource, options: nil) {
            linePipeline = try? pipeline(vertex: "line_vertex", fragment: "line_fragment", library: lineLibrary, writesColor: true)
        } else {
            linePipeline = nil
        }

        func stencilState(_ configure: (MTLStencilDescriptor, MTLStencilDescriptor) -> Void) throws -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            let front = MTLStencilDescriptor(), back = MTLStencilDescriptor()
            configure(front, back)
            descriptor.frontFaceStencil = front
            descriptor.backFaceStencil = back
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else { throw PathError.unavailable }
            return state
        }
        // nonzero: 表向きの三角形は +1、裏向きは -1（どちらも 256 で折り返す）。
        fillStencil = try stencilState { front, back in
            front.depthStencilPassOperation = .incrementWrap
            back.depthStencilPassOperation = .decrementWrap
        }
        // 線: 触れた所を 1 に。何度重なっても 1 のまま。
        strokeStencil = try stencilState { front, back in
            front.depthStencilPassOperation = .replace
            back.depthStencilPassOperation = .replace
        }
        // 塗る: ステンシルが 0 でない所だけ。塗ったら 0 に戻して次の図形に渡す。
        coverStencil = try stencilState { front, back in
            for side in [front, back] {
                side.stencilCompareFunction = .notEqual
                side.depthStencilPassOperation = .zero
            }
        }
        noStencil = try stencilState { _, _ in }
        // 線: 自分の番号（シェーダが書く参照値）でない所だけ塗って、自分の番号にする。
        lineStencil = try stencilState { front, back in
            for side in [front, back] {
                side.stencilCompareFunction = .notEqual
                side.depthStencilPassOperation = .replace
            }
        }
        clearStencil = try stencilState { front, back in
            for side in [front, back] { side.depthStencilPassOperation = .zero }
        }
    }

    private enum PathError: Error { case unavailable }

    /// 一辺 `pixels` のタイルに描いて PNG にする。描けなければ nil で、呼び出し側は CPU へ落ちる。
    func renderPng(_ scene: Scene, pixels: Int) -> Data? {
        guard !scene.isEmpty, pixels > 0,
              let targets = acquire(pixels) else { return nil }
        defer { release(targets, pixels) }
        return draw(scene, pixels: pixels, target: targets)
    }

    private func buffer<T>(_ items: [T]) -> MTLBuffer? {
        // 空の配列でも束縛できるように、最低 1 要素ぶん取る。
        let length = max(1, items.count) * MemoryLayout<T>.stride
        if items.isEmpty { return device.makeBuffer(length: length, options: .storageModeShared) }
        return items.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: length, options: .storageModeShared) }
    }

    private func draw(_ scene: Scene, pixels: Int, target: Targets) -> Data? {
        guard let fillVertices = buffer(scene.fillVertices),
              let strokeVertices = buffer(scene.strokeVertices),
              let fillCovers = buffer(scene.fillCovers),
              let strokeCovers = buffer(scene.strokeCovers),
              let circles = buffer(scene.circles),
              let lineVertices = buffer(scene.lineVertices) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.msaa
        pass.colorAttachments[0].resolveTexture = target.resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.stencilAttachment.texture = target.stencil
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        pass.stencilAttachment.clearStencil = 0
        guard let commands = commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var extent = Float(pixels)
        encoder.setVertexBytes(&extent, length: MemoryLayout<Float>.size, index: 1)
        for batch in scene.batches {
            if !batch.fill.isEmpty {
                encoder.setRenderPipelineState(stencilPipeline)
                encoder.setDepthStencilState(fillStencil)
                encoder.setVertexBuffer(fillVertices, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: batch.fill.lowerBound, vertexCount: batch.fill.count)
            }
            if !batch.fillCovers.isEmpty {
                encoder.setRenderPipelineState(coverPipeline)
                encoder.setDepthStencilState(coverStencil)
                encoder.setStencilReferenceValue(0)
                encoder.setVertexBuffer(fillCovers, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: batch.fillCovers.count, baseInstance: batch.fillCovers.lowerBound)
            }
            if !batch.circles.isEmpty {
                encoder.setRenderPipelineState(circlePipeline)
                encoder.setDepthStencilState(noStencil)
                encoder.setVertexBuffer(circles, offset: 0, index: 0)
                encoder.setFragmentBuffer(circles, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: batch.circles.count, baseInstance: batch.circles.lowerBound)
            }
            if !batch.stroke.isEmpty {
                encoder.setRenderPipelineState(stencilPipeline)
                encoder.setDepthStencilState(strokeStencil)
                encoder.setStencilReferenceValue(1)
                encoder.setVertexBuffer(strokeVertices, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: batch.stroke.lowerBound, vertexCount: batch.stroke.count)
            }
            if !batch.strokeCovers.isEmpty {
                encoder.setRenderPipelineState(coverPipeline)
                encoder.setDepthStencilState(coverStencil)
                encoder.setStencilReferenceValue(0)
                encoder.setVertexBuffer(strokeCovers, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: batch.strokeCovers.count, baseInstance: batch.strokeCovers.lowerBound)
            }
        }
        if !scene.lineGroups.isEmpty {
            let p = Float(pixels)
            var whole: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(p, 0), SIMD2(0, p), SIMD2(p, 0), SIMD2(p, p), SIMD2(0, p)]
            /// 番号を振り直す前に、前の 255 本が残した番号を消す。
            func clear() {
                encoder.setRenderPipelineState(stencilPipeline)
                encoder.setDepthStencilState(clearStencil)
                encoder.setVertexBytes(&whole, length: MemoryLayout<SIMD2<Float>>.stride * 6, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            if let linePipeline {
                for (n, group) in scene.lineGroups.enumerated() {
                    if n > 0 { clear() }
                    encoder.setRenderPipelineState(linePipeline)
                    encoder.setDepthStencilState(lineStencil)
                    encoder.setVertexBuffer(lineVertices, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: group.lowerBound, vertexCount: group.count)
                }
            } else {
                for (n, line) in scene.lines.enumerated() {
                    if n > 0 && line.id == 1 { clear() }
                    encoder.setRenderPipelineState(lineByReferencePipeline)
                    encoder.setDepthStencilState(lineStencil)
                    encoder.setStencilReferenceValue(line.id)
                    encoder.setVertexBuffer(lineVertices, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: line.vertices.lowerBound, vertexCount: line.vertices.count)
                }
            }
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.error == nil else { return nil }

        let bytesPerRow = pixels * 4
        var readback = [UInt8](repeating: 0, count: bytesPerRow * pixels)
        readback.withUnsafeMutableBytes { raw in
            target.resolved.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                                     from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        }
        return readback.withUnsafeMutableBytes { raw -> Data? in
            guard let base = raw.baseAddress else { return nil }
            return TilePngEncoder.encode(rgba: base, width: pixels, height: pixels, premultiplied: true)
        }
    }

    private func release(_ targets: Targets, _ pixels: Int) {
        targetsLock.lock()
        idleTargets[pixels, default: []].append(targets)
        targetsLock.unlock()
    }

    private func acquire(_ pixels: Int) -> Targets? {
        targetsLock.lock()
        if let idle = idleTargets[pixels]?.popLast() {
            targetsLock.unlock()
            return idle
        }
        targetsLock.unlock()
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: pixels, height: pixels, mipmapped: false)
            descriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
            descriptor.sampleCount = samples
            descriptor.usage = usage
            descriptor.storageMode = samples > 1 ? .private : .shared
            return device.makeTexture(descriptor: descriptor)
        }
        guard let msaa = texture(.rgba8Unorm, samples: Self.sampleCount, usage: .renderTarget),
              let stencil = texture(.stencil8, samples: Self.sampleCount, usage: .renderTarget),
              let resolved = texture(.rgba8Unorm, samples: 1, usage: [.renderTarget, .shaderRead]) else { return nil }
        return (msaa, stencil, resolved)
    }
}

/// 1 タイル分の ``MetalPathRasterizer/Scene`` を組み立てる。座標はタイルの画素（上が 0）。
///
/// 図形を足すたびに、その外接矩形が今の組のどれかと重なるかを粗い格子（8 px）で見て、
/// 重なるなら組を閉じる。
struct PathSceneBuilder {
    private(set) var scene = MetalPathRasterizer.Scene()
    private var current = MetalPathRasterizer.Scene.Batch()
    private let pixels: Int
    private let cell = 8
    private let cells: Int
    private var occupied: [Bool]
    private var touched: [Int] = []
    private var lineCount = 0
    private var lineGroupStart = 0

    init(pixels: Int) {
        self.pixels = pixels
        cells = (pixels + cell - 1) / cell
        occupied = [Bool](repeating: false, count: cells * cells)
        current = Self.empty(at: scene)
    }

    private static func empty(at scene: MetalPathRasterizer.Scene) -> MetalPathRasterizer.Scene.Batch {
        .init(
            fill: scene.fillVertices.count..<scene.fillVertices.count,
            fillCovers: scene.fillCovers.count..<scene.fillCovers.count,
            circles: scene.circles.count..<scene.circles.count,
            stroke: scene.strokeVertices.count..<scene.strokeVertices.count,
            strokeCovers: scene.strokeCovers.count..<scene.strokeCovers.count
        )
    }

    private mutating func close() {
        current = .init(
            fill: current.fill.lowerBound..<scene.fillVertices.count,
            fillCovers: current.fillCovers.lowerBound..<scene.fillCovers.count,
            circles: current.circles.lowerBound..<scene.circles.count,
            stroke: current.stroke.lowerBound..<scene.strokeVertices.count,
            strokeCovers: current.strokeCovers.lowerBound..<scene.strokeCovers.count
        )
        if !(current.fillCovers.isEmpty && current.circles.isEmpty && current.strokeCovers.isEmpty) {
            scene.batches.append(current)
        }
        for i in touched { occupied[i] = false }
        touched.removeAll(keepingCapacity: true)
        current = Self.empty(at: scene)
    }

    /// 外接矩形 `rect`（左・上・右・下）の図形を今の組に入れてよいか確かめ、
    /// 重なるなら組を閉じてから場所を取る。タイルの外なら false（描かない）。
    private mutating func claim(_ rect: SIMD4<Float>) -> Bool {
        let x0 = max(0, Int(floor(rect.x)) / cell), y0 = max(0, Int(floor(rect.y)) / cell)
        let x1 = min(cells - 1, Int(ceil(rect.z)) / cell), y1 = min(cells - 1, Int(ceil(rect.w)) / cell)
        guard rect.z >= 0, rect.w >= 0, rect.x <= Float(pixels), rect.y <= Float(pixels), x0 <= x1, y0 <= y1 else { return false }
        var overlaps = false
        outer: for y in y0...y1 { for x in x0...x1 where occupied[y * cells + x] { overlaps = true; break outer } }
        if overlaps { close() }
        for y in y0...y1 { for x in x0...x1 {
            let i = y * cells + x
            if !occupied[i] { occupied[i] = true; touched.append(i) }
        } }
        return true
    }

    /// 円か矩形（``MetalShapeRasterizer/Instance``）を 1 つ。
    mutating func add(circle: MetalShapeRasterizer.Instance) {
        let rect: SIMD4<Float>
        if circle.kind == 1 {
            rect = SIMD4(circle.x, circle.y, circle.x + circle.radius, circle.y + circle.strokeWidth)
        } else {
            let reach = circle.radius + circle.strokeWidth / 2 + 1
            rect = SIMD4(circle.x - reach, circle.y - reach, circle.x + reach, circle.y + reach)
        }
        guard claim(rect) else { return }
        scene.circles.append(circle)
    }

    /// ポリゴン 1 つ: `rings`（画素、`[x, y, ...]`）を nonzero で塗り、`outline` なら 1 本目の縁を描く。
    mutating func add(polygon rings: [[Float]], fill: SIMD4<Float>?, outline: SIMD4<Float>?, strokeWidth: Float) {
        guard let first = rings.first, first.count >= 6 else { return }
        var box = Self.bounds(first)
        if outline != nil { box = Self.inflate(box, by: strokeWidth / 2) }
        guard claim(Self.inflate(box, by: 1)) else { return }
        if let fill {
            let pivot = SIMD2(first[0], first[1])
            for ring in rings {
                let n = ring.count / 2
                guard n >= 3 else { continue }
                for i in 0..<n {
                    let j = (i + 1) % n
                    scene.fillVertices.append(pivot)
                    scene.fillVertices.append(SIMD2(ring[i * 2], ring[i * 2 + 1]))
                    scene.fillVertices.append(SIMD2(ring[j * 2], ring[j * 2 + 1]))
                }
            }
            scene.fillCovers.append(.init(rect: Self.inflate(Self.bounds(first), by: 1), color: fill))
        }
        if let outline {
            Self.stroke(first, closed: true, halfWidth: strokeWidth / 2, into: &scene.strokeVertices) { $0 }
            scene.strokeCovers.append(.init(rect: Self.inflate(box, by: 1), color: outline))
        }
    }

    /// ポリライン 1 本（画素、`[x, y, ...]`、2 点以上）を、番号付きの線として。
    /// 外接矩形の重なりは見ない（``MetalPathRasterizer`` の「ポリライン」）。
    mutating func add(line points: [Float], color: SIMD4<Float>, strokeWidth: Float) {
        guard points.count >= 4 else { return }
        let id = nextLineId()
        let start = scene.lineVertices.count
        Self.stroke(points, closed: false, halfWidth: strokeWidth / 2, into: &scene.lineVertices) {
            .init(position: $0, id: id, color: color)
        }
        if scene.lineVertices.count > start { scene.lines.append((start..<scene.lineVertices.count, id)) }
    }

    /// 1 点に縮んだ線: 中心 `center`、半径 `radius` の丸を、番号付きの線として。
    mutating func add(lineDot center: SIMD2<Float>, radius: Float, color: SIMD4<Float>) {
        let id = nextLineId()
        let start = scene.lineVertices.count
        Self.disc(center, radius: radius, into: &scene.lineVertices) { .init(position: $0, id: id, color: color) }
        scene.lines.append((start..<scene.lineVertices.count, id))
    }

    /// 次の線の番号（1〜255）。使い切ったら区切って、ステンシルを消してから振り直す。
    private mutating func nextLineId() -> UInt32 {
        if lineCount > 0 && lineCount % 255 == 0 {
            scene.lineGroups.append(lineGroupStart..<scene.lineVertices.count)
            lineGroupStart = scene.lineVertices.count
        }
        let id = UInt32(lineCount % 255 + 1)
        lineCount += 1
        return id
    }

    mutating func finish() -> MetalPathRasterizer.Scene {
        close()
        if scene.lineVertices.count > lineGroupStart {
            scene.lineGroups.append(lineGroupStart..<scene.lineVertices.count)
        }
        return scene
    }

    private static func bounds(_ points: [Float]) -> SIMD4<Float> {
        var box = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
        var i = 0
        while i < points.count {
            box.x = min(box.x, points[i]); box.z = max(box.z, points[i])
            box.y = min(box.y, points[i + 1]); box.w = max(box.w, points[i + 1])
            i += 2
        }
        return box
    }

    private static func inflate(_ box: SIMD4<Float>, by d: Float) -> SIMD4<Float> {
        SIMD4(box.x - d, box.y - d, box.z + d, box.w + d)
    }

    /// 半径 1 の円の頂点。分割数（6〜32）ごとに 1 度だけ作る。
    private static let unitCircles: [[SIMD2<Float>]] = (0...32).map { segments in
        guard segments >= 6 else { return [] }
        return (0..<segments).map { k in
            let a = Float(k) / Float(segments) * 2 * .pi
            return SIMD2(cos(a), sin(a))
        }
    }

    /// 円の分割数: 半径に応じて。細い線では角の丸みは画素に出ない。
    private static func circleSegments(_ radius: Float) -> Int {
        max(6, min(32, Int((radius * 2).rounded(.up)) + 4))
    }

    /// 線分ごとの四角形と、頂点ごとの円（丸い角と端）。ステンシルで和を取るので重なってよい。
    /// `make` が頂点を出力の型にする（ポリゴンの縁は座標だけ、ポリラインは番号と色付き）。
    @inline(__always)
    private static func stroke<Vertex>(
        _ points: [Float], closed: Bool, halfWidth: Float,
        into out: inout [Vertex], _ make: (SIMD2<Float>) -> Vertex
    ) {
        let n = points.count / 2
        guard n >= 2, halfWidth > 0 else { return }
        let unit = unitCircles[circleSegments(halfWidth)]
        let segments = unit.count
        let edges = closed ? n : n - 1
        points.withUnsafeBufferPointer { p in
            for i in 0..<edges {
                let j = (i + 1) % n
                let a = SIMD2(p[i * 2], p[i * 2 + 1]), b = SIMD2(p[j * 2], p[j * 2 + 1])
                let d = b - a
                let length = (d.x * d.x + d.y * d.y).squareRoot()
                guard length > 0 else { continue }
                let normal = SIMD2(-d.y, d.x) / length * halfWidth
                out.append(make(a + normal)); out.append(make(a - normal)); out.append(make(b + normal))
                out.append(make(a - normal)); out.append(make(b - normal)); out.append(make(b + normal))
            }
            for i in 0..<n {
                let c = SIMD2(p[i * 2], p[i * 2 + 1])
                var previous = c + unit[segments - 1] * halfWidth
                for k in 0..<segments {
                    let next = c + unit[k] * halfWidth
                    out.append(make(c)); out.append(make(previous)); out.append(make(next))
                    previous = next
                }
            }
        }
    }

    /// 中心 `center`、半径 `radius` の丸（三角形の扇）。
    @inline(__always)
    private static func disc<Vertex>(_ center: SIMD2<Float>, radius: Float, into out: inout [Vertex], _ make: (SIMD2<Float>) -> Vertex) {
        let unit = unitCircles[circleSegments(radius)]
        var previous = center + unit[unit.count - 1] * radius
        for k in 0..<unit.count {
            let next = center + unit[k] * radius
            out.append(make(center)); out.append(make(previous)); out.append(make(next))
            previous = next
        }
    }
}
