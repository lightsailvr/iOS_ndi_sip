//  SessionStatus.swift
//
//  Per-session warning state for the on-screen banner overlays. Owned
//  at the ContentView level alongside AlignmentState; populated by the
//  FramePairer's tick callback (which has the freshest view of the
//  per-side frame metadata) and consumed by the WarningBanner SwiftUI
//  view stacked above the preview.
//
//  Each warning is a deterministic, non-crashing surfacing of a
//  source condition the operator should know about. The handling is
//  baked into the pipeline (e.g. resolution mismatch is letterboxed
//  by the existing aspect-fit math; alpha is premultiplied against
//  black in the BGRA fragment shader); the SessionStatus banner is
//  the operator-visible part.
//
//  Updates are triggered from `FramePairer.tick(...)` only when the
//  underlying signal actually changes — the Observable side does the
//  diff so SwiftUI doesn't redraw the banner stack every frame. (See
//  the per-property `didSet`-style guard helpers below.)
//
//  Why this is its own model rather than a couple of fields on
//  `AlignmentState`: alignment state is operator intent (HIT,
//  convergence, modes); SessionStatus is observed source conditions.
//  Mixing them muddles two very different lifetimes — alignment
//  persists across launches, status doesn't.

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class SessionStatus {

    /// Pair of source sizes that disagreed. `nil` when they agree (or
    /// when only one side is connected). The compositor's per-side
    /// aspect-fit math handles the actual rendering — the smaller
    /// source ends up letterboxed on its half, which is "scale to
    /// smaller" in effect (PRD: "scale both to the smaller resolution
    /// at the receive→stereo-pair stage; banner warning"). The HIT
    /// math operates in source-pixel space per side, so the warning
    /// is purely operator-facing — they should know the rig is
    /// mis-set.
    struct ResolutionMismatch: Equatable, Sendable {
        let leftSize: CGSize
        let rightSize: CGSize
    }

    var resolutionMismatch: ResolutionMismatch?

    /// True when at least one side delivered a frame whose
    /// `frame_format_type` is interleaved or a discrete field rather
    /// than progressive — i.e. FrameSync's deinterlacer didn't land
    /// us at a clean progressive frame and the operator is seeing a
    /// dominant-field passthrough.
    var interlacedWarning: Bool = false

    /// True when at least one side's frame format carries an alpha
    /// channel (BGRA today). The shader pre-multiplies against black
    /// for those sources; the banner makes the condition visible so
    /// the operator knows the on-screen image is composited rather
    /// than passed through.
    var hasAlphaWarning: Bool = false

    /// True when at least one of the connected sources has been
    /// flagged interlaced AND FrameSync was unable to deinterlace
    /// (we asked for progressive but got a field type). Reserved for
    /// a future polish slice that distinguishes "deinterlaced fine"
    /// from "couldn't deinterlace, dominant field shown" — for v1
    /// `interlacedWarning` covers both.
    init() {}

    /// One-shot update called by `FramePairer.tick(...)` with the
    /// current per-side dimensions and frame-format flags. The body
    /// guards against spurious re-publishes — assigning the same value
    /// to an `@Observable` property still notifies observers, so we
    /// only assign on actual change.
    func update(leftSize: CGSize?,
                rightSize: CGSize?,
                leftInterlaced: Bool,
                rightInterlaced: Bool,
                leftHasAlpha: Bool,
                rightHasAlpha: Bool) {
        let newMismatch: ResolutionMismatch? = {
            guard let l = leftSize, let r = rightSize else { return nil }
            guard l != r else { return nil }
            return ResolutionMismatch(leftSize: l, rightSize: r)
        }()
        if newMismatch != resolutionMismatch {
            resolutionMismatch = newMismatch
        }

        let newInterlaced = leftInterlaced || rightInterlaced
        if newInterlaced != interlacedWarning {
            interlacedWarning = newInterlaced
        }

        let newAlpha = leftHasAlpha || rightHasAlpha
        if newAlpha != hasAlphaWarning {
            hasAlphaWarning = newAlpha
        }
    }

    /// Clear all warnings. Called when both sides go to .empty (no
    /// sources assigned) so a freshly-cleared session doesn't carry
    /// stale banner state.
    func clear() {
        if resolutionMismatch != nil { resolutionMismatch = nil }
        if interlacedWarning { interlacedWarning = false }
        if hasAlphaWarning { hasAlphaWarning = false }
    }
}
