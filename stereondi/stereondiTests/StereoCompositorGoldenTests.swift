//  StereoCompositorGoldenTests.swift
//
//  One reference golden: zero-HIT SbS of two synthetic gradient pixel
//  buffers (red on the left, blue on the right). Renders into a
//  1920×1080 BGRA Metal texture, reads it back, then either
//
//    - compares against the bundled reference PNG (default), or
//    - rewrites the reference PNG (when STEREONDI_UPDATE_GOLDENS=1).
//
//  The first test run on a developer Mac will fail with
//  GoldenImageError.missingReference; that's the cue to set
//  STEREONDI_UPDATE_GOLDENS=1 once and re-run to seed the reference.
//
//  See stereondiTests/Goldens/README.md for the workflow.

import CoreGraphics
import Foundation
import Metal
import Testing
@testable import stereondi

@MainActor
struct StereoCompositorGoldenTests {

    @Test
    func zeroHitSbSGradientPair() throws {
        let device = try MetalRenderUtilities.makeDevice()
        let queue = try MetalRenderUtilities.makeCommandQueue(device: device)
        let target = try MetalRenderUtilities.makeRenderTarget(device: device)

        let leftPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .red)
        let rightPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .blue)

        let leftFrame = StubVideoFrame(pixelBuffer: leftPB)
        let rightFrame = StubVideoFrame(pixelBuffer: rightPB)

        let compositor = try StereoCompositor(device: device)
        let pair = StereoFramePair(left: leftFrame, right: rightFrame, hostTime: 0)

        let commandBuffer = try #require(queue.makeCommandBuffer())
        compositor.render(pair: pair, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let candidate = try MetalRenderUtilities.readBackImage(texture: target)

        if ProcessInfo.processInfo.environment["STEREONDI_UPDATE_GOLDENS"] == "1" {
            let dir = goldensDirectory()
            try GoldenImage.write(candidate,
                                  named: "sbs_zero_hit_gradient",
                                  toDirectory: dir)
            print("STEREONDI_UPDATE_GOLDENS=1 → wrote sbs_zero_hit_gradient.png to \(dir.path)")
            return
        }

        let reference = try GoldenImage.loadReference(named: "sbs_zero_hit_gradient")
        let result = GoldenImage.compare(candidate,
                                         against: reference,
                                         tolerance: 0.02)
        #expect(result.passed,
                "Golden mismatch: worstΔ=\(result.worstChannelDiff), failingPixels=\(result.failingPixelCount)/\(result.totalPixelCount)")
    }

    /// Resolve the Goldens directory from `#filePath` so an
    /// STEREONDI_UPDATE_GOLDENS=1 run lands a fresh PNG in
    /// `stereondiTests/Goldens/` of the live checkout regardless of
    /// where Xcode wrote the test bundle.
    private func goldensDirectory(file: StaticString = #filePath) -> URL {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let testDir = testFileURL.deletingLastPathComponent()
        return testDir.appendingPathComponent("Goldens", isDirectory: true)
    }
}
