//  SessionStatusTests.swift
//
//  Pure-Swift tests for SessionStatus's mismatch / interlace / alpha
//  detection. SessionStatus's `update(...)` is the single entry point
//  the FramePairer feeds, so these tests directly exercise that.

import CoreGraphics
import Foundation
import Testing
@testable import stereondi

@MainActor
struct SessionStatusTests {

    @Test
    func resolutionMismatchIsNilWhenSizesMatch() {
        let status = SessionStatus()
        status.update(leftSize: CGSize(width: 1920, height: 1080),
                      rightSize: CGSize(width: 1920, height: 1080),
                      leftInterlaced: false,
                      rightInterlaced: false,
                      leftHasAlpha: false,
                      rightHasAlpha: false)
        #expect(status.resolutionMismatch == nil)
    }

    @Test
    func resolutionMismatchIsPopulatedWhenSizesDiffer() {
        let status = SessionStatus()
        status.update(leftSize: CGSize(width: 1920, height: 1080),
                      rightSize: CGSize(width: 960, height: 540),
                      leftInterlaced: false,
                      rightInterlaced: false,
                      leftHasAlpha: false,
                      rightHasAlpha: false)
        guard let mismatch = status.resolutionMismatch else {
            Issue.record("Expected a mismatch when sizes differ")
            return
        }
        #expect(mismatch.leftSize == CGSize(width: 1920, height: 1080))
        #expect(mismatch.rightSize == CGSize(width: 960, height: 540))
    }

    @Test
    func resolutionMismatchClearsWhenSourcesAgreeAgain() {
        let status = SessionStatus()
        status.update(leftSize: CGSize(width: 1920, height: 1080),
                      rightSize: CGSize(width: 960, height: 540),
                      leftInterlaced: false,
                      rightInterlaced: false,
                      leftHasAlpha: false,
                      rightHasAlpha: false)
        #expect(status.resolutionMismatch != nil)

        status.update(leftSize: CGSize(width: 1920, height: 1080),
                      rightSize: CGSize(width: 1920, height: 1080),
                      leftInterlaced: false,
                      rightInterlaced: false,
                      leftHasAlpha: false,
                      rightHasAlpha: false)
        #expect(status.resolutionMismatch == nil)
    }

    @Test
    func resolutionMismatchNilWhenOneSideMissing() {
        let status = SessionStatus()
        status.update(leftSize: CGSize(width: 1920, height: 1080),
                      rightSize: nil,
                      leftInterlaced: false,
                      rightInterlaced: false,
                      leftHasAlpha: false,
                      rightHasAlpha: false)
        #expect(status.resolutionMismatch == nil)
    }

    @Test
    func interlacedWarningTracksEitherSide() {
        let status = SessionStatus()

        status.update(leftSize: nil, rightSize: nil,
                      leftInterlaced: true, rightInterlaced: false,
                      leftHasAlpha: false, rightHasAlpha: false)
        #expect(status.interlacedWarning == true)

        status.update(leftSize: nil, rightSize: nil,
                      leftInterlaced: false, rightInterlaced: false,
                      leftHasAlpha: false, rightHasAlpha: false)
        #expect(status.interlacedWarning == false)

        status.update(leftSize: nil, rightSize: nil,
                      leftInterlaced: false, rightInterlaced: true,
                      leftHasAlpha: false, rightHasAlpha: false)
        #expect(status.interlacedWarning == true)
    }

    @Test
    func alphaWarningTracksEitherSide() {
        let status = SessionStatus()

        status.update(leftSize: nil, rightSize: nil,
                      leftInterlaced: false, rightInterlaced: false,
                      leftHasAlpha: true, rightHasAlpha: false)
        #expect(status.hasAlphaWarning == true)

        status.update(leftSize: nil, rightSize: nil,
                      leftInterlaced: false, rightInterlaced: false,
                      leftHasAlpha: false, rightHasAlpha: false)
        #expect(status.hasAlphaWarning == false)
    }

    @Test
    func clearResetsAllWarnings() {
        let status = SessionStatus()
        status.update(leftSize: CGSize(width: 1920, height: 1080),
                      rightSize: CGSize(width: 960, height: 540),
                      leftInterlaced: true,
                      rightInterlaced: false,
                      leftHasAlpha: false,
                      rightHasAlpha: true)
        #expect(status.resolutionMismatch != nil)
        #expect(status.interlacedWarning == true)
        #expect(status.hasAlphaWarning == true)

        status.clear()

        #expect(status.resolutionMismatch == nil)
        #expect(status.interlacedWarning == false)
        #expect(status.hasAlphaWarning == false)
    }
}
