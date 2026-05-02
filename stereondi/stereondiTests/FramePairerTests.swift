//  FramePairerTests.swift
//
//  Pure-Swift unit tests for FramePairer's tick → onTick contract.
//  Bypasses the CADisplayLink wiring entirely by calling
//  pairer.tick(hostTime:) directly with a scripted clock.

import CoreVideo
import Foundation
import Testing
@testable import stereondi

@MainActor
struct FramePairerTests {

    @Test
    func emitsBothSidesWhenBothReceiversHaveFrames() {
        let leftFrame = makeStubFrame()
        let rightFrame = makeStubFrame()
        let left = FakeReceiver(scripted: [leftFrame, leftFrame])
        let right = FakeReceiver(scripted: [rightFrame, rightFrame])

        var captured: [StereoFramePair] = []
        let pairer = FramePairer(left: left, right: right) { pair in
            captured.append(pair)
        }

        pairer.tick(hostTime: 0.016)
        pairer.tick(hostTime: 0.033)

        #expect(captured.count == 2)
        #expect(captured[0].left === leftFrame)
        #expect(captured[0].right === rightFrame)
        #expect(captured[0].hostTime == 0.016)
        #expect(captured[1].left === leftFrame)
        #expect(captured[1].right === rightFrame)
        #expect(captured[1].hostTime == 0.033)
    }

    @Test
    func emitsNilRightWhenOnlyLeftIsArriving() {
        let leftFrame = makeStubFrame()
        let left = FakeReceiver(scripted: [leftFrame, leftFrame, leftFrame])
        let right = FakeReceiver(scripted: [])

        var captured: [StereoFramePair] = []
        let pairer = FramePairer(left: left, right: right) { pair in
            captured.append(pair)
        }

        pairer.tick(hostTime: 1.0)
        pairer.tick(hostTime: 2.0)
        pairer.tick(hostTime: 3.0)

        #expect(captured.count == 3)
        for pair in captured {
            #expect(pair.left === leftFrame)
            #expect(pair.right == nil)
        }
    }

    @Test
    func emitsBothNilWhenNeitherSideHasFrames() {
        let left = FakeReceiver(scripted: [])
        let right = FakeReceiver(scripted: [])

        var captured: [StereoFramePair] = []
        let pairer = FramePairer(left: left, right: right) { pair in
            captured.append(pair)
        }

        pairer.tick(hostTime: 0.5)

        #expect(captured.count == 1)
        #expect(captured[0].left == nil)
        #expect(captured[0].right == nil)
    }

    @Test
    func setReceiversSwapsTargetsBeforeNextTick() {
        let leftA = makeStubFrame()
        let rightA = makeStubFrame()
        let leftB = makeStubFrame()
        let rightB = makeStubFrame()

        let originalLeft = FakeReceiver(scripted: [leftA])
        let originalRight = FakeReceiver(scripted: [rightA])

        var captured: [StereoFramePair] = []
        let pairer = FramePairer(left: originalLeft, right: originalRight) { pair in
            captured.append(pair)
        }

        pairer.tick(hostTime: 0.0)

        let swappedLeft = FakeReceiver(scripted: [leftB])
        let swappedRight = FakeReceiver(scripted: [rightB])
        pairer.setReceivers(left: swappedLeft, right: swappedRight)

        pairer.tick(hostTime: 0.016)

        #expect(captured.count == 2)
        #expect(captured[0].left === leftA)
        #expect(captured[0].right === rightA)
        #expect(captured[1].left === leftB)
        #expect(captured[1].right === rightB)
    }

    // MARK: - Helpers

    private func makeStubFrame() -> StubVideoFrame {
        let pb = makePixelBuffer()
        return StubVideoFrame(pixelBuffer: pb)
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         16,
                                         16,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pb)
        precondition(status == kCVReturnSuccess, "Test pixel buffer creation failed")
        return pb!
    }
}

// MARK: - Fake receiver

/// Hands the FramePairer a scripted sequence of frames, one per
/// `currentFrame()` call. After the script is exhausted it returns
/// nil forever (matching real-world stalled-source behavior).
private final class FakeReceiver: VideoFrameReceiving, @unchecked Sendable {
    private var scripted: [StubVideoFrame?]
    private var cursor = 0

    init(scripted: [StubVideoFrame?]) {
        self.scripted = scripted
    }

    func currentFrame() -> (any VideoFrameSource)? {
        guard cursor < scripted.count else { return nil }
        defer { cursor += 1 }
        return scripted[cursor]
    }
}
