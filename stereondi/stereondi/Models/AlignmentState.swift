//  AlignmentState.swift
//
//  The single observable owner of the operator's HIT/convergence
//  controls. Shared by the bottom-bar SwiftUI view, the on-preview
//  gesture overlay, and the Metal compositor — every reader pulls the
//  current values fresh per frame, so a slider drag or a two-finger
//  pan reflects in shader output within ONE frame (no caching).
//
//  Sign convention:
//   - convergence > 0  → leftHIT = -convergence/2, rightHIT = +convergence/2
//   - HIT > 0 means add a positive ΔU to that eye's source sampler
//     (sample further RIGHT in source → the visible image translates
//     LEFT). HIT < 0 is the mirror.
//   - So positive convergence pushes the left eye's image RIGHT and
//     the right eye's image LEFT — both images move TOWARD the screen
//     centerline, which reduces horizontal disparity at the convergence
//     plane. In stereoscopy terms, positive convergence brings the
//     converged object closer in depth ("comes out of the screen").
//   - leftFineHIT / rightFineHIT add to the convergence-derived base
//     so an asymmetric lens offset can be corrected without disturbing
//     the operator's primary convergence target.
//
//  All values are clamped to ±400 px (PRD user story 9). Clamping is
//  silent — the UI doesn't need to disable the per-eye fine sliders
//  when their effect would push past the limit.
//
//  Slice scope: convergence, per-eye fine, reset, nudge. Crop toggle,
//  preview-mode (SbS / anaglyph / channel-test), and swap-eyes live
//  in this same model in slice #7 — extending here is intentional.

import Foundation
import Observation

@MainActor
@Observable
final class AlignmentState {

    static let hitMaxAbsPixels: Double = AlignmentMath.hitMaxAbsPixels

    /// Symmetric base convergence in source pixels. Positive convergence
    /// sends the left eye's HIT to negative and the right eye's HIT to
    /// positive (see file header for the visual interpretation).
    var convergence: Double = 0 {
        didSet {
            let clamped = AlignmentMath.clampHIT(convergence)
            if convergence != clamped { convergence = clamped }
        }
    }

    /// Per-eye fine adjustment added to the convergence-derived base.
    var leftFineHIT: Double = 0 {
        didSet {
            let clamped = AlignmentMath.clampHIT(leftFineHIT)
            if leftFineHIT != clamped { leftFineHIT = clamped }
        }
    }

    var rightFineHIT: Double = 0 {
        didSet {
            let clamped = AlignmentMath.clampHIT(rightFineHIT)
            if rightFineHIT != clamped { rightFineHIT = clamped }
        }
    }

    /// Effective per-eye HIT in source pixels (sub-pixel precision
    /// preserved). Compositor reads this fresh on every frame.
    var leftHIT: Double {
        AlignmentMath.perEyeHIT(convergence: convergence,
                                leftFine: leftFineHIT,
                                rightFine: rightFineHIT).left
    }

    var rightHIT: Double {
        AlignmentMath.perEyeHIT(convergence: convergence,
                                leftFine: leftFineHIT,
                                rightFine: rightFineHIT).right
    }

    func resetAll() {
        convergence = 0
        leftFineHIT = 0
        rightFineHIT = 0
    }

    /// Bumps convergence by `delta` (typically ±1 or ±0.1 px). Sub-pixel
    /// precision is retained — the slider's display formatter rounds
    /// to one decimal but the stored value keeps its full precision so
    /// the shader samples sub-pixel-accurately via bilinear filtering.
    func nudgeConvergence(by delta: Double) {
        convergence = AlignmentMath.clampHIT(convergence + delta)
    }
}
