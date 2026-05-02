//  StereoCompositor.swift
//
//  Slice #4 stereo compositor — renders a side-by-side composite of
//  two VideoFrameSources into a target Metal texture. One mode only:
//  zero-HIT SbS, no anaglyph, no channel test, no crop math. Slices
//  #6 / #7 extend this with HIT/crop and the alignment / channel-test
//  modes; the per-side draw structure is the seam they bolt onto.
//
//  Two pipelines because UYVY and BGRA need different fragment shaders
//  (UYVY samples through the bgrg422-format hardware chroma upsampler
//  and decodes BT.709 limited-range in-shader). Pipeline selection is
//  per-side; the operator can mix BGRA and UYVY sources for free.
//
//  The MTLTexture handed to render() is owned by the caller (typically
//  an MTKView's currentDrawable). We do not present or commit; the
//  caller does. This keeps the compositor reusable for the future
//  CPU-readback path the NDI sender will use in slice #9.

import CoreVideo
import Foundation
import Metal
import simd

@MainActor
final class StereoCompositor {

    enum Error: Swift.Error {
        case defaultLibraryUnavailable
        case shaderFunctionMissing(String)
        case textureCacheCreationFailed(CVReturn)
        case pipelineCreationFailed(Swift.Error)
    }

    /// Width of the offscreen render target consumed by the NDI
    /// sender pipeline. Per PRD: v1 always outputs 1920×1080 SbS.
    static let senderOutputWidth = 1920
    /// Height of the offscreen render target consumed by the NDI
    /// sender pipeline. Per PRD: v1 always outputs 1920×1080 SbS.
    static let senderOutputHeight = 1080

    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let fragmentBGRA: MTLFunction
    private let fragmentUYVY: MTLFunction
    private let vertexDescriptor: MTLVertexDescriptor
    private let textureCache: CVMetalTextureCache

    // (sourceKind, targetPixelFormat) → pipeline. Built lazily so the
    // compositor adapts to both .bgra8Unorm (MTKView default) and
    // .bgra8Unorm_srgb (golden-image test target) without the caller
    // having to pre-declare which.
    private var pipelineCache: [PipelineKey: MTLRenderPipelineState] = [:]

    // Lazily-allocated 1920×1080 .bgra8Unorm offscreen render target
    // for the NDI sender path. Reused across frames; rebuilt only if
    // the device hands back a nil texture. .private storage because
    // the consumer (UYVYEncoder) is a GPU compute pass.
    private var senderTarget: MTLTexture?

