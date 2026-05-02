//  SourceSelection.swift
//
//  Owns the operator's currently-picked Left and Right NDI sources.
//  Slice #3 only renders the Left source through the live preview;
//  Right is stored so the Top Bar can show its label and so a future
//  slice (FramePairer + dual-receiver) can wire up the second pipeline
//  without changing the selection model.

import Foundation
import Observation

@MainActor
@Observable
final class SourceSelection {
    var leftSource: NDISource?
    var rightSource: NDISource?

    func swap() {
        (leftSource, rightSource) = (rightSource, leftSource)
    }
}
