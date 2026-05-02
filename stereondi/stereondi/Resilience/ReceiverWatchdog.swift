//  ReceiverWatchdog.swift
//
//  Owns the per-second timer that promotes a `.live` receiver to
//  `.stalled` after 2 s without a frame, kicks reconnects on
//  `.stalled` / `.disconnected` receivers every 2 s, and surfaces a
//  per-side `SideStatus` for the SwiftUI overlay.
//
//  The watchdog is the bridge between the ObjC receiver (which knows
//  state + lastFrameTimestamp) and the Swift Observable surface
//  (`leftStatus` / `rightStatus`) consumed by the SwiftUI overlays
//  and by FramePairer for its frozen-frame logic.
//
//  Why a separate type rather than baking it into FramePairer:
//   - The pairer ticks on the display clock (60 Hz typical). Stall
//     detection is a 2 s phenomenon; checking it at the display clock
//     wastes work and (more importantly) couples the pair-output
//     contract to the wall clock. The watchdog ticks at 1 Hz, the
//     pairer reads its result.
//   - Tests for the pairer benefit from being able to script the
//     SideStatus directly via the `WatchableReceiver` seam without
//     standing up the full timer + NDI stack.
//
//  Tests inject a `WatchableReceiver` conformance backed by a fake
//  receiver whose state and `timeSinceLastFrame` are scriptable. The
//  production NDIReceiver conforms via a `nonisolated` extension.
//
//  Threading:
//   - The 1 Hz tick loop is a `Task @MainActor` driven by
//     `Task.sleep`; all reads happen on the main actor (the
//     underlying receiver state + lastFrameTimestamp are atomic, so
//     a main-actor read from a background-thread write is safe).
//   - `kickReconnect` is invoked on the main actor; the receiver's
//     internal `os_unfair_lock` serializes against any background
//     `latestFrame` capture currently in flight.

import Foundation
import Observation

/// Protocol seam over the parts of `NDIReceiver` the watchdog needs.
/// Lets tests inject scriptable doubles without touching the ObjC
/// bridge or the NDI runtime.
///
/// All requirements are `nonisolated` because `NDIReceiver` is an
/// ObjC class without Swift actor isolation. The watchdog reads them
/// from MainActor-isolated code (atomic reads from any thread are
/// safe by construction in NDIReceiver.mm).
protocol WatchableReceiver: AnyObject {
    nonisolated var state: NDIReceiverState { get }
    nonisolated var timeSinceLastFrame: TimeInterval { get }
    nonisolated var lastFrameWidth: Int { get }
    nonisolated var lastFrameHeight: Int { get }
    nonisolated var lastFrameInterlaced: Bool { get }
    nonisolated var lastFrameHasAlpha: Bool { get }

    nonisolated func kickReconnect()
}

// `NSInteger` bridges to `Int` and `BOOL` to `Bool` on every Swift /
// iOS target the project supports, so the ObjC property accessors
// already satisfy the protocol's `Int` / `Bool` requirements directly
// — no shim required. The accessors are atomic reads under the hood
// and are therefore safe from any thread, which matches the protocol's
// `nonisolated` annotation.
extension NDIReceiver: WatchableReceiver {}

@MainActor
@Observable
final class ReceiverWatchdog {

    /// Per-side status as observed at the most recent watchdog tick.
    /// Equatable so SwiftUI can diff cheaply; `Sendable` because it's
    /// a value type with only Sendable payload.
    enum SideStatus: Equatable, Sendable {
        case live(width: Int, height: Int, frameRate: Double)
        /// Receiver is in `.disconnected` and we're attempting
        /// `kickReconnect` every 2 s. UI shows the last good frozen
        /// frame plus a "Reconnecting…" overlay.
        case reconnecting
        /// Receiver is in `.stalled` (≥2 s without a frame, no
        /// disconnect). UI shows the last good frozen frame plus a
        /// "Stalled" overlay (distinct from reconnecting).
        case stalled
        /// Receiver was wired up but never produced a frame, OR the
        /// state machine is in `.connecting`. Treated as "trying to
        /// connect" by the overlay.
        case connecting
        /// No source assigned to this side; the picker should be
        /// surfaced. The compositor renders black on this half.
        case empty
    }

    /// Number of seconds without a frame before a `.live` receiver
    /// flips to `.stalled`. Per PRD / issue: "≥2 s without frame, no
    /// disconnect → stalled".
    static let stallThresholdSeconds: TimeInterval = 2.0

    /// Interval between `kickReconnect` attempts on `.stalled` /
    /// `.disconnected` receivers. Per PRD / issue: "auto-retry every
    /// 2 s".
    static let retryIntervalSeconds: TimeInterval = 2.0

    var leftStatus: SideStatus = .empty
    var rightStatus: SideStatus = .empty

    // Strong references — the watchdog is owned by ContentView at
    // the same level as the receivers (both are SwiftUI @State), so
    // they share the same lifetime. A weak ref would require an
    // upcast through `AnyObject?` (Swift can't store `weak` of an
    // existential without a class anchor), and the upcast would lose
    // the protocol witness; storing the existential strongly is
    // simpler and equivalent in lifetime here.
    private var leftReceiver: (any WatchableReceiver)?
    private var rightReceiver: (any WatchableReceiver)?

