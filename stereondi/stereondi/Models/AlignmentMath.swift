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
}
