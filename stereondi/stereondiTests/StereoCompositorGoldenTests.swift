//  StereoCompositorGoldenTests.swift
//
//  Reference goldens for the screen-pipeline compositor:
//
//   1. zero-HIT SbS gradient (slice #4 baseline) — `sbs_zero_hit_gradient.png`
//   2. +50 px convergence, AUTO crop — `sbs_hit_p50_crop_auto.png`
//   3. +50 px convergence, OFF  crop — `sbs_hit_p50_crop_off.png`
//   4. −50 px convergence (auto) — `sbs_hit_n50.png`
//   5. +200 px convergence (auto) — `sbs_hit_p200.png`
//   6. +0.3 px sub-pixel convergence (auto) — `sbs_hit_p0_3.png`
//   7. anaglyph at zero HIT — `anaglyph_zero_hit_gradient.png`
//   8. anaglyph at zero HIT, swap-eyes ON — `anaglyph_swapped_zero_hit_gradient.png`
//   9. channel test (sources nil) — `channel_test.png`
//
//  Each renders through `renderScreen(...)` (the new slice-#8 entry
//  point that honors `alignment.screenMode`) and either compares
//  against the bundled reference PNG (default) or rewrites it (when
//  STEREONDI_UPDATE_GOLDENS=1).
//
//  Slice #7 renames the slice-#6 `sbs_hit_p50.png` → `sbs_hit_p50_crop_auto.png`
//  (auto-crop was the implicit slice-#6 behavior) and adds the OFF
//  variant. Other slice-#6 goldens stay under their old names because
//  they're rendered with the default `.auto` mode.
//
//  Slice #8 adds the anaglyph + channel-test references. The SbS
//  goldens are unchanged — `renderScreen` with `screenMode == .sbs`
//  routes through the same SbS draw the slice-#4 path used.
//
//  The first test run on a developer Mac will fail with
//  GoldenImageError.missingReference for any unseeded golden — set
//  STEREONDI_UPDATE_GOLDENS=1 once and re-run to seed them.
//
//  See stereondiTests/Goldens/README.md for the workflow.

import CoreGraphics
import Foundation
import Metal
import Testing
@testable import stereondi

@MainActor
struct StereoCompositorGoldenTests {

    /// Per-test `AlignmentState` over a fresh UserDefaults suite so the
    /// slice-#11 SessionStore write-through can't pollute the standard
    /// suite during a Metal golden-image run.
    private static func freshAlignment() -> AlignmentState {
        let suite = UserDefaults(suiteName: "stereondi.tests.\(UUID().uuidString)")!
        return AlignmentState(store: SessionStore(defaults: suite))
    }

    @Test
    func zeroHitSbSGradientPair() throws {
        try renderAndCompare(named: "sbs_zero_hit_gradient", convergence: 0)
    }

    @Test
    func hitPositive50CropAuto() throws {
        try renderAndCompare(named: "sbs_hit_p50_crop_auto",
                             convergence: 50,
                             cropMode: .auto)
    }

    @Test
    func hitPositive50CropOff() throws {
        // OFF mode at +50 px convergence: each eye samples
        // [hitUV, hitUV + 1] of its source. The shader returns black
        // outside [0, 1], so a thin black bar appears on one edge of
        // each half (the right edge of the left eye, the left edge of
        // the right eye — both on the inside of the SbS pair).
        try renderAndCompare(named: "sbs_hit_p50_crop_off",
                             convergence: 50,
                             cropMode: .off)
    }

    @Test
    func hitNegative50() throws {
        try renderAndCompare(named: "sbs_hit_n50", convergence: -50)
    }

    @Test
    func hitPositive200() throws {
        try renderAndCompare(named: "sbs_hit_p200", convergence: 200)
    }

    @Test
    func hitSubPixel0_3() throws {
        try renderAndCompare(named: "sbs_hit_p0_3", convergence: 0.3)
    }

    // MARK: - Slice #8: anaglyph + channel-test

    @Test
    func anaglyphZeroHitGradient() throws {
        // Pure-luma red/cyan anaglyph at zero HIT. With a red-left /
        // blue-right gradient, the red channel of the output reads
        // luma(red) (which rises with the left source's gradient) and
        // the cyan channels read luma(blue) (which rises with the
        // right source's gradient). Both sources cover the FULL
        // output via aspect-fit, so a 16:9 1920×1080 target on a 16:9
        // 960×540 source fills edge-to-edge.
        try renderAndCompare(named: "anaglyph_zero_hit_gradient",
                             convergence: 0,
                             screenMode: .anaglyph)
    }

