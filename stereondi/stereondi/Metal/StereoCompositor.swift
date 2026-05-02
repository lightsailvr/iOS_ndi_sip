//  StereoCompositor.swift
//
//  Stereo SbS compositor. Each per-eye draw call covers an aspect-fit
//  half of the target with a triangle strip; the fragment shader maps
//  destination UV ∈ [0,1] into the auto-crop "common region" of source
//  UV ∈ [0,1]. The hardware bilinear filter on the source sampler
//  delivers sub-pixel sampling for free, which is how HIT achieves its
//  0.1 px specified resolution.
//
//  Two pipelines because UYVY and BGRA need different fragment shaders
//  (UYVY samples through the bgrg422-format hardware chroma upsampler
//  and decodes BT.709 limited-range in-shader). Pipeline selection is
//  per-side; the operator can mix BGRA and UYVY sources for free.
//
//  Slice #6 additions:
//   - `AlignmentUniforms` carries (u_min, u_max) per side. The shader
//     samples `dst_uv.x → u_min + dst_uv.x * (u_max - u_min)`.
//   - The CPU computes (u_min, u_max) per eye by combining the eye's
//     own HIT offset (in source pixels → normalized U) with the
//     "common region" crop amount, which is `max(|leftHIT|, |rightHIT|)`
//     normalized by source width.
//
//  Slice #7 additions:
//   - `AlignmentState.cropMode` (.auto / .off) is threaded through
//     `alignmentUniforms(...)` into the per-side `(uMin, uMax)`. With
//     `.auto` the slice-#6 common-region math runs; with `.off` the
//     window is exactly `[hitUV, hitUV + 1]` and the shader's
//     `uv_outside_source` check produces visible black bars on the
//     missing-edge of one half.
//   - The trailing-padding slot in `AlignmentUniforms` is renamed
//     `cropModeFlag` (0 = auto, 1 = off). The shader does not
//     currently branch on it — the CPU has already done the right
//     `(uMin, uMax)` math — but it's wired through so future shader
//     work (anaglyph mode-specific behavior, telemetry overlays) can
//     read the active mode without an extra binding.
//
//  The MTLTexture handed to render() is owned by the caller (typically
//  an MTKView's currentDrawable). We do not present or commit; the
//  caller does.

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

    /// Per-side fragment-shader buffer-0 contents. Layout MUST stay in
    /// sync with the `AlignmentUniforms` struct in `Compositor.metal`.
    /// `cropModeFlag` is informational (0 = auto, 1 = off); the
    /// chosen mode is already baked into `(uMin, uMax)`. The trailing
    /// padding keeps the struct at a 16-byte SIMD-aligned size.
    struct AlignmentUniforms: Sendable {
        var uMin: Float
        var uMax: Float
        var cropModeFlag: Float = 0
        var padding: Float = 0
    }

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

    /// Render the SbS composite of `pair` into `target`, using `alignment`
    /// for per-eye HIT + auto-crop. The target's loadAction is .clear
    /// (black); a nil pair (or nil eye) draws no geometry for that
    /// half so the cleared black shows through.
    ///
    /// `alignment` is read fresh per call — the compositor never caches
    /// values from prior frames, so a slider drag or a two-finger pan
    /// reflects in the very next rendered frame.
    func render(pair: StereoFramePair,
                alignment: AlignmentState,
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

        // Snapshot the values once per frame. The reads still happen on
        // MainActor (this method is @MainActor) but capturing into
        // locals avoids repeated property accesses per side and makes
        // the common-region + crop-mode math obviously consistent
        // across eyes.
        let leftHIT = alignment.leftHIT
        let rightHIT = alignment.rightHIT
        let cropMode = alignment.cropMode

        // Hold CVMetalTextures alive until GPU completion. The MTLTexture
        // returned via CVMetalTextureGetTexture aliases the IOSurface
        // backing; if the CVMetalTexture wrapper is released before the
        // GPU is done sampling, the IOSurface can be recycled.
        var inflight: [CVMetalTexture] = []

        if let leftFrame = pair.left,
           let drawn = drawSide(encoder: encoder,
                                frame: leftFrame,
                                side: .left,
                                hitPixels: leftHIT,
                                otherHitPixels: rightHIT,
                                otherFrameWidth: pair.right?.width,
                                cropMode: cropMode,
                                targetWidth: target.width,
                                targetHeight: target.height,
                                targetPixelFormat: target.pixelFormat) {
            inflight.append(drawn)
        }

        if let rightFrame = pair.right,
           let drawn = drawSide(encoder: encoder,
                                frame: rightFrame,
                                side: .right,
                                hitPixels: rightHIT,
                                otherHitPixels: leftHIT,
                                otherFrameWidth: pair.left?.width,
                                cropMode: cropMode,
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
                         alignment: AlignmentState,
                         commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let target = ensureSenderTarget() else {
            return nil
        }
        render(pair: pair, alignment: alignment, into: target, commandBuffer: commandBuffer)
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

    /// Compute per-eye `(u_min, u_max, cropModeFlag)` in source-UV
    /// space. Delegates the math to the pure
    /// `AlignmentMath.uvWindow(...)` helper (so unit tests can exercise
    /// it without touching Metal) and packs the result into the GPU
    /// uniform layout.
    ///
    /// `.auto` mode samples a slice of width `1 − 2 × commonAbsUV`
    /// where `commonAbsUV = max(|leftHitUV|, |rightHitUV|)`, so the
    /// window stays inside `[0, 1]` and the operator sees no black
    /// bars regardless of HIT. `.off` mode samples exactly
    /// `[hitUV, hitUV + 1]`, letting the shader's out-of-source
    /// black-bar branch reveal what HIT is shifting.
    ///
    /// When both HITs are zero (either mode), the window collapses to
    /// `(0, 1)` — the slice-#4 zero-HIT golden continues to render
    /// byte-identical.
    ///
    /// `otherSourceWidthPixels: nil` (lone-eye case) falls back to
    /// this eye's width so the auto-crop math still produces a
    /// sensible window.
    nonisolated static func alignmentUniforms(forSideHITPixels hit: Double,
                                              otherSideHITPixels otherHit: Double,
                                              sourceWidthPixels: Int,
                                              otherSourceWidthPixels: Int?,
                                              cropMode: CropMode) -> AlignmentUniforms {
        let srcW = Double(max(sourceWidthPixels, 1))
        let otherW = Double(max(otherSourceWidthPixels ?? sourceWidthPixels, 1))
        let window = AlignmentMath.uvWindow(hitPixels: hit,
                                            otherHitPixels: otherHit,
                                            sourceWidthPixels: srcW,
                                            otherSourceWidthPixels: otherW,
                                            cropMode: cropMode)
        let flag: Float = (cropMode == .off) ? 1.0 : 0.0
        return AlignmentUniforms(uMin: Float(window.uMin),
                                 uMax: Float(window.uMax),
                                 cropModeFlag: flag)
    }

    @discardableResult
    private func drawSide(encoder: MTLRenderCommandEncoder,
                          frame: any VideoFrameSource,
                          side: Side,
                          hitPixels: Double,
                          otherHitPixels: Double,
                          otherFrameWidth: Int?,
                          cropMode: CropMode,
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

        var uniforms = Self.alignmentUniforms(forSideHITPixels: hitPixels,
                                              otherSideHITPixels: otherHitPixels,
                                              sourceWidthPixels: frame.width,
                                              otherSourceWidthPixels: otherFrameWidth,
                                              cropMode: cropMode)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&verts,
                               length: MemoryLayout<SbSVertex>.stride * verts.count,
                               index: 0)
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<AlignmentUniforms>.stride,
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
