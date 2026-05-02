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
//
//  Slice #11 scope: persistence. The model now takes a `SessionStore`
//  in its initializer (default `.shared`); each property's `didSet`
//  writes through to the store on every change. The init loads
//  initial values from the store, but defers the write-through until
//  after the load so the restored values aren't immediately re-written
//  on top of themselves (saves a handful of UserDefaults writes on
//  app launch and avoids any chance of an infinite-loop nightmare if
//  a future store-side mutation triggered Observation back through
//  the model).
//
//  `screenMode` is restored from the operator's
//  `defaultScreenModeOnLaunch` preference rather than the last-used
//  mode — per the PRD, the operator gets a predictable launch
//  experience that matches their preference (rather than ending up in
//  channel-test because that was the last mode they had open).

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
///
/// Slice #11: declared `Codable` so a saved Favorite (which carries
/// the operator's preferred crop view alongside HIT) round-trips
/// through `JSONEncoder` on the favorites JSON blob.
enum CropMode: String, CaseIterable, Codable, Sendable {
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
///
/// Slice #11: `Codable` for the same reason as `CropMode` — favorites
/// don't currently carry screenMode, but a future polish slice may
/// want to.
enum ScreenMode: String, CaseIterable, Codable, Sendable {
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
            if convergence != clamped {
                convergence = clamped
                return
            }
            if persistsToStore { store.convergence = convergence }
        }
    }

    /// Per-eye fine adjustment added to the convergence-derived base.
    var leftFineHIT: Double = 0 {
        didSet {
            let clamped = AlignmentMath.clampHIT(leftFineHIT)
            if leftFineHIT != clamped {
                leftFineHIT = clamped
                return
            }
            if persistsToStore { store.leftFineHIT = leftFineHIT }
        }
    }

    var rightFineHIT: Double = 0 {
        didSet {
            let clamped = AlignmentMath.clampHIT(rightFineHIT)
            if rightFineHIT != clamped {
                rightFineHIT = clamped
                return
            }
            if persistsToStore { store.rightFineHIT = rightFineHIT }
        }
    }

    /// Per-PRD default: auto-crop is ON so the operator's resting view
    /// is clean. The bottom-bar disclosure exposes a toggle that flips
    /// this to `.off` for diagnostic / "show me exactly what HIT is
    /// doing" use.
    var cropMode: CropMode = .auto {
        didSet { if persistsToStore { store.cropMode = cropMode } }
    }

    /// What the iPad preview screen renders (SbS, anaglyph, or the
    /// channel-test pattern). Only affects the on-screen render path;
    /// the NDI-output pipeline always sends SbS regardless. Default
    /// `.sbs` so the resting state matches what the Quest viewer sees.
    /// Slice #9 wires up the proper segmented-control UI in the TopBar.
    /// Slice #11 hydrates this from the operator's
    /// `defaultScreenModeOnLaunch` preference at launch (see init).
    var screenMode: ScreenMode = .sbs {
        didSet { if persistsToStore { store.screenMode = screenMode } }
    }

    /// Inverts which source feeds the red channel in `.anaglyph` mode
    /// (default: left → red, right → green+blue; swapped: right → red,
    /// left → green+blue). No effect in `.sbs` or `.channelTest` mode
    /// — by design, so flipping back to SbS leaves the operator's
    /// alignment view unchanged.
    var swapEyes: Bool = false {
        didSet { if persistsToStore { store.swapEyes = swapEyes } }
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

    private let store: SessionStore

    /// Write-through gate. False during init so the initial restore
    /// from `SessionStore` doesn't immediately re-write the same
    /// values; flipped to `true` at the end of init so every later
    /// mutation flows out to the store.
    private var persistsToStore: Bool = false

    /// Construct a fresh state, hydrating each persisted property from
    /// the supplied `SessionStore`. `screenMode` reads from
    /// `defaultScreenModeOnLaunch` rather than the last-used
    /// `screenMode` (per PRD).
    init(store: SessionStore = .shared) {
        self.store = store
        // Direct property assignments below run the property's
        // `didSet`; the `persistsToStore` flag is false until the end
        // of this init, so write-through is suppressed and we don't
        // immediately re-write the same values back to defaults.
        self.convergence = store.convergence
        self.leftFineHIT = store.leftFineHIT
        self.rightFineHIT = store.rightFineHIT
        self.cropMode = store.cropMode
        self.swapEyes = store.swapEyes
        // Per PRD: launch in the operator's default-mode preference,
        // not whatever mode they happened to leave the app in.
        self.screenMode = store.defaultScreenModeOnLaunch
        self.persistsToStore = true
    }

    /// Zeros HIT state but intentionally preserves `cropMode`,
    /// `screenMode`, and `swapEyes` — operators frequently reset HIT
    /// mid-take while keeping their preferred crop / preview-mode /
    /// glasses-orientation choices in place.
    ///
    /// Each assignment runs the property's didSet, which writes
    /// through to the store. After the three writes, `SessionStore`'s
    /// stored convergence / leftFine / rightFine are all 0 — exactly
    /// what `SessionStore.resetSession()` would do directly.
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