    init(device: MTLDevice) throws {
        self.device = device

        guard let library = device.makeDefaultLibrary() else {
            throw Error.defaultLibraryUnavailable
        }

        self.vertexFunction = try Self.loadFunction(library: library, name: "sbs_vertex")
        self.fragmentBGRA = try Self.loadFunction(library: library, name: "sbs_fragment_bgra")
        self.fragmentUYVY = try Self.loadFunction(library: library, name: "sbs_fragment_uyvy")
        self.vertexDescriptor = Self.makeVertexDescriptor()

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw Error.textureCacheCreationFailed(status)
        }
        self.textureCache = cache
    }

    /// Render the SbS composite of `pair` into `target`. The target's
    /// loadAction is .clear (black); a nil pair (or nil eye) draws no
    /// geometry for that half, so the cleared black shows through —
    /// this is also the fallback when the format isn't BGRA/UYVY.
    func render(pair: StereoFramePair,
                into target: MTLTexture,
                commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }

        // Hold CVMetalTextures alive until GPU completion. The MTLTexture
        // returned via CVMetalTextureGetTexture aliases the IOSurface
        // backing; if the CVMetalTexture wrapper is released before the
        // GPU is done sampling, the IOSurface can be recycled. Capturing
        // the array in the completed-handler closure is the standard
        // CV/Metal lifetime pattern.
        var inflight: [CVMetalTexture] = []

        if let leftFrame = pair.left,
           let drawn = drawSide(encoder: encoder,
                                frame: leftFrame,
                                side: .left,
                                targetWidth: target.width,
                                targetHeight: target.height,
                                targetPixelFormat: target.pixelFormat) {
            inflight.append(drawn)
        }

        if let rightFrame = pair.right,
           let drawn = drawSide(encoder: encoder,
                                frame: rightFrame,
                                side: .right,
                                targetWidth: target.width,
                                targetHeight: target.height,
                                targetPixelFormat: target.pixelFormat) {
            inflight.append(drawn)
        }

        encoder.endEncoding()

        if !inflight.isEmpty {
            commandBuffer.addCompletedHandler { _ in
                _ = inflight
            }
        }
    }

    /// Render the SbS composite of `pair` into the compositor's owned
    /// 1920×1080 offscreen BGRA target and return that texture. The
    /// caller appends a UYVY-encode compute pass on the same command
    /// buffer and reads the result back via a completion handler.
    /// Returns nil if the offscreen target couldn't be allocated.
    func renderForSender(pair: StereoFramePair,
                         commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let target = ensureSenderTarget() else {
            return nil
        }
        render(pair: pair, into: target, commandBuffer: commandBuffer)
        return target
    }

    private func ensureSenderTarget() -> MTLTexture? {
        if let existing = senderTarget,
           existing.width == Self.senderOutputWidth,
           existing.height == Self.senderOutputHeight {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Self.senderOutputWidth,
            height: Self.senderOutputHeight,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let target = device.makeTexture(descriptor: descriptor)
        senderTarget = target
        return target
    }

    // MARK: - Per-side draw

    private enum Side {
        case left
        case right
    }

    @discardableResult
    private func drawSide(encoder: MTLRenderCommandEncoder,
                          frame: any VideoFrameSource,
                          side: Side,
                          targetWidth: Int,
                          targetHeight: Int,
                          targetPixelFormat: MTLPixelFormat) -> CVMetalTexture? {
        let pixelBuffer = frame.pixelBuffer
        let formatType = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let (cvTexture, sourceKind): (CVMetalTexture, SourceKind)
        switch formatType {
        case kCVPixelFormatType_32BGRA:
            guard let tex = makeMetalTexture(pixelBuffer: pixelBuffer,
                                             format: .bgra8Unorm,
                                             planeIndex: 0) else {
                return nil
            }
            cvTexture = tex
            sourceKind = .bgra
        case kCVPixelFormatType_422YpCbCr8:
            // HITL-verify: .gbgr422 matches the '2vuy' UYVY layout on
            // Apple Silicon's CVMetalTextureCache decode path. If
            // colors look swapped on iPad, flip to .bgrg422 — the
            // shader math (sample.r=Y, .g=Cb, .b=Cr) is unchanged.
            guard let tex = makeMetalTexture(pixelBuffer: pixelBuffer,
                                             format: .gbgr422,
                                             planeIndex: 0) else {
                return nil
            }
            cvTexture = tex
            sourceKind = .uyvy
        default:
            // Unsupported FourCC: no geometry → cleared black shows.
            return nil
        }

        guard let metalTexture = CVMetalTextureGetTexture(cvTexture),
              let pipelineState = pipeline(for: sourceKind, targetPixelFormat: targetPixelFormat) else {
            return nil
        }

        let rect = Self.aspectFitNDCRect(srcWidth: frame.width,
                                         srcHeight: frame.height,
                                         targetWidth: targetWidth,
                                         targetHeight: targetHeight,
                                         side: side)
        var verts = Self.quadVertices(for: rect)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&verts,
                               length: MemoryLayout<SbSVertex>.stride * verts.count,
                               index: 0)
        encoder.setFragmentTexture(metalTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: verts.count)
        return cvTexture
    }

    private enum SourceKind {
        case bgra
        case uyvy
    }

    private struct PipelineKey: Hashable {
        let sourceKind: SourceKind
        let targetFormatRaw: UInt
    }

    private func pipeline(for sourceKind: SourceKind,
                          targetPixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = PipelineKey(sourceKind: sourceKind,
                              targetFormatRaw: targetPixelFormat.rawValue)
        if let cached = pipelineCache[key] {
            return cached
        }
        let fragment: MTLFunction
        switch sourceKind {
        case .bgra: fragment = fragmentBGRA
        case .uyvy: fragment = fragmentUYVY
        }
        do {
            let pipeline = try Self.makePipeline(device: device,
                                                 vertex: vertexFunction,
                                                 fragment: fragment,
                                                 vertexDescriptor: vertexDescriptor,
                                                 targetPixelFormat: targetPixelFormat)
            pipelineCache[key] = pipeline
            return pipeline
        } catch {
            return nil
        }
    }

    private func makeMetalTexture(pixelBuffer: CVPixelBuffer,
                                  format: MTLPixelFormat,
                                  planeIndex: Int) -> CVMetalTexture? {
        let width: Int
        let height: Int
        if CVPixelBufferIsPlanar(pixelBuffer) {
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        } else {
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
        }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            return nil
        }
        return cvTexture
    }

    // MARK: - Vertex types & helpers

    fileprivate struct SbSVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    fileprivate struct NDCRect {
        var xMin: Float
        var xMax: Float
        var yMin: Float
        var yMax: Float
    }

    fileprivate static func aspectFitNDCRect(srcWidth: Int,
                                             srcHeight: Int,
                                             targetWidth: Int,
                                             targetHeight: Int,
                                             side: Side) -> NDCRect {
        let halfWidthPx = Float(targetWidth) / 2
        let targetHeightPx = Float(targetHeight)
        let srcW = Float(max(srcWidth, 1))
        let srcH = Float(max(srcHeight, 1))

        let scale = min(halfWidthPx / srcW, targetHeightPx / srcH)
        let fitW = srcW * scale
        let fitH = srcH * scale

        let localX = (halfWidthPx - fitW) / 2
        let localY = (targetHeightPx - fitH) / 2

        let originX: Float
        switch side {
        case .left: originX = -1
        case .right: originX = 0
        }

        let xMin = originX + localX / halfWidthPx
        let xMax = originX + (localX + fitW) / halfWidthPx
        // NDC y is +1 at top, -1 at bottom. Pixel y is 0 at top.
        let yMax = 1 - 2 * (localY / targetHeightPx)
        let yMin = 1 - 2 * ((localY + fitH) / targetHeightPx)
        return NDCRect(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax)
    }

    fileprivate static func quadVertices(for rect: NDCRect) -> [SbSVertex] {
        // Triangle strip: TL, BL, TR, BR. UV (0,0) at top-left to match
        // the CVPixelBuffer's top-down coordinate convention.
        return [
            SbSVertex(position: SIMD2(rect.xMin, rect.yMax), uv: SIMD2(0, 0)),
            SbSVertex(position: SIMD2(rect.xMin, rect.yMin), uv: SIMD2(0, 1)),
            SbSVertex(position: SIMD2(rect.xMax, rect.yMax), uv: SIMD2(1, 0)),
            SbSVertex(position: SIMD2(rect.xMax, rect.yMin), uv: SIMD2(1, 1)),
        ]
    }

    private static func loadFunction(library: MTLLibrary, name: String) throws -> MTLFunction {
        guard let fn = library.makeFunction(name: name) else {
            throw Error.shaderFunctionMissing(name)
        }
        return fn
    }

    private static func makeVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<SbSVertex>.stride
        vd.layouts[0].stepRate = 1
        vd.layouts[0].stepFunction = .perVertex
        return vd
    }

    private static func makePipeline(device: MTLDevice,
                                     vertex: MTLFunction,
                                     fragment: MTLFunction,
                                     vertexDescriptor: MTLVertexDescriptor,
                                     targetPixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = targetPixelFormat
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Error.pipelineCreationFailed(error)
        }
    }
}
