//  FramePairer.swift
//
//  Pulls the latest video frame from each of two VideoFrameReceiving
//  sources (typically NDIReceivers) on a shared CADisplayLink clock and
//  emits StereoFramePair values to a callback.
//
//  Slice #4 scope:
//   - The pair may have either side nil; the compositor draws black on
//     the missing eye. Single-source partial-preview UX (slice #13)
//     adds the "No source / Reconnecting" placeholder.
//   - The CADisplayLink callback runs on the main thread (.main run loop,
//     .common modes) and `currentFrame()` is non-blocking
//     (NDIlib_framesync_capture_video with timeout 0), so the pairer
//     never blocks vsync.
//
//  Testability:
//   - `start()` wires up the display link; tests bypass it and call
//     `tick(hostTime:)` directly with scripted frame arrivals.
//   - The receiver dependency is the `VideoFrameReceiving` protocol, so
//     tests inject fake conformances without touching NDI.

import Foundation
import QuartzCore

@MainActor
final class FramePairer {

    typealias Tick = (StereoFramePair) -> Void

    private(set) var leftReceiver: any VideoFrameReceiving
    private(set) var rightReceiver: any VideoFrameReceiving
    /// Mutable so the MetalPreviewView coordinator can swap in its
    /// own cache-and-redraw closure after the pairer is constructed
    /// (the SwiftUI owner constructs the pairer earlier in the view
    /// hierarchy than the MTKView coordinator exists).
    var onTick: Tick

    private var displayLink: CADisplayLink?

    init(left: any VideoFrameReceiving,
         right: any VideoFrameReceiving,
         onTick: @escaping Tick = { _ in }) {
        self.leftReceiver = left
        self.rightReceiver = right
        self.onTick = onTick
    }

    deinit {
        displayLink?.invalidate()
    }

    func setReceivers(left: any VideoFrameReceiving, right: any VideoFrameReceiving) {
        self.leftReceiver = left
        self.rightReceiver = right
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
        let left = leftReceiver.currentFrame()
        let right = rightReceiver.currentFrame()
        onTick(StereoFramePair(left: left, right: right, hostTime: hostTime))
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
