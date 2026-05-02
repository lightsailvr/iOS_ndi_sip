//  FramePairerTests.swift
//
//  Pure-Swift unit tests for FramePairer's tick → onTick contract.
//  Bypasses the CADisplayLink wiring entirely by calling
//  pairer.tick(hostTime:) directly with a scripted clock.
//
//  Slice #12 additions:
//   - Frozen-frame tests: a side that was live but is now nil (and
//     whose status is .live, .stalled, or .reconnecting) keeps its
//     previous frame in the emitted pair rather than going to nil.
//   - Stall-threshold tests: ReceiverWatchdog promotes .live →
//     .stalled at the 2 s mark (driven by the fake clock).
//   - Recovery test: a stalled receiver that emits a frame returns
//     to .live on the next watchdog tick AND on the next pairer tick.
//   - Interface-change test: NetworkResilience.onInterfaceChange()
//     fires → both receivers' kickReconnect is invoked.

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
            // No status provider configured → both sides default to
            // .empty; the pairer's freeze logic keeps right at nil
            // because .empty status means "no source assigned".
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

    // MARK: - Slice #12: freeze frame on disappearance + stall promotion

    @Test
    func freezesPreviousLeftFrameWhenLiveCaptureGoesNilButStatusStaysLive() {
        let leftFrame1 = makeStubFrame()
        let leftFrame2 = makeStubFrame()
        // After the second frame the source goes nil for two ticks.
        let left = FakeReceiver(scripted: [leftFrame1, leftFrame2, nil, nil])
        let right = FakeReceiver(scripted: [makeStubFrame(),
                                            makeStubFrame(),
                                            makeStubFrame(),
                                            makeStubFrame()])

        var sideStatus: ReceiverWatchdog.SideStatus = .live(width: 100, height: 100, frameRate: 60)
        var captured: [StereoFramePair] = []
        let pairer = FramePairer(
            left: left,
            right: right,
            onTick: { captured.append($0) },
            statusProvider: { (left: sideStatus, right: .live(width: 100, height: 100, frameRate: 60)) }
        )

        pairer.tick(hostTime: 0.0)
        pairer.tick(hostTime: 0.016)

        // Tick 3: live capture nil but status still .live (within 2 s window).
        pairer.tick(hostTime: 0.033)

        // Tick 4: status flips to .stalled (watchdog would promote it).
        sideStatus = .stalled
        pairer.tick(hostTime: 0.05)

        #expect(captured.count == 4)
        #expect(captured[0].left === leftFrame1)
        #expect(captured[1].left === leftFrame2)
        // Frozen on the most recent good frame.
        #expect(captured[2].left === leftFrame2)
        #expect(captured[2].leftStatus == .live(width: 100, height: 100, frameRate: 60))
        // Stall keeps the freeze in place; status reflects stalled.
        #expect(captured[3].left === leftFrame2)
        #expect(captured[3].leftStatus == .stalled)
    }

    @Test
    func reconnectingStatusFreezesPreviousFrame() {
        let leftFrame = makeStubFrame()
        let rightFrame = makeStubFrame()
        let left = FakeReceiver(scripted: [leftFrame, nil, nil])
        let right = FakeReceiver(scripted: [rightFrame, rightFrame, rightFrame])

        var captured: [StereoFramePair] = []
        let pairer = FramePairer(
            left: left,
            right: right,
            onTick: { captured.append($0) },
            statusProvider: { (left: .reconnecting,
                               right: .live(width: 100, height: 100, frameRate: 60)) }
        )

        pairer.tick(hostTime: 0.0)
        pairer.tick(hostTime: 0.016)
        pairer.tick(hostTime: 0.033)

        #expect(captured.count == 3)
        #expect(captured[0].left === leftFrame)
        #expect(captured[1].left === leftFrame)
        #expect(captured[2].left === leftFrame)
        #expect(captured[1].leftStatus == .reconnecting)
    }

    @Test
    func emptyStatusKeepsLeftNilEvenAfterPriorFrame() {
        // When the operator clears a source, status flips to .empty
        // and the pairer should NOT freeze the previous frame —
        // .empty means the side has no source assigned.
        let leftFrame = makeStubFrame()
        let left = FakeReceiver(scripted: [leftFrame, nil])

        var status: ReceiverWatchdog.SideStatus = .live(width: 100, height: 100, frameRate: 60)
        var captured: [StereoFramePair] = []
        let pairer = FramePairer(
            left: left,
            right: FakeReceiver(scripted: []),
            onTick: { captured.append($0) },
            statusProvider: { (left: status, right: .empty) }
        )

        pairer.tick(hostTime: 0.0)

        status = .empty
        pairer.tick(hostTime: 0.016)

        #expect(captured.count == 2)
        #expect(captured[0].left === leftFrame)
        #expect(captured[1].left == nil)
    }

    // MARK: - Slice #12: stall threshold + recovery

    @Test
    func watchdogPromotesLiveToStalledAtTwoSeconds() {
        let receiver = ScriptableWatchableReceiver()
        receiver.state = .live
        receiver.timeSinceLastFrame = 0.0
        let other = ScriptableWatchableReceiver()
        let watchdog = ReceiverWatchdog(left: receiver,
                                        right: other,
                                        network: NetworkResilience())

        // t=0: just got a frame.
        receiver.timeSinceLastFrame = 0.0
        watchdog.tick(now: 0.0)
        guard case .live = watchdog.leftStatus else {
            Issue.record("Expected .live at t=0 (got \(watchdog.leftStatus))")
            return
        }

        // t=1.9: still under the 2 s threshold.
        receiver.timeSinceLastFrame = 1.9
        watchdog.tick(now: 1.9)
        guard case .live = watchdog.leftStatus else {
            Issue.record("Expected .live at t=1.9 (got \(watchdog.leftStatus))")
            return
        }

        // t=2.1: tipped over the stall threshold.
        receiver.timeSinceLastFrame = 2.1
        watchdog.tick(now: 2.1)
        #expect(watchdog.leftStatus == .stalled)
    }

    @Test
    func watchdogReturnsToLiveOnFrameResumptionAfterStall() {
        let receiver = ScriptableWatchableReceiver()
        receiver.state = .live
        receiver.timeSinceLastFrame = 2.5
        receiver.lastFrameWidth = 1920
        receiver.lastFrameHeight = 1080

        let other = ScriptableWatchableReceiver()
        let watchdog = ReceiverWatchdog(left: receiver,
                                        right: other,
                                        network: NetworkResilience())

        // First tick: stalled.
        watchdog.tick(now: 2.5)
        #expect(watchdog.leftStatus == .stalled)

        // A fresh frame arrives. In production NDIReceiver flips its
        // own state back to .live on a successful capture; we mirror
        // that here by setting state + zeroing timeSinceLastFrame.
        receiver.state = .live
        receiver.timeSinceLastFrame = 0.05
        watchdog.tick(now: 2.6)

        guard case .live(let width, let height, _) = watchdog.leftStatus else {
            Issue.record("Expected .live after recovery (got \(watchdog.leftStatus))")
            return
        }
        #expect(width == 1920)
        #expect(height == 1080)
    }

    @Test
    func watchdogKicksReconnectOnDisconnectedReceiverEveryTwoSeconds() {
        let receiver = ScriptableWatchableReceiver()
        receiver.state = .disconnected

        let other = ScriptableWatchableReceiver()
        let watchdog = ReceiverWatchdog(left: receiver,
                                        right: other,
                                        network: NetworkResilience())

        // First tick: surfaces .reconnecting and kicks once.
        watchdog.tick(now: 0.0)
        #expect(watchdog.leftStatus == .reconnecting)
        #expect(receiver.kickCount == 1)

        // 1 s later: still reconnecting, but throttled below the 2 s
        // retry interval, so no additional kick.
        watchdog.tick(now: 1.0)
        #expect(receiver.kickCount == 1)

        // 2 s after the first kick: another kick.
        watchdog.tick(now: 2.0)
        #expect(receiver.kickCount == 2)
    }

    // MARK: - Slice #12: interface-change kick

    @Test
    func interfaceChangeFiresKickOnBothReceivers() {
        let left = ScriptableWatchableReceiver()
        let right = ScriptableWatchableReceiver()
        let network = NetworkResilience()
        // Constructing the watchdog wires up network.onInterfaceChange.
        let watchdog = ReceiverWatchdog(left: left, right: right, network: network)
        _ = watchdog

        network.onInterfaceChange?()

        #expect(left.kickCount == 1)
        #expect(right.kickCount == 1)
    }

    @Test
    func handleInterfaceChangePublicEntryPointKicksBothReceivers() {
        let left = ScriptableWatchableReceiver()
        let right = ScriptableWatchableReceiver()
        let watchdog = ReceiverWatchdog(left: left,
                                        right: right,
                                        network: NetworkResilience())

        watchdog.handleInterfaceChange()

        #expect(left.kickCount == 1)
        #expect(right.kickCount == 1)
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
/// nil forever (matching real-world stalled-source behavior). Nil
/// entries inside the script let tests interleave gaps.
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

// MARK: - Scriptable WatchableReceiver

/// Test double for `ReceiverWatchdog` — every property is freely
/// settable from the test, and `kickReconnect` increments a counter
/// the test asserts on.
private final class ScriptableWatchableReceiver: WatchableReceiver, @unchecked Sendable {
    var state: NDIReceiverState = .idle
    var timeSinceLastFrame: TimeInterval = .infinity
    var lastFrameWidth: Int = 0
    var lastFrameHeight: Int = 0
    var lastFrameInterlaced: Bool = false
    var lastFrameHasAlpha: Bool = false
    var lastFrameRate: Double = 0
    private(set) var kickCount: Int = 0

    func kickReconnect() {
        kickCount += 1
    }
}