    /// Wall-clock of the most recent kickReconnect per side, so the
    /// 2 s retry cadence is honored regardless of how often the timer
    /// fires (we tick at 1 Hz, but a future change to a faster timer
    /// shouldn't accidentally hammer reconnects). Optional so the
    /// "never kicked" case is distinguishable from a kick at t=0.
    private var lastKickLeft: TimeInterval?
    private var lastKickRight: TimeInterval?

    /// Long-lived task driving the 1 Hz tick loop. Cancelled on stop()
    /// or deinit. We use a Task with `Task.sleep` rather than a
    /// `Timer` so the closure captures play nicely with Swift 6
    /// strict-concurrency MainActor isolation (Timer's block API
    /// fights @MainActor capture).
    private var pollTask: Task<Void, Never>?

    private let network: NetworkResilience

    init(left: any WatchableReceiver,
         right: any WatchableReceiver,
         network: NetworkResilience) {
        self.leftReceiver = left
        self.rightReceiver = right
        self.network = network

        // Self-register with the NetworkResilience model so an
        // interface change kicks both receivers.
        network.onInterfaceChange = { [weak self] in
            self?.handleInterfaceChange()
        }
    }

    deinit {
        pollTask?.cancel()
    }

    /// Replace the watched receivers (e.g. when the operator picks new
    /// sources). The old ones are forgotten; the new ones are
    /// evaluated on the next tick. Idempotent at the same identity.
    func setReceivers(left: any WatchableReceiver, right: any WatchableReceiver) {
        self.leftReceiver = left
        self.rightReceiver = right
        // Reset retry bookkeeping so the new receivers get a fresh
        // 2 s window before the watchdog starts kicking them. We
        // record "now" rather than nil so a brand-new receiver that's
        // already disconnected (e.g. invalid URL) doesn't get a free
        // immediate kick before its initial connection attempt has
        // had time to fail.
        let now = Date.timeIntervalSinceReferenceDate
        lastKickLeft = now
        lastKickRight = now
    }

    /// Begin polling at 1 Hz. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        // Do an immediate tick so the SideStatus surfaces on first
        // appear without waiting up to 1 s for the loop's first sleep.
        tick(now: Date.timeIntervalSinceReferenceDate)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                self.tick(now: Date.timeIntervalSinceReferenceDate)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Public for tests: drives one tick of the watchdog state
    /// machine using `now` as the wall clock. Production code reaches
    /// this through the 1 Hz Timer.
    func tick(now: TimeInterval) {
        if let left = leftReceiver {
            leftStatus = evaluate(receiver: left,
                                  side: .left,
                                  now: now,
                                  previous: leftStatus)
        } else {
            leftStatus = .empty
        }
        if let right = rightReceiver {
            rightStatus = evaluate(receiver: right,
                                   side: .right,
                                   now: now,
                                   previous: rightStatus)
        } else {
            rightStatus = .empty
        }
    }

    /// Called from `NetworkResilience.onInterfaceChange` (and exposed
    /// publicly for tests). Kicks both receivers — a WiFi handoff
    /// invalidates the existing FrameSync's UDP sockets, so a clean
    /// recreate is the only reliable recovery.
    func handleInterfaceChange() {
        let now = Date.timeIntervalSinceReferenceDate
        if let left = leftReceiver {
            left.kickReconnect()
            lastKickLeft = now
        }
        if let right = rightReceiver {
            right.kickReconnect()
            lastKickRight = now
        }
    }

    // MARK: - Private

    private enum SideTag {
        case left
        case right
    }

    private func evaluate(receiver: any WatchableReceiver,
                          side: SideTag,
                          now: TimeInterval,
                          previous: SideStatus) -> SideStatus {
        let state = receiver.state

        switch state {
        case .idle:
            return .empty
        case .connecting:
            return .connecting
        case .live:
            // Promote .live → .stalled when the receiver hasn't
            // produced a frame for `stallThresholdSeconds`. The
            // receiver will flip itself back to .live as soon as a
            // fresh frame arrives via `latestFrame`.
            let elapsed = receiver.timeSinceLastFrame
            if elapsed >= Self.stallThresholdSeconds {
                return .stalled
            }
            return .live(width: receiver.lastFrameWidth,
                         height: receiver.lastFrameHeight,
                         frameRate: 0)
        case .stalled:
            kickIfDue(receiver: receiver, side: side, now: now)
            return .stalled
        case .disconnected:
            kickIfDue(receiver: receiver, side: side, now: now)
            return .reconnecting
        @unknown default:
            return previous
        }
    }

    private func kickIfDue(receiver: any WatchableReceiver,
                           side: SideTag,
                           now: TimeInterval) {
        let last: TimeInterval?
        switch side {
        case .left: last = lastKickLeft
        case .right: last = lastKickRight
        }
        // `last == nil` means we've never kicked this side yet — kick
        // immediately (don't make the operator wait 2 s for the first
        // retry on a brand-new disconnect).
        if let last, now - last < Self.retryIntervalSeconds {
            return
        }
        receiver.kickReconnect()
        switch side {
        case .left: lastKickLeft = now
        case .right: lastKickRight = now
        }
    }
}
