//  AlignmentStateTests.swift
//
//  Tests for the @Observable AlignmentState wrapper. Covers:
//   - clamping at ±400 px on convergence and per-eye fine sliders
//   - the opposite-shift convergence math (positive convergence sends
//     left to negative HIT, right to positive HIT)
//   - sub-pixel precision is preserved through nudgeConvergence
//   - resetAll() zeros all three fields

import Foundation
import Testing
@testable import stereondi

@MainActor
struct AlignmentStateTests {

    @Test
    func convergenceClampsBeyondPositiveLimit() {
        let state = AlignmentState()
        state.convergence = 1000
        #expect(state.convergence == 400)
    }

    @Test
    func convergenceClampsBeyondNegativeLimit() {
        let state = AlignmentState()
        state.convergence = -1000
        #expect(state.convergence == -400)
    }

    @Test
    func leftFineHITClamps() {
        let state = AlignmentState()
        state.leftFineHIT = 999
        #expect(state.leftFineHIT == 400)
        state.leftFineHIT = -999
        #expect(state.leftFineHIT == -400)
    }

    @Test
    func rightFineHITClamps() {
        let state = AlignmentState()
        state.rightFineHIT = 999
        #expect(state.rightFineHIT == 400)
        state.rightFineHIT = -999
        #expect(state.rightFineHIT == -400)
    }

    @Test
    func convergenceSplitsOppositely() {
        let state = AlignmentState()
        state.convergence = 100
        #expect(state.leftHIT == -50)
        #expect(state.rightHIT == 50)
    }

    @Test
    func perEyeFineAddsToConvergenceShift() {
        let state = AlignmentState()
        state.convergence = 100
        state.leftFineHIT = 10
        state.rightFineHIT = -10
        #expect(state.leftHIT == -40)
        #expect(state.rightHIT == 40)
    }

    @Test
    func resetAllZeros() {
        let state = AlignmentState()
        state.convergence = 123
        state.leftFineHIT = 45
        state.rightFineHIT = -67
        state.resetAll()
        #expect(state.convergence == 0)
        #expect(state.leftFineHIT == 0)
        #expect(state.rightFineHIT == 0)
        #expect(state.leftHIT == 0)
        #expect(state.rightHIT == 0)
    }

    @Test
    func nudgeConvergencePreservesSubPixel() {
        let state = AlignmentState()
        state.nudgeConvergence(by: 0.1)
        #expect(state.convergence == 0.1)
        state.nudgeConvergence(by: 0.1)
        state.nudgeConvergence(by: 0.1)
        // 3 × 0.1 doesn't equal 0.3 in IEEE-754; assert the float is
        // within sub-pixel tolerance of 0.3 instead.
        #expect(abs(state.convergence - 0.3) < 1e-9)
    }

    @Test
    func nudgeConvergenceClampsAtLimit() {
        let state = AlignmentState()
        state.convergence = 399.95
        state.nudgeConvergence(by: 1.0)
        #expect(state.convergence == 400)
    }

    @Test
    func nudgeConvergenceClampsAtNegativeLimit() {
        let state = AlignmentState()
        state.convergence = -399.95
        state.nudgeConvergence(by: -1.0)
        #expect(state.convergence == -400)
    }

    @Test
    func defaultsAreAllZero() {
        let state = AlignmentState()
        #expect(state.convergence == 0)
        #expect(state.leftFineHIT == 0)
        #expect(state.rightFineHIT == 0)
        #expect(state.leftHIT == 0)
        #expect(state.rightHIT == 0)
    }

    @Test
    func cropToggle() {
        let state = AlignmentState()
        #expect(state.cropMode == .auto)
        state.toggleCrop()
        #expect(state.cropMode == .off)
        state.toggleCrop()
        #expect(state.cropMode == .auto)
    }

    @Test
    func resetAllPreservesCropMode() {
        // resetAll() zeros HIT but intentionally leaves cropMode in
        // place — operators frequently reset alignment mid-take while
        // keeping their preferred crop view.
        let state = AlignmentState()
        state.cropMode = .off
        state.convergence = 100
        state.resetAll()
        #expect(state.convergence == 0)
        #expect(state.cropMode == .off)
    }

    // MARK: - Slice #8: screenMode + swapEyes

    @Test
    func screenModeDefaultsToSbS() {
        let state = AlignmentState()
        #expect(state.screenMode == .sbs)
    }

    @Test
    func screenModeTransitionsAcrossAllCases() {
        let state = AlignmentState()
        state.screenMode = .anaglyph
        #expect(state.screenMode == .anaglyph)
        state.screenMode = .channelTest
        #expect(state.screenMode == .channelTest)
        state.screenMode = .sbs
        #expect(state.screenMode == .sbs)
    }

    @Test
    func swapEyesDefaultsFalse() {
        let state = AlignmentState()
        #expect(state.swapEyes == false)
    }

    @Test
    func swapEyesToggles() {
        let state = AlignmentState()
        state.swapEyes = true
        #expect(state.swapEyes == true)
        state.swapEyes = false
        #expect(state.swapEyes == false)
    }

    @Test
    func resetAllPreservesScreenMode() {
        // resetAll() zeros HIT but intentionally leaves screenMode in
        // place — operators frequently reset alignment mid-take while
        // keeping their chosen preview mode (e.g. staying in anaglyph
        // for the next take's alignment pass).
        let state = AlignmentState()
        state.screenMode = .anaglyph
        state.convergence = 100
        state.resetAll()
        #expect(state.convergence == 0)
        #expect(state.screenMode == .anaglyph)
    }

    @Test
    func resetAllPreservesSwapEyes() {
        // Same rationale as cropMode + screenMode: a mismatched glasses
        // orientation discovered at the start of a session shouldn't
        // need to be re-discovered after every alignment reset.
        let state = AlignmentState()
        state.swapEyes = true
        state.convergence = 100
        state.resetAll()
        #expect(state.convergence == 0)
        #expect(state.swapEyes == true)
    }

    // MARK: - Slice #9: screenMode/swapEyes interaction (top-bar UI)

    @Test
    func switchingToAnaglyphPreservesSwapEyes() {
        // The slice-#9 TopBar only mounts the swap-eyes toggle when
        // screenMode == .anaglyph. The operator may set swap-eyes once
        // (e.g. while testing glasses) and then move through SbS for a
        // creative-look pass before returning to anaglyph for fine
        // alignment — switching modes must never silently flip the
        // swap-eyes preference.
        let state = AlignmentState()
        state.swapEyes = true
        state.screenMode = .anaglyph
        #expect(state.swapEyes == true)
    }

    @Test
    func swapEyesSurvivesScreenModeRoundTrip() {
        // Same invariant as above, exercised across a full
        // anaglyph → channel-test → sbs → anaglyph round trip. The
        // swap-eyes preference is glasses-orientation, not view-state,
        // so it must remain stable as the operator iterates between
        // modes that ignore it.
        let state = AlignmentState()
        state.screenMode = .anaglyph
        state.swapEyes = true
        state.screenMode = .channelTest
        state.screenMode = .sbs
        state.screenMode = .anaglyph
        #expect(state.swapEyes == true)
    }
}
