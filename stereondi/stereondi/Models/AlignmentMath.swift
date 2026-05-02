//  AlignmentMath.swift
//
//  Pure top-level functions for HIT / convergence math. Lives outside
//  AlignmentState so the Metal pipeline AND the AlignmentState property
//  setters can share one canonical implementation, and so the unit
//  tests can exercise it without involving Observation, MainActor, or
//  any Metal/SwiftUI imports.
//
//  Sign convention (mirrored in AlignmentState):
//   - HIT is in source pixels.
//   - leftHIT > 0 / rightHIT > 0 mean: add a positive ΔU to the source
//     sampler. A positive ΔU means we sample further to the right of
//     the source, which shifts the visible image to the LEFT.
//   - Convergence > 0 produces leftHIT = -conv/2 and rightHIT = +conv/2:
//     the left eye's image shifts RIGHT, the right eye's image shifts
//     LEFT — both images move toward each other, reducing horizontal
//     disparity. In stereoscopy terms this brings the convergence
//     point toward the viewer (objects "come out of the screen"), so
//     positive convergence "reduces parallax".

import Foundation

enum AlignmentMath {

    /// Hard limit on per-eye HIT and on the convergence base value. Per
    /// PRD user story 9 (hyper-stereo rigs with wide interaxials).
    static let hitMaxAbsPixels: Double = 400.0

    static func clampHIT(_ value: Double) -> Double {
        max(-hitMaxAbsPixels, min(hitMaxAbsPixels, value))
    }

    /// Convert a HIT in source pixels to a normalized UV ΔU. Bilinear
    /// filter on the sampled texture provides sub-pixel accuracy when
    /// `hitPixels` carries fractional precision.
    static func hitToUVOffset(hitPixels: Double, sourceWidthPixels: Double) -> Double {
        guard sourceWidthPixels > 0 else { return 0 }
        return hitPixels / sourceWidthPixels
    }

    /// Per-eye HIT given convergence + per-eye fine. Mirrors the
    /// computed properties on AlignmentState; exposed here for tests
    /// that don't want to spin up the Observable.
    static func perEyeHIT(convergence: Double,
                          leftFine: Double,
                          rightFine: Double) -> (left: Double, right: Double) {
        let left = -convergence / 2.0 + leftFine
        let right = +convergence / 2.0 + rightFine
        return (left, right)
    }

    /// Returns the source-UV sampling window `(uMin, uMax)` for one
    /// eye given its own HIT, the other eye's HIT, both eyes' source
    /// widths, and the active `CropMode`. The sampler in the fragment
    /// shader maps destination UV ∈ [0,1] linearly onto this window:
    ///
    ///   `src_u = uMin + dst_u * (uMax - uMin)`
    ///
    /// — so the window's *width* (uMax − uMin) controls how much of
    /// the source is stretched across the eye's destination half, and
    /// the window's *position* controls which slice of the source is
    /// shown.
    ///
    /// Sign convention: `hitPixels > 0` means "sample further right
    /// in source" (the visible image translates LEFT). Same convention
    /// as `hitToUVOffset` and `perEyeHIT`.
    ///
    /// `.auto` — common-region crop. Both eyes sample a slice of width
    /// `1 − 2 × commonAbsUV`, centered at `0.5 + hitUV`, where
    /// `commonAbsUV = max(|leftHitUV|, |rightHitUV|)` computed against
    /// each eye's own source width. The slice is guaranteed to stay
    /// inside `[0, 1]` for both eyes (the eye carrying the larger
    /// |HIT| has exactly `commonAbsUV` of headroom on its outside
    /// edge), so no black bars appear regardless of HIT magnitude.
    /// When both HITs are zero this collapses to `(0, 1)` — i.e. the
    /// pre-slice-#6 zero-HIT render.
    ///
    /// `.off` — full-frame, no crop. Each eye samples exactly
    /// `[hitUV, hitUV + 1]`. With non-zero HIT the window pokes past
    /// `[0, 1]` on one edge; the shader's `uv_outside_source` check
    /// returns black for those samples, producing the visible black
    /// bar that lets the operator see exactly what HIT is shifting.
    /// The window's *width* stays at 1 regardless of HIT, so the
    /// in-source pixels are NOT stretched (they keep their native
    /// pixel-aspect across the destination half — which is the whole
    /// point of OFF mode).
    static func uvWindow(hitPixels: Double,
                         otherHitPixels: Double,
                         sourceWidthPixels: Double,
                         otherSourceWidthPixels: Double,
                         cropMode: CropMode) -> (uMin: Double, uMax: Double) {
        let srcW = max(sourceWidthPixels, 1)
        let hitUV = hitToUVOffset(hitPixels: hitPixels, sourceWidthPixels: srcW)

        switch cropMode {
        case .off:
            return (uMin: hitUV, uMax: hitUV + 1.0)

        case .auto:
            let otherW = max(otherSourceWidthPixels, 1)
            let otherHitUV = hitToUVOffset(hitPixels: otherHitPixels,
                                           sourceWidthPixels: otherW)
            let commonAbsUV = max(abs(hitUV), abs(otherHitUV))
            let uMin = commonAbsUV + hitUV
            let uMax = (1.0 - commonAbsUV) + hitUV
            return (uMin: uMin, uMax: uMax)
        }
    }
}
