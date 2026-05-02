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
//  Slice #6 scope: convergence, per-eye fine, reset, nudge.
//  Slice #7 scope: crop toggle (auto/off).
//  Slice #8 scope: iPad screen-mode (sbs/anaglyph/channel-test) and
//  swap-eyes — these only affect the on-screen preview pipeline; the
//  NDI-output pipeline always renders SbS regardless.

import Foundation
import Observation

/// How the per-eye sampling window is computed in the compositor.
///
/// - `.auto`: both eyes are cropped by the maximum absolute HIT offset
///   (in normalized UV) and the source slice is rescaled across the
///   eye's destination half. The operator sees a clean, full-bleed
///   image with no black bars regardless of HIT magnitude.
/// - `.off`: each eye samples its native `[hitUV, hitUV + 1]` window;
///   the shader returns black for source-UV outside `[0, 1]`, so the
///   missing-edge region becomes a visible black bar that lets the
///   operator see exactly what HIT is doing.
///
/// Default (auto) matches PRD user story 13: "the operator sees a
/// clean image with no black bars" while still allowing them to
/// flip the toggle to verify what HIT is shifting.
enum CropMode: String, CaseIterable, Sendable {
    case auto
    case off
}

/// What the iPad preview screen renders. Only affects the screen
/// pipeline — `StereoCompositor.renderForSender(...)` is always SbS
/// regardless (PRD user story 17 + 30: the Quest viewer's stream is
/// uninterrupted while the operator iterates between alignment views).
///
/// - `.sbs`: side-by-side, identical to the NDI output. Default.
/// - `.anaglyph`: pure-luma red/cyan anaglyph. Left source's BT.709
///   luma → red channel; right source's luma → green and blue
///   channels. `swapEyes` inverts the assignment.
/// - `.channelTest`: solid red on the left half, solid cyan on the
///   right half. Sources are bypassed — operators flip into this mode
///   to verify their anaglyph glasses are oriented correctly before
///   doing real alignment work.
enum ScreenMode: String, CaseIterable, Sendable {
    case sbs
    case anaglyph
    case channelTest
}

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

    /// Per-PRD default: auto-crop is ON so the operator's resting view
    /// is clean. The bottom-bar disclosure exposes a toggle that flips
    /// this to `.off` for diagnostic / "show me exactly what HIT is
    /// doing" use.
    var cropMode: CropMode = .auto

    /// What the iPad preview screen renders (SbS, anaglyph, or the
    /// channel-test pattern). Only affects the on-screen render path;
    /// the NDI-output pipeline always sends SbS regardless. Default
    /// `.sbs` so the resting state matches what the Quest viewer sees.
    /// The slice #8 hookup is a debug-only menu; slice #9 wires up the
    /// proper segmented-control UI.
    var screenMode: ScreenMode = .sbs

    /// Inverts which source feeds the red channel in `.anaglyph` mode
    /// (default: left → red, right → green+blue; swapped: right → red,
    /// left → green+blue). No effect in `.sbs` or `.channelTest` mode
    /// — by design, so flipping back to SbS leaves the operator's
    /// alignment view unchanged.
    var swapEyes: Bool = false

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

    /// Zeros HIT state but intentionally preserves `cropMode`,
    /// `screenMode`, and `swapEyes` — operators frequently reset HIT
    /// mid-take while keeping their preferred crop / preview-mode /
    /// glasses-orientation choices in place.
    func resetAll() {
        convergence = 0
        leftFineHIT = 0
        rightFineHIT = 0
    }

    /// Flips the crop mode between `.auto` and `.off`. The toggle is
    /// not reset by `resetAll()` — operators frequently adjust HIT
    /// while leaving the crop preference in place.
    func toggleCrop() {
        cropMode = (cropMode == .auto) ? .off : .auto
    }

    /// Bumps convergence by `delta` (typically ±1 or ±0.1 px). Sub-pixel
    /// precision is retained — the slider's display formatter rounds
    /// to one decimal but the stored value keeps its full precision so
    /// the shader samples sub-pixel-accurately via bilinear filtering.
    func nudgeConvergence(by delta: Double) {
        convergence = AlignmentMath.clampHIT(convergence + delta)
    }
}
