//  FramePairer.swift
//
//  Pulls the latest video frame from each of two VideoFrameReceiving
//  sources (typically NDIReceivers) on a shared CADisplayLink clock and
//  emits StereoFramePair values to a callback.
//
//  Slice #4 scope: nil-eye → compositor draws black; pair was just
//  (left, right, hostTime).
//
//  Slice #12 additions:
//   - Per-side `SideStatus` is computed by an injected `StatusProvider`
//     closure (the production wiring points it at `ReceiverWatchdog.
//     {left,right}Status`). The pairer is responsible for translating
//     "current frame is nil but receiver is .live" into "use the
//     previous good frame and report .live", and similarly for
//     .stalled / .disconnected (which surfaces as .reconnecting on
//     the overlay per the issue's contract).
//   - The pairer tracks the previous good frame per side. When the
//     receiver returns nil for that side, the pairer re-uses the
//     previous frame. The compositor's nil → black behavior thus only
//     fires for sides that have NEVER produced a frame; once a side
//     has been live, it stays frozen (rather than going black) until
//     either a new frame arrives or both sides recover.
//   - The pairer also calls a `StatusObserver` closure on each tick
//     with the per-side dimensions / interlace / alpha — the
//     production wiring routes this into `SessionStatus.update(...)`
//     so the warning-banner state diffs without an extra sweep loop.
//
//  Testability:
//   - `start()` wires up the display link; tests bypass it and call
//     `tick(hostTime:)` directly with scripted frame arrivals AND
//     scripted per-side statuses.
//   - The receiver dependency is the `VideoFrameReceiving` protocol;
//     the status dependency is a closure. Tests inject both without
//     touching NDI or the watchdog timer.

