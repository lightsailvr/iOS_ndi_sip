//  StereoCompositor.swift
//
//  Stereo compositor with split screen and sender pipelines (slice #8).
//  Shared upstream: per-eye CVMetalTexture cache lookup +
//  AlignmentMath uniform calculation. Two final-stage entry points
//  diverge from there:
//   - `renderScreen(...)` honors `alignment.screenMode` and dispatches
//     to the SbS, anaglyph, or channel-test draw path.
//   - `renderForSender(...)` is hard-wired to SbS regardless of
//     screenMode so the Quest viewer's stream stays uninterrupted
//     while the operator iterates between alignment views.
//
//  SbS draws each eye as an aspect-fit half via a per-side triangle
//  strip; the fragment shader maps destination UV ∈ [0,1] into the
//  HIT-translated source-UV window the CPU computed via
//  AlignmentMath.uvWindow. The hardware bilinear filter on the source
//  sampler delivers sub-pixel sampling for free, which is how HIT
//  achieves its 0.1 px specified resolution.
//
//  Anaglyph draws a single full-frame quad and samples both sources
//  in one fragment invocation via per-side AnaglyphSideUniforms (the
//  `decodeMode` field selects BGRA vs UYVY decode per side, so a
//  single anaglyph pipeline covers all source-format permutations).
//  Channel-test draws a full-frame quad and bypasses sources entirely.
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
//  Slice #8 split: there are now two final-stage render entry points
//  sharing the upstream per-eye CVMetalTexture cache + alignment
//  uniform calculation:
//   - `renderScreen(...)` honors `alignment.screenMode` (.sbs /
//     .anaglyph / .channelTest). The iPad operator's preview.
//   - `renderForSender(...)` is always SbS regardless of
//     `screenMode`. The Quest viewer's stream is uninterrupted.
//  The legacy `render(...)` is preserved as a wrapper that calls
//  `renderScreen(...)` so any external caller still compiles. The
//  pipeline cache now keys on `(SourceKind, Mode, target pixelFormat)`
//  so the .sbs / .anaglyph / .channelTest pipelines coexist for both
//  the MTKView's `.bgra8Unorm` drawable and the test target's
//  offscreen render target.
//
//  The MTLTexture handed to renderScreen() is owned by the caller
//  (typically an MTKView's currentDrawable). We do not present or
//  commit; the caller does.

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

    /// Per-side payload for the anaglyph fragment shader. Layout MUST
    /// stay in sync with `AnaglyphSideUniforms` in `Compositor.metal`.
    /// `decodeMode` is 0 for BGRA sources, 1 for UYVY (.bgrg422). The
    /// destination subrect is in full-frame UV space (origin top-left,
    /// (0,0) → (1,1)) and identifies where this source's aspect-fit
    /// lives within the full anaglyph output.
    struct AnaglyphSideUniforms: Sendable {
        var dstUVxMin: Float
        var dstUVxMax: Float
        var dstUVyMin: Float
        var dstUVyMax: Float
        var uMin: Float
        var uMax: Float
        var decodeMode: UInt32
        var padding: UInt32 = 0
    }

    struct AnaglyphUniforms: Sendable {
        var redSide: AnaglyphSideUniforms
        var cyanSide: AnaglyphSideUniforms
    }

    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let fullFrameVertex: MTLFunction
    private let fragmentBGRA: MTLFunction
    private let fragmentUYVY: MTLFunction
    private let fragmentAnaglyph: MTLFunction
    private let fragmentChannelTest: MTLFunction
    private let vertexDescriptor: MTLVertexDescriptor
    private let textureCache: CVMetalTextureCache

    // (sourceKind, mode, targetPixelFormat) → pipeline. Built lazily so
    // the compositor adapts to both .bgra8Unorm (MTKView default) and
    // .bgra8Unorm_srgb (golden-image test target) without the caller
    // having to pre-declare which. Slice #8 adds Mode (.sbs / .anaglyph
    // / .channelTest) so the screen pipeline can carry all three
    // simultaneously while the sender's .sbs entry remains unchanged.
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
        self.fullFrameVertex = try Self.loadFunction(library: library, name: "fullframe_vertex")
        self.fragmentBGRA = try Self.loadFunction(library: library, name: "sbs_fragment_bgra")
        self.fragmentUYVY = try Self.loadFunction(library: library, name: "sbs_fragment_uyvy")
        self.fragmentAnaglyph = try Self.loadFunction(library: library, name: "fragment_anaglyph")
        self.fragmentChannelTest = try Self.loadFunction(library: library, name: "fragment_channeltest")
        self.vertexDescriptor = Self.makeVertexDescriptor()

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw Error.textureCacheCreationFailed(status)
        }
        self.textureCache = cache
    }

    /// Render the iPad screen composite of `pair` into `target` using
    /// `alignment` for per-eye HIT + crop and `alignment.screenMode`
    /// for the final stage (.sbs / .anaglyph / .channelTest). The
    /// target's loadAction is .clear (black); a nil pair (or nil eye)
    /// in SbS draws no geometry for that half so the cleared black
    /// shows through. In anaglyph, a missing source contributes 0 to
    /// its channel(s); channel-test bypasses sources entirely.
    ///
    /// `alignment` is read fresh per call — the compositor never
    /// caches values from prior frames, so a slider drag or a
    /// two-finger pan reflects in the very next rendered frame.
    func renderScreen(pair: StereoFramePair,
                      alignment: AlignmentState,
                      into target: MTLTexture,
                      commandBuffer: MTLCommandBuffer) {
        switch alignment.screenMode {
        case .sbs:
            renderSbS(pair: pair, alignment: alignment, into: target, commandBuffer: commandBuffer)
        case .anaglyph:
            renderAnaglyph(pair: pair, alignment: alignment, into: target, commandBuffer: commandBuffer)
        case .channelTest:
            renderChannelTest(into: target, commandBuffer: commandBuffer)
        }
    }

    /// Backwards-compat wrapper for callers written before the slice-#8
    /// split. Routes through `renderScreen(...)` so external behavior is
    /// preserved (the wrapper honors `alignment.screenMode`).
    @available(*, deprecated, renamed: "renderScreen(pair:alignment:into:commandBuffer:)")
    func render(pair: StereoFramePair,
                alignment: AlignmentState,
                into target: MTLTexture,
                commandBuffer: MTLCommandBuffer) {
        renderScreen(pair: pair, alignment: alignment, into: target, commandBuffer: commandBuffer)
    }

    /// Render the SbS composite of `pair` into the compositor's owned
    /// 1920×1080 offscreen BGRA target and return that texture. ALWAYS
    /// SbS regardless of `alignment.screenMode` — the NDI-output
    /// pipeline is mode-agnostic so the Quest viewer's stream stays
    /// uninterrupted while the operator iterates between alignment
    /// views (PRD user story 17 + 30). The caller appends a
    /// UYVY-encode compute pass on the same command buffer and reads
    /// the result back via a completion handler. Returns nil if the
    /// offscreen target couldn't be allocated.
    func renderForSender(pair: StereoFramePair,
                         alignment: AlignmentState,
                         commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let target = ensureSenderTarget() else {
            return nil
        }
        renderSbS(pair: pair, alignment: alignment, into: target, commandBuffer: commandBuffer)
        return target
    }

    // MARK: - Mode dispatch

    private func renderSbS(pair: StereoFramePair,
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
           let drawn = drawSbSSide(encoder: encoder,
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
           let drawn = drawSbSSide(encoder: encoder,
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

    private func renderAnaglyph(pair: StereoFramePair,
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

        let leftHIT = alignment.leftHIT
        let rightHIT = alignment.rightHIT
        let cropMode = alignment.cropMode
        let swap = alignment.swapEyes

        // Resolve the per-eye sampled textures. If a source is missing
        // we still need a valid texture binding for the shader, so we
        // fall back to the "other" eye's resolved texture and mark its
        // destination subrect as empty (uMin == uMax, dst zero-area)
        // so its sample contribution is 0.
        let resolvedLeft = pair.left.flatMap { resolveSource($0) }
        let resolvedRight = pair.right.flatMap { resolveSource($0) }

        guard resolvedLeft != nil || resolvedRight != nil else {
            encoder.endEncoding()
            return
        }

        // The two source slots in the anaglyph shader are: red_source
        // (luma → red), cyan_source (luma → green+blue). Default
        // mapping is left → red, right → cyan; swap-eyes inverts.
        let redResolved   = swap ? resolvedRight : resolvedLeft
        let redHIT        = swap ? rightHIT : leftHIT
        let redOtherHIT   = swap ? leftHIT : rightHIT
        let redOtherWidth = swap ? pair.left?.width : pair.right?.width

        let cyanResolved   = swap ? resolvedLeft : resolvedRight
        let cyanHIT        = swap ? leftHIT : rightHIT
        let cyanOtherHIT   = swap ? rightHIT : leftHIT
        let cyanOtherWidth = swap ? pair.right?.width : pair.left?.width

        let redSide = anaglyphSideUniforms(resolved: redResolved,
                                           hit: redHIT,
                                           otherHit: redOtherHIT,
                                           otherWidth: redOtherWidth,
                                           cropMode: cropMode,
                                           targetWidth: target.width,
                                           targetHeight: target.height,
                                           side: .left)
        let cyanSide = anaglyphSideUniforms(resolved: cyanResolved,
                                            hit: cyanHIT,
                                            otherHit: cyanOtherHIT,
                                            otherWidth: cyanOtherWidth,
                                            cropMode: cropMode,
                                            targetWidth: target.width,
                                            targetHeight: target.height,
                                            side: .right)

        guard let pipelineState = pipeline(for: nil,
                                           mode: .anaglyph,
                                           targetPixelFormat: target.pixelFormat) else {
            encoder.endEncoding()
            return
        }

        // Both texture slots must be bound — the shader samples both
        // unconditionally. If one source is missing we bind the other
        // resolved texture into both slots; the missing side's
        // dst-subrect is zero-area so its luma contribution is 0.
        let redTexture: MTLTexture? = redResolved?.texture ?? cyanResolved?.texture
        let cyanTexture: MTLTexture? = cyanResolved?.texture ?? redResolved?.texture
        guard let redTexture, let cyanTexture else {
            encoder.endEncoding()
            return
        }

        var verts = Self.fullFrameQuadVertices()
        var uniforms = AnaglyphUniforms(redSide: redSide, cyanSide: cyanSide)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&verts,
                               length: MemoryLayout<SbSVertex>.stride * verts.count,
                               index: 0)
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<AnaglyphUniforms>.stride,
                                 index: 0)
        encoder.setFragmentTexture(redTexture, index: 0)
        encoder.setFragmentTexture(cyanTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: verts.count)
        encoder.endEncoding()

        var inflight: [CVMetalTexture] = []
        if let cv = redResolved?.cvTexture { inflight.append(cv) }
        if let cv = cyanResolved?.cvTexture { inflight.append(cv) }
        if !inflight.isEmpty {
            commandBuffer.addCompletedHandler { _ in
                _ = inflight
            }
        }
    }

    private func renderChannelTest(into target: MTLTexture,
                                   commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }

        guard let pipelineState = pipeline(for: nil,
                                           mode: .channelTest,
                                           targetPixelFormat: target.pixelFormat) else {
            encoder.endEncoding()
            return
        }

        var verts = Self.fullFrameQuadVertices()
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&verts,
                               length: MemoryLayout<SbSVertex>.stride * verts.count,
                               index: 0)
        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: verts.count)
        encoder.endEncoding()
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
    private func drawSbSSide(encoder: MTLRenderCommandEncoder,
                             frame: any VideoFrameSource,
                             side: Side,
                             hitPixels: Double,
                             otherHitPixels: Double,
                             otherFrameWidth: Int?,
                             cropMode: CropMode,
                             targetWidth: Int,
                             targetHeight: Int,
                             targetPixelFormat: MTLPixelFormat) -> CVMetalTexture? {
        guard let resolved = resolveSource(frame) else {
            return nil
        }
        guard let pipelineState = pipeline(for: resolved.sourceKind,
                                           mode: .sbs,
                                           targetPixelFormat: targetPixelFormat) else {
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
        encoder.setFragmentTexture(resolved.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: verts.count)
        return resolved.cvTexture
    }

    /// Per-eye anaglyph uniforms. The destination subrect is the same
    /// aspect-fit subrect SbS uses for that side, but expressed in
    /// full-frame UV (origin top-left) so a single full-frame quad can
    /// cover the output. The (uMin, uMax) sampling window matches the
    /// SbS path's HIT/crop math exactly so anaglyph and SbS share the
    /// same sub-pixel HIT correctness.
    ///
    /// `resolved == nil` (single-source case) returns a zero-area
    /// destination subrect so the shader's bounds check zeroes out
    /// this side's luma contribution.
    private func anaglyphSideUniforms(resolved: ResolvedSource?,
                                      hit: Double,
                                      otherHit: Double,
                                      otherWidth: Int?,
                                      cropMode: CropMode,
                                      targetWidth: Int,
                                      targetHeight: Int,
                                      side: Side) -> AnaglyphSideUniforms {
        guard let resolved else {
            return AnaglyphSideUniforms(dstUVxMin: 0, dstUVxMax: 0,
                                        dstUVyMin: 0, dstUVyMax: 0,
                                        uMin: 0, uMax: 0,
                                        decodeMode: 0)
        }

        let alignmentU = Self.alignmentUniforms(forSideHITPixels: hit,
                                                otherSideHITPixels: otherHit,
                                                sourceWidthPixels: resolved.width,
                                                otherSourceWidthPixels: otherWidth,
                                                cropMode: cropMode)

        // Anaglyph outputs over the FULL frame, not split halves, so
        // the destination is the entire output rect (UV 0..1) — but
        // we still aspect-fit the source within that full rect so a
        // 16:9 source on a 16:9 target fills it edge-to-edge, while a
        // 4:3 source pillar-boxes. (PRD: "matching the existing
        // aspect-fit math you'd otherwise apply to a half — but here
        // both sources fill the same full output rect.")
        let subrect = Self.aspectFitFullFrameUVRect(srcWidth: resolved.width,
                                                    srcHeight: resolved.height,
                                                    targetWidth: targetWidth,
                                                    targetHeight: targetHeight)
        _ = side
        let decode: UInt32 = (resolved.sourceKind == .uyvy) ? 1 : 0
        return AnaglyphSideUniforms(dstUVxMin: subrect.xMin,
                                    dstUVxMax: subrect.xMax,
                                    dstUVyMin: subrect.yMin,
                                    dstUVyMax: subrect.yMax,
                                    uMin: alignmentU.uMin,
                                    uMax: alignmentU.uMax,
                                    decodeMode: decode)
    }

    /// Per-frame source resolution: CVPixelBuffer → MTLTexture via
    /// the cache, plus the source-kind tag the pipeline cache keys on.
    /// Returned together so the SbS and anaglyph paths share one
    /// resolution path.
    private struct ResolvedSource {
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
        let sourceKind: SourceKind
        let width: Int
        let height: Int
    }

    private func resolveSource(_ frame: any VideoFrameSource) -> ResolvedSource? {
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

        guard let metalTexture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return ResolvedSource(cvTexture: cvTexture,
                              texture: metalTexture,
                              sourceKind: sourceKind,
                              width: frame.width,
                              height: frame.height)
    }

    private enum SourceKind: Hashable {
        case bgra
        case uyvy
    }

    /// Final-stage compositor mode. Drives both pipeline-cache keying
    /// and the dispatch in `renderScreen(...)`. The sender pipeline
    /// is hard-wired to `.sbs` and never sees the others.
    enum Mode: Hashable {
        case sbs
        case anaglyph
        case channelTest
    }

    /// `sourceKind` is `nil` for modes that don't sample a textured
    /// source (`.anaglyph`'s shader is the same regardless of the two
    /// sources' formats — decode is per-side via the uniform's
    /// `decodeMode` field; `.channelTest` doesn't sample at all).
    private struct PipelineKey: Hashable {
        let sourceKind: SourceKind?
        let mode: Mode
        let targetFormatRaw: UInt
    }

    private func pipeline(for sourceKind: SourceKind?,
                          mode: Mode,
                          targetPixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = PipelineKey(sourceKind: sourceKind,
                              mode: mode,
                              targetFormatRaw: targetPixelFormat.rawValue)
        if let cached = pipelineCache[key] {
            return cached
        }
        let vertex: MTLFunction
        let fragment: MTLFunction
        switch mode {
        case .sbs:
            vertex = vertexFunction
            switch sourceKind {
            case .bgra: fragment = fragmentBGRA
            case .uyvy: fragment = fragmentUYVY
            case .none: return nil
            }
        case .anaglyph:
            vertex = fullFrameVertex
            fragment = fragmentAnaglyph
        case .channelTest:
            vertex = fullFrameVertex
            fragment = fragmentChannelTest
        }
        do {
            let pipeline = try Self.makePipeline(device: device,
                                                 vertex: vertex,
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

    /// Full-frame triangle-strip quad covering NDC (-1,-1)→(+1,+1)
    /// with UV (0,0)→(1,1). Used by anaglyph and channel-test (single
    /// draw call covering the full output).
    fileprivate static func fullFrameQuadVertices() -> [SbSVertex] {
        return [
            SbSVertex(position: SIMD2(-1,  1), uv: SIMD2(0, 0)),
            SbSVertex(position: SIMD2(-1, -1), uv: SIMD2(0, 1)),
            SbSVertex(position: SIMD2( 1,  1), uv: SIMD2(1, 0)),
            SbSVertex(position: SIMD2( 1, -1), uv: SIMD2(1, 1)),
        ]
    }

    /// Aspect-fit subrect in full-frame UV space (0..1, top-left
    /// origin) for a single source filling the FULL output rect (not
    /// a side-by-side half). Anaglyph uses this so a 16:9 source on a
    /// 16:9 target fills edge-to-edge while a 4:3 source pillar-boxes.
    fileprivate static func aspectFitFullFrameUVRect(srcWidth: Int,
                                                     srcHeight: Int,
                                                     targetWidth: Int,
                                                     targetHeight: Int) -> UVRect {
        let targetW = Float(max(targetWidth, 1))
        let targetH = Float(max(targetHeight, 1))
        let srcW = Float(max(srcWidth, 1))
        let srcH = Float(max(srcHeight, 1))

        let scale = min(targetW / srcW, targetH / srcH)
        let fitW = srcW * scale
        let fitH = srcH * scale

        let xMin = (targetW - fitW) / 2 / targetW
        let yMin = (targetH - fitH) / 2 / targetH
        let xMax = (targetW - fitW) / 2 / targetW + fitW / targetW
        let yMax = (targetH - fitH) / 2 / targetH + fitH / targetH
        return UVRect(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax)
    }

    fileprivate struct UVRect {
        var xMin: Float
        var xMax: Float
        var yMin: Float
        var yMax: Float
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
