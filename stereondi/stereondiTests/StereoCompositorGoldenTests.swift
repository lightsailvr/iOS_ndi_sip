//  StereoCompositorGoldenTests.swift
//
//  Reference goldens for the SbS compositor:
//
//   1. zero-HIT SbS gradient (slice #4 baseline) — `sbs_zero_hit_gradient.png`
//   2. +50 px convergence, AUTO crop — `sbs_hit_p50_crop_auto.png`
//   3. +50 px convergence, OFF  crop — `sbs_hit_p50_crop_off.png`
//   4. −50 px convergence (auto) — `sbs_hit_n50.png`
//   5. +200 px convergence (auto) — `sbs_hit_p200.png`
//   6. +0.3 px sub-pixel convergence (auto) — `sbs_hit_p0_3.png`
//
//  Each renders the same red-left / blue-right gradient pair with the
//  AlignmentState's convergence + cropMode dialed to the listed value,
//  then either compares against the bundled reference PNG (default) or
//  rewrites it (when STEREONDI_UPDATE_GOLDENS=1).
//
//  Slice #7 renames the slice-#6 `sbs_hit_p50.png` → `sbs_hit_p50_crop_auto.png`
//  (auto-crop was the implicit slice-#6 behavior) and adds the OFF
//  variant. Other slice-#6 goldens stay under their old names because
//  they're rendered with the default `.auto` mode.
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

    // MARK: - Test harness

    private func renderAndCompare(named referenceName: String,
                                  convergence: Double,
                                  cropMode: CropMode = .auto) throws {
        let device = try MetalRenderUtilities.makeDevice()
        let queue = try MetalRenderUtilities.makeCommandQueue(device: device)
        let target = try MetalRenderUtilities.makeRenderTarget(device: device)

        let leftPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .red)
        let rightPB = try MetalRenderUtilities.makeGradientPixelBuffer(tone: .blue)

        let leftFrame = StubVideoFrame(pixelBuffer: leftPB)
        let rightFrame = StubVideoFrame(pixelBuffer: rightPB)

        let alignment = AlignmentState()
        alignment.convergence = convergence
        alignment.cropMode = cropMode

        let compositor = try StereoCompositor(device: device)
        let pair = StereoFramePair(left: leftFrame, right: rightFrame, hostTime: 0)

        let commandBuffer = try #require(queue.makeCommandBuffer())
        compositor.render(pair: pair,
                          alignment: alignment,
                          into: target,
                          commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

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