    @Test
    func anaglyphSwappedZeroHitGradient() throws {
        // Same inputs, swap-eyes ON: the red channel is now driven by
        // the right source's luma and the cyan channels by the left.
        // The output should be visibly different from the
        // non-swapped version (the red gradient runs the same
        // direction as the *blue* source rather than the *red*
        // source) — confirmed structurally by the difference of the
        // two PNGs once they're seeded on a Mac.
        try renderAndCompare(named: "anaglyph_swapped_zero_hit_gradient",
                             convergence: 0,
                             screenMode: .anaglyph,
                             swapEyes: true)
    }

    @Test
    func channelTest() throws {
        // Sources are intentionally nil — channel-test bypasses
        // sources entirely and outputs solid red on the left half,
        // solid cyan on the right half. The seeded reference PNG is
        // a 1920×1080 image that's exactly half (1, 0, 0, 1) and
        // half (0, 1, 1, 1).
        try renderAndCompareNoSources(named: "channel_test")
    }

    // MARK: - Test harness

    private func renderAndCompare(named referenceName: String,
                                  convergence: Double,
                                  cropMode: CropMode = .auto,
                                  screenMode: ScreenMode = .sbs,
                                  swapEyes: Bool = false) throws {
        let device = try MetalRenderUtilities.makeDevice()
        let queue = try MetalRenderUtilities.makeCommandQueue(device: device)
        let target = try MetalRenderUtilities.makeRenderTarget(device: device)

        let leftPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .red)
        let rightPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .blue)

        let leftFrame = StubVideoFrame(pixelBuffer: leftPB)
        let rightFrame = StubVideoFrame(pixelBuffer: rightPB)

        let alignment = Self.freshAlignment()
        alignment.convergence = convergence
        alignment.cropMode = cropMode
        alignment.screenMode = screenMode
        alignment.swapEyes = swapEyes

        let compositor = try StereoCompositor(device: device)
        let pair = StereoFramePair(left: leftFrame, right: rightFrame, hostTime: 0)

        let commandBuffer = try #require(queue.makeCommandBuffer())
        compositor.renderScreen(pair: pair,
                                alignment: alignment,
                                into: target,
                                commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        try compareOrSeed(target: target, named: referenceName)
    }

    /// Channel-test variant: no sources, no AlignmentState mutation
    /// beyond `screenMode = .channelTest`.
    private func renderAndCompareNoSources(named referenceName: String) throws {
        let device = try MetalRenderUtilities.makeDevice()
        let queue = try MetalRenderUtilities.makeCommandQueue(device: device)
        let target = try MetalRenderUtilities.makeRenderTarget(device: device)

        let alignment = Self.freshAlignment()
        alignment.screenMode = .channelTest

        let compositor = try StereoCompositor(device: device)
        let pair = StereoFramePair(left: nil, right: nil, hostTime: 0)

        let commandBuffer = try #require(queue.makeCommandBuffer())
        compositor.renderScreen(pair: pair,
                                alignment: alignment,
                                into: target,
                                commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        try compareOrSeed(target: target, named: referenceName)
    }

    private func compareOrSeed(target: MTLTexture, named referenceName: String) throws {
        let candidate = try MetalRenderUtilities.readBackImage(texture: target)

        if ProcessInfo.processInfo.environment["STEREONDI_UPDATE_GOLDENS"] == "1" {
            let dir = goldensDirectory()
            try GoldenImage.write(candidate,
                                  named: referenceName,
                                  toDirectory: dir)
            print("STEREONDI_UPDATE_GOLDENS=1 → wrote \(referenceName).png to \(dir.path)")
            return
        }

        let reference = try GoldenImage.loadReference(named: referenceName)
        let result = GoldenImage.compare(candidate,
                                         against: reference,
                                         tolerance: 0.02)
        #expect(result.passed,
                "Golden mismatch for \(referenceName): worstΔ=\(result.worstChannelDiff), failingPixels=\(result.failingPixelCount)/\(result.totalPixelCount)")
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
