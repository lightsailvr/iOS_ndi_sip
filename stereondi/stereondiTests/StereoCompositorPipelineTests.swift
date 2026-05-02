//  StereoCompositorPipelineTests.swift
//
//  Slice #8: verifies the screen pipeline and the sender pipeline are
//  truly independent. With `alignment.screenMode = .anaglyph` and a
//  red-left / blue-right gradient pair:
//
//   - `renderScreen(...)` produces an anaglyph output (red channel
//     dominant on one side from the left source's luma; cyan
//     channels dominant from the right source's luma).
//   - `renderForSender(...)` STILL produces an SbS output (a
//     red gradient on the left half, a blue gradient on the right
//     half) regardless of the screenMode setting.
//
//  This is the slice's load-bearing acceptance criterion: the Quest
//  viewer's stream stays uninterrupted while the operator iterates
//  between alignment views on the iPad. We test it directly rather
//  than relying on the source-code shape, so a future refactor that
//  routed both paths through the same mode-aware render call would
//  still trip this test.
//
//  Gated on `MTLCreateSystemDefaultDevice() != nil` so the test
//  target exits cleanly on Linux CI.

import CoreVideo
import Foundation
import Metal
import Testing
@testable import stereondi

@MainActor
struct StereoCompositorPipelineTests {

    /// In `screenMode == .anaglyph`, `renderForSender(...)` ignores
    /// the screen mode and produces SbS. We assert this by sampling
    /// representative pixels in the sender output: a pixel near the
    /// left half's center should be red-dominant (from the left
    /// source's red gradient), and a pixel near the right half's
    /// center should be blue-dominant (from the right source's blue
    /// gradient). An anaglyph output would instead have BOTH halves
    /// reading red+cyan from the combined luma, so this assertion
    /// would fail if `renderForSender` accidentally branched on
    /// screenMode.
    @Test
    func renderForSenderIgnoresAnaglyphScreenMode() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on this host; skipping sender-vs-screen test.")
            return
        }
        let queue = try MetalRenderUtilities.makeCommandQueue(device: device)

        let leftPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .red)
        let rightPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .blue)

        let pair = StereoFramePair(left: StubVideoFrame(pixelBuffer: leftPB),
                                   right: StubVideoFrame(pixelBuffer: rightPB),
                                   hostTime: 0)

        let alignment = AlignmentState()
        alignment.screenMode = .anaglyph

        let compositor = try StereoCompositor(device: device)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let senderTexture = try #require(compositor.renderForSender(pair: pair,
                                                                    alignment: alignment,
                                                                    commandBuffer: commandBuffer))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // The sender target is .private storage; round-trip through a
        // .shared texture so we can read back the bytes.
        let blitTarget = try MetalRenderUtilities.makeRenderTarget(
            device: device,
            width: senderTexture.width,
            height: senderTexture.height,
            pixelFormat: senderTexture.pixelFormat
        )
        let blitBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(blitBuffer.makeBlitCommandEncoder())
        blit.copy(from: senderTexture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: senderTexture.width,
                                      height: senderTexture.height,
                                      depth: 1),
                  to: blitTarget,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        blitBuffer.commit()
        blitBuffer.waitUntilCompleted()

        // Sample two pixels: one in the left half's interior, one in
        // the right half's interior. SbS layout means the left-half
        // sample is sourcing the red gradient (B≈0, R>>0) and the
        // right-half sample is sourcing the blue gradient (R≈0, B>>0).
        let leftSample = readBGRA(from: blitTarget,
                                  x: blitTarget.width / 4,
                                  y: blitTarget.height / 2)
        let rightSample = readBGRA(from: blitTarget,
                                   x: 3 * blitTarget.width / 4,
                                   y: blitTarget.height / 2)

        // Left-half pixel: red-dominant.
        #expect(Int(leftSample.r) > Int(leftSample.b) + 32,
                "Sender left-half pixel should be red-dominant (SbS), got bgra=\(leftSample)")
        #expect(Int(leftSample.r) > Int(leftSample.g) + 32,
                "Sender left-half pixel should have R > G (SbS), got bgra=\(leftSample)")

        // Right-half pixel: blue-dominant.
        #expect(Int(rightSample.b) > Int(rightSample.r) + 32,
                "Sender right-half pixel should be blue-dominant (SbS), got bgra=\(rightSample)")
        #expect(Int(rightSample.b) > Int(rightSample.g) + 32,
                "Sender right-half pixel should have B > G (SbS), got bgra=\(rightSample)")
    }

    /// Companion: with `screenMode = .anaglyph`, `renderScreen(...)`
    /// produces a pure-luma red/cyan anaglyph — the LEFT source's
    /// luma drives the red channel (so a sample near where the left
    /// source's brightest red pixels land has high red), and the
    /// RIGHT source's luma drives the green+blue channels (which is
    /// "cyan" in additive mixing). We deliberately don't compare
    /// against a golden here — that's `StereoCompositorGoldenTests`'s
    /// job — we just confirm the qualitative anaglyph signature.
    @Test
    func renderScreenAnaglyphProducesRedCyanComposite() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on this host; skipping anaglyph-shape test.")
            return
        }
        let queue = try MetalRenderUtilities.makeCommandQueue(device: device)
        let target = try MetalRenderUtilities.makeRenderTarget(device: device)

        let leftPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .red)
        let rightPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .blue)

        let pair = StereoFramePair(left: StubVideoFrame(pixelBuffer: leftPB),
                                   right: StubVideoFrame(pixelBuffer: rightPB),
                                   hostTime: 0)

        let alignment = AlignmentState()
        alignment.screenMode = .anaglyph

        let compositor = try StereoCompositor(device: device)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        compositor.renderScreen(pair: pair,
                                alignment: alignment,
                                into: target,
                                commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // With BT.709 luma weights, a fully-saturated red source
        // contributes Y=0.2126 and a fully-saturated blue source
        // contributes Y=0.0722 — both anti-correlated with the
        // gradient's left→right brightness ramp. At the right edge
        // of the output, both sources read at their brightest
        // gradient-step, so the output's red channel ≈ 0.2126*1 ≈ 54
        // and the green+blue channels ≈ 0.0722*1 ≈ 18.
        let nearRightEdge = readBGRA(from: target,
                                     x: target.width - 4,
                                     y: target.height / 2)
        // Anaglyph signature: R > 0, G == B (luma-driven cyan).
        #expect(Int(nearRightEdge.r) > 32,
                "Anaglyph output should have R > 0 from left luma; got \(nearRightEdge)")
        #expect(abs(Int(nearRightEdge.g) - Int(nearRightEdge.b)) <= 2,
                "Anaglyph output should have G == B (pure cyan); got \(nearRightEdge)")
    }

    // MARK: - Read helpers

    private struct BGRA: CustomStringConvertible {
        let b: UInt8
        let g: UInt8
        let r: UInt8
        let a: UInt8
        var description: String { "(B:\(b) G:\(g) R:\(r) A:\(a))" }
    }

    private func readBGRA(from texture: MTLTexture, x: Int, y: Int) -> BGRA {
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBufferPointer { ptr in
            texture.getBytes(ptr.baseAddress!,
                             bytesPerRow: 4,
                             from: MTLRegionMake2D(x, y, 1, 1),
                             mipmapLevel: 0)
        }
        return BGRA(b: pixel[0], g: pixel[1], r: pixel[2], a: pixel[3])
    }
}
