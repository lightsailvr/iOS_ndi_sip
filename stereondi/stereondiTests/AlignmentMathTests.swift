//  AlignmentMathTests.swift
//
//  Pure-function tests for AlignmentMath. No Metal, no Observation,
//  no MainActor — these run in milliseconds on any platform with the
//  test target.

import Foundation
import Testing
@testable import stereondi

struct AlignmentMathTests {

    @Test
    func clampHITAtPositiveLimit() {
        #expect(AlignmentMath.clampHIT(500) == 400)
    }

    @Test
    func clampHITAtNegativeLimit() {
        #expect(AlignmentMath.clampHIT(-500) == -400)
    }

    @Test
    func clampHITAtZero() {
        #expect(AlignmentMath.clampHIT(0) == 0)
    }

    @Test
    func clampHITPassesThroughInRange() {
        #expect(AlignmentMath.clampHIT(123.456) == 123.456)
        #expect(AlignmentMath.clampHIT(-399.99) == -399.99)
        #expect(AlignmentMath.clampHIT(400) == 400)
        #expect(AlignmentMath.clampHIT(-400) == -400)
    }

    @Test
    func hitToUVOffsetMatchesPixelDivision() {
        let uv = AlignmentMath.hitToUVOffset(hitPixels: 50, sourceWidthPixels: 1920)
        #expect(abs(uv - 50.0 / 1920.0) < 1e-12)
    }

    @Test
    func hitToUVOffsetSubPixelPrecision() {
        let uv = AlignmentMath.hitToUVOffset(hitPixels: 0.3, sourceWidthPixels: 1920)
        #expect(abs(uv - 0.3 / 1920.0) < 1e-12)
    }

    @Test
    func hitToUVOffsetSafeForZeroWidth() {
        let uv = AlignmentMath.hitToUVOffset(hitPixels: 50, sourceWidthPixels: 0)
        #expect(uv == 0)
    }

    @Test
    func perEyeHITSplitsConvergenceOppositely() {
        let r = AlignmentMath.perEyeHIT(convergence: 100, leftFine: 5, rightFine: -5)
        #expect(r.left == -45)
        #expect(r.right == 45)
    }

    @Test
    func perEyeHITZeroConvergenceJustFine() {
        let r = AlignmentMath.perEyeHIT(convergence: 0, leftFine: 12.5, rightFine: -7.25)
        #expect(r.left == 12.5)
        #expect(r.right == -7.25)
    }

    @Test
    func perEyeHITZeroFineMatchesHalfConvergence() {
        let r = AlignmentMath.perEyeHIT(convergence: 100, leftFine: 0, rightFine: 0)
        #expect(r.left == -50)
        #expect(r.right == 50)
    }

    // MARK: - Compositor uniform math
    //
    // These exercise StereoCompositor.alignmentUniforms — the pure
    // CPU-side function that converts (sidesHITPx, sourceWidthPx)
    // into the (u_min, u_max) the fragment shader uses for sub-pixel
    // texture-coordinate sampling. They cover the AC item
    // "sub-pixel offset → texture coordinate" alongside hitToUVOffset.

    @Test
    func uniformsZeroHITMapsFullSource() {
        let u = StereoCompositor.alignmentUniforms(forSideHITPixels: 0,
                                                   otherSideHITPixels: 0,
                                                   sourceWidthPixels: 1920,
                                                   otherSourceWidthPixels: 1920,
                                                   cropMode: .auto)
        #expect(u.uMin == 0)
        #expect(u.uMax == 1)
        #expect(u.cropModeFlag == 0)
    }

    @Test
    func uniformsSubPixelHITTranslatesUV() {
        // Convergence 0.3 px → leftHIT = -0.15, rightHIT = +0.15.
        // On a 1920-wide source, |hitUV| = 0.15/1920 ≈ 7.8e-5.
        // The common-region crop is also 7.8e-5 (same magnitude).
        let leftPx = -0.15
        let rightPx = +0.15
        let widthPx = 1920
        let leftU = StereoCompositor.alignmentUniforms(
            forSideHITPixels: leftPx,
            otherSideHITPixels: rightPx,
            sourceWidthPixels: widthPx,
            otherSourceWidthPixels: widthPx,
            cropMode: .auto)
        let rightU = StereoCompositor.alignmentUniforms(
            forSideHITPixels: rightPx,
            otherSideHITPixels: leftPx,
            sourceWidthPixels: widthPx,
            otherSourceWidthPixels: widthPx,
            cropMode: .auto)

        let absUV = Float(abs(leftPx) / Double(widthPx))
        // Left eye: uMin = absUV + (-absUV) = 0,  uMax = (1 - absUV) + (-absUV) = 1 - 2*absUV
        #expect(abs(leftU.uMin - 0) < 1e-7)
        #expect(abs(leftU.uMax - (1 - 2 * absUV)) < 1e-7)
        // Right eye mirror: uMin = absUV + absUV = 2*absUV, uMax = (1 - absUV) + absUV = 1
        #expect(abs(rightU.uMin - 2 * absUV) < 1e-7)
        #expect(abs(rightU.uMax - 1) < 1e-7)
    }