import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class FramePairer {

    typealias Tick = (StereoFramePair) -> Void

    /// Provides the current per-side `SideStatus`. Production wiring
    /// points it at the `ReceiverWatchdog`; tests script it directly.
    typealias StatusProvider = () -> (left: ReceiverWatchdog.SideStatus,
                                      right: ReceiverWatchdog.SideStatus)

    /// Per-tick observer for SessionStatus updates. Receives per-side
    /// dimensions (nil when no frame has ever been seen on that side),
    /// per-side interlaced flag, per-side alpha-presence flag.
    typealias StatusObserver = (
        _ leftSize: CGSize?,
        _ rightSize: CGSize?,
        _ leftInterlaced: Bool,
        _ rightInterlaced: Bool,
        _ leftHasAlpha: Bool,
        _ rightHasAlpha: Bool
    ) -> Void

    private(set) var leftReceiver: any VideoFrameReceiving
    private(set) var rightReceiver: any VideoFrameReceiving
    /// Mutable so the MetalPreviewView coordinator can swap in its
    /// own cache-and-redraw closure after the pairer is constructed
    /// (the SwiftUI owner constructs the pairer earlier in the view
    /// hierarchy than the MTKView coordinator exists).
    var onTick: Tick
    /// Returns the per-side `SideStatus` to publish in the next pair.
    /// Defaults to `.empty` for both sides; ContentView swaps in a
    /// closure that reads from `ReceiverWatchdog`.
    var statusProvider: StatusProvider
    /// Optional per-tick observer for SessionStatus mismatch /
    /// interlace / alpha detection.
    var statusObserver: StatusObserver?

    private var displayLink: CADisplayLink?

    /// Last good frame per side. nil until the first frame arrives,
    /// then replaced on every successful capture. Used to "freeze"
    /// the last good frame when a source disappears mid-take, per
    /// PRD: "the alignment view doesn't go black mid-take".
    private var previousLeftFrame: (any VideoFrameSource)?
    private var previousRightFrame: (any VideoFrameSource)?

    init(left: any VideoFrameReceiving,
         right: any VideoFrameReceiving,
         onTick: @escaping Tick = { _ in },
         statusProvider: @escaping StatusProvider = { (left: .empty, right: .empty) },
         statusObserver: StatusObserver? = nil) {
        self.leftReceiver = left
        self.rightReceiver = right
        self.onTick = onTick
        self.statusProvider = statusProvider
        self.statusObserver = statusObserver
    }

    deinit {
        displayLink?.invalidate()
    }

    func setReceivers(left: any VideoFrameReceiving, right: any VideoFrameReceiving) {
        self.leftReceiver = left
        self.rightReceiver = right
        // New receivers ⇒ old frozen frames are stale, drop them so
        // the compositor doesn't show the previous source's frozen
        // image while the new one warms up.
        self.previousLeftFrame = nil
        self.previousRightFrame = nil
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self),
                                 selector: #selector(DisplayLinkProxy.linkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Synchronous tick entry-point exposed for unit tests. Production
    /// code reaches it via the CADisplayLink callback in DisplayLinkProxy.
    func tick(hostTime: CFTimeInterval) {
        let liveLeft = leftReceiver.currentFrame()
        let liveRight = rightReceiver.currentFrame()
        let statuses = statusProvider()

        if let liveLeft { previousLeftFrame = liveLeft }
        if let liveRight { previousRightFrame = liveRight }

        // Resolve per-side displayed frame: prefer the live frame; if
        // it's nil, fall back to the frozen previous frame for
        // .live / .stalled / .reconnecting (so the operator sees the
        // last good image rather than a black eye). For .empty /
        // .connecting, surface nil so the compositor falls through to
        // its black-eye + overlay-handles-it behavior.
        let displayedLeft = displayedFrame(live: liveLeft,
                                           previous: previousLeftFrame,
                                           status: statuses.left)
        let displayedRight = displayedFrame(live: liveRight,
                                            previous: previousRightFrame,
                                            status: statuses.right)

        onTick(StereoFramePair(left: displayedLeft,
                               right: displayedRight,
                               leftStatus: statuses.left,
                               rightStatus: statuses.right,
                               hostTime: hostTime))

        // Surface per-side metadata to the SessionStatus observer.
        // Use the displayed frame's dimensions when available; that
        // matches what the operator is seeing on screen (which is
        // what the resolution-mismatch banner refers to).
        if let observer = statusObserver {
            let leftSize: CGSize? = displayedLeft.map { CGSize(width: $0.width, height: $0.height) }
            let rightSize: CGSize? = displayedRight.map { CGSize(width: $0.width, height: $0.height) }
            // Interlace + alpha flags need to come from the
            // currently-arriving frame metadata, not the frozen one.
            // The watchdog-backed SideStatus carries the receiver's
            // most recent frame metadata; query the receiver directly
            // here for the same reason.
            let leftReceiverInterlaced =
                (leftReceiver as? any WatchableReceiver)?.lastFrameInterlaced ?? false
            let rightReceiverInterlaced =
                (rightReceiver as? any WatchableReceiver)?.lastFrameInterlaced ?? false
            let leftReceiverHasAlpha =
                (leftReceiver as? any WatchableReceiver)?.lastFrameHasAlpha ?? false
            let rightReceiverHasAlpha =
                (rightReceiver as? any WatchableReceiver)?.lastFrameHasAlpha ?? false
            observer(leftSize, rightSize,
                     leftReceiverInterlaced, rightReceiverInterlaced,
                     leftReceiverHasAlpha, rightReceiverHasAlpha)
        }
    }

    /// Decide which frame to put in the StereoFramePair for a side.
    /// See file header for the freeze-frame rationale.
    private func displayedFrame(live: (any VideoFrameSource)?,
                                previous: (any VideoFrameSource)?,
                                status: ReceiverWatchdog.SideStatus) -> (any VideoFrameSource)? {
        if let live { return live }
        switch status {
        case .live, .stalled, .reconnecting:
            return previous
        case .connecting, .empty:
            return nil
        }
    }
}

// MARK: - CADisplayLink trampoline

// CADisplayLink retains its target. Holding the FramePairer here would
// make the pairer outlive its owner; this trampoline keeps the pairer
// weak so deinit semantics are predictable.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: FramePairer?

    init(owner: FramePairer) {
        self.owner = owner
    }

    @objc func linkFired(_ link: CADisplayLink) {
        owner?.tick(hostTime: link.timestamp)
    }
}