    @Test
    func uniformsAsymmetricHITUsesCommonAbsCrop() {
        // Left HIT = +50 px (uvL = +50/960), right HIT = -10 px
        // (uvR = -10/960). Common abs UV = 50/960.
        let widthPx = 960
        let leftPx = 50.0
        let rightPx = -10.0
        let leftU = StereoCompositor.alignmentUniforms(
            forSideHITPixels: leftPx,
            otherSideHITPixels: rightPx,
            sourceWidthPixels: widthPx,
            otherSourceWidthPixels: widthPx,
            cropMode: .auto)
        let common = Float(50.0 / 960.0)
        let leftHitUV = Float(50.0 / 960.0)
        #expect(abs(leftU.uMin - (common + leftHitUV)) < 1e-7)
        #expect(abs(leftU.uMax - ((1 - common) + leftHitUV)) < 1e-7)
        // Far edge sits at exactly 1.0 because this eye carries the
        // larger absolute HIT.
        #expect(abs(leftU.uMax - 1) < 1e-7)
    }

    @Test
    func uniformsCropOffSetsFlag() {
        let u = StereoCompositor.alignmentUniforms(forSideHITPixels: 50,
                                                   otherSideHITPixels: -50,
                                                   sourceWidthPixels: 1920,
                                                   otherSourceWidthPixels: 1920,
                                                   cropMode: .off)
        // OFF mode: window is exactly [hitUV, hitUV + 1].
        let hitUV = Float(50.0 / 1920.0)
        #expect(abs(u.uMin - hitUV) < 1e-7)
        #expect(abs(u.uMax - (hitUV + 1.0)) < 1e-7)
        #expect(u.cropModeFlag == 1)
    }

    // MARK: - uvWindow (crop-mode-aware sampling window)

    @Test
    func uvWindowAutoSymmetricHIT() {
        // Both eyes carry equal-and-opposite HIT, so commonAbsUV equals
        // |hitUV| and the window for THIS eye is shifted to put its
        // outside edge at exactly 1.0 (it's the eye with the larger
        // positive HIT — the right eye in slice #6's convention).
        let w = AlignmentMath.uvWindow(hitPixels: 50,
                                       otherHitPixels: -50,
                                       sourceWidthPixels: 1920,
                                       otherSourceWidthPixels: 1920,
                                       cropMode: .auto)
        let hitUV = 50.0 / 1920.0
        // commonAbsUV = 50/1920; uMin = commonAbsUV + hitUV = 2*hitUV.
        #expect(abs(w.uMin - 2 * hitUV) < 1e-12)
        // uMax = (1 - commonAbsUV) + hitUV = 1.
        #expect(abs(w.uMax - 1.0) < 1e-12)
    }

    @Test
    func uvWindowOffSymmetricHIT() {
        // OFF: uMin = hitUV, uMax = hitUV + 1 — independent of the
        // other eye's HIT (so the missing-edge black bar shows up
        // outside [0, 1]).
        let w = AlignmentMath.uvWindow(hitPixels: 50,
                                       otherHitPixels: -50,
                                       sourceWidthPixels: 1920,
                                       otherSourceWidthPixels: 1920,
                                       cropMode: .off)
        let hitUV = 50.0 / 1920.0
        #expect(abs(w.uMin - hitUV) < 1e-12)
        #expect(abs(w.uMax - (hitUV + 1.0)) < 1e-12)
        // Width is always 1 in OFF mode (no rescaling).
        #expect(abs((w.uMax - w.uMin) - 1.0) < 1e-12)
    }

    @Test
    func uvWindowAutoMismatchedWidthsUsesPerEyeNormalization() {
        // hit: 50 / 1920, other: 50 / 960. |hitUV| = 50/1920 ≈ 0.026,
        // |otherHitUV| = 50/960 ≈ 0.052 → commonAbsUV = 50/960.
        let w = AlignmentMath.uvWindow(hitPixels: 50,
                                       otherHitPixels: 50,
                                       sourceWidthPixels: 1920,
                                       otherSourceWidthPixels: 960,
                                       cropMode: .auto)
        let hitUV = 50.0 / 1920.0
        let commonAbsUV = 50.0 / 960.0
        #expect(abs(w.uMin - (commonAbsUV + hitUV)) < 1e-12)
        #expect(abs(w.uMax - ((1.0 - commonAbsUV) + hitUV)) < 1e-12)
    }

    @Test
    func uvWindowAutoZeroHITIsFullSource() {
        let w = AlignmentMath.uvWindow(hitPixels: 0,
                                       otherHitPixels: 0,
                                       sourceWidthPixels: 1920,
                                       otherSourceWidthPixels: 1920,
                                       cropMode: .auto)
        #expect(w.uMin == 0)
        #expect(w.uMax == 1)
    }

    @Test
    func uvWindowOffZeroHITIsFullSource() {
        // With zero HIT both modes collapse to the same (0, 1) window —
        // the OFF mode's "show me the black bars" only differs from
        // AUTO when HIT is non-zero.
        let w = AlignmentMath.uvWindow(hitPixels: 0,
                                       otherHitPixels: 0,
                                       sourceWidthPixels: 1920,
                                       otherSourceWidthPixels: 1920,
                                       cropMode: .off)
        #expect(w.uMin == 0)
        #expect(w.uMax == 1)
    }

    @Test
    func uvWindowOffNegativeHITPushesUMinNegative() {
        // hit: -50 / 1920 → window = [-50/1920, 1 - 50/1920]. The
        // shader's uv_outside_source check will return black for
        // src_u < 0 — that's the black bar on the LEFT edge of this
        // eye.
        let w = AlignmentMath.uvWindow(hitPixels: -50,
                                       otherHitPixels: 0,
                                       sourceWidthPixels: 1920,
                                       otherSourceWidthPixels: 1920,
                                       cropMode: .off)
        let hitUV = -50.0 / 1920.0
        #expect(abs(w.uMin - hitUV) < 1e-12)
        #expect(abs(w.uMax - (hitUV + 1.0)) < 1e-12)
        #expect(w.uMin < 0)
        #expect(w.uMax < 1)
    }
}
