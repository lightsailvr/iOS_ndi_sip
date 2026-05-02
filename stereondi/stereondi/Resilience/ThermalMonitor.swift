//  ThermalMonitor.swift
//
//  Slice #13. Monitors the device's thermal state and (as a secondary
//  signal) the rolling frame-time delivered by the screen render
//  loop. Drives a coarse `Mode` (.full / .reduced) that the
//  MetalPreviewView's coordinator consumes to throttle on-screen
//  redraws while leaving the NDI sender path firing every tick.
//
//  Why the coordinator throttles redraws rather than dropping the
//  MTKView's preferredFramesPerSecond:
//   - The PRD requires "NDI output rate unaffected" by thermal
//     degradation. The pairer + sender share the same display-link
//     tick (slice #5), so dropping the MTKView's frame rate would
//     also drop the send rate. Throttling the on-screen
//     `setNeedsDisplay` to alternate ticks instead lets the pairer
//     keep ticking at 60 Hz, the sender keep firing every tick, and
//     the on-screen MTKView only repaint at 30 Hz.
//
//  Mode rules (from the issue):
//    .nominal               → .full
//    .fair                  → .full
//    .serious / .critical   → .reduced
//    plus: rolling-mean of last 60 frame times > 22 ms ⇒ .reduced
//          regardless of thermal state (catches "the GPU is slow but
//          ProcessInfo hasn't woken up yet")
//
//  Recovery hysteresis: once .reduced, stay reduced until BOTH
//   - 5 s of nominal frame times (rolling avg ≤ 22 ms) AND
//   - ProcessInfo.thermalState == .nominal
//  have held continuously. This avoids flapping between modes when
//  the thermal state hovers around the .fair/.serious boundary.
//
//  Testability:
//   - `handleThermalStateChange(_:now:)` and `recordFrameTime(_:now:)`
//     both accept an injectable wall clock (`now:` parameter, default
//     `CACurrentMediaTime()`) so tests script the elapsed-time math
//     deterministically.
//   - `handleThermalStateChange(_:)` accepts the new state directly so
//     tests don't have to mock `ProcessInfo.thermalState` (which has
//     no setter).
//
//  Notification wiring:
//   - In production, `init` subscribes to
//     `ProcessInfo.thermalStateDidChangeNotification` on the main
//     queue and calls `handleThermalStateChange()` (which reads the
//     current state from `ProcessInfo.processInfo.thermalState`).
//   - The observer captures `[weak self]` and hops to MainActor via
//     `Task { @MainActor in ... }` so Swift 6 strict concurrency
//     stays happy.

import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class ThermalMonitor {

    enum Mode: Equatable, Sendable {
        /// 60 fps preview (or whatever the display max is — the MTKView
        /// stays at preferredFramesPerSecond = 0 in this mode).
        case full
        /// 30 fps preview. The sender keeps firing every tick; the
        /// MTKView's `setNeedsDisplay` is skipped on alternate pairer
        /// ticks.
        case reduced
    }

    /// Number of recent frame times averaged for the slow-frame check.
    /// 60 frames at 60 fps ≈ 1 second of history — long enough to
    /// smooth out per-frame jitter, short enough to react within a
    /// second of a sustained slowdown.
    static let frameWindow: Int = 60

    /// Average frame time at which we consider the GPU "can't sustain
    /// 60". 22 ms ⇒ ~45.5 fps achievable, comfortably below the 60 fps
    /// target. Per the issue's specification.
    static let slowFrameThresholdSeconds: CFTimeInterval = 0.022

    /// Continuous "clean" period required before recovering
    /// `.reduced → .full`. Per the issue: "after 5 seconds of nominal
    /// frame times AND `.thermalState == .nominal`".
    static let recoveryWaitSeconds: CFTimeInterval = 5.0

    private(set) var previewMode: Mode = .full

    /// Last-observed `ProcessInfo.ThermalState`. Updated either via
    /// the notification or via the test-only `handleThermalStateChange
    /// (_:)` overload.
    private var thermalState: ProcessInfo.ThermalState

    /// Rolling buffer of recent frame times in seconds. Capped at
    /// `frameWindow` entries (oldest dropped on overflow). The sample
    /// is the wall-clock delta between consecutive pairer ticks
    /// observed by MetalPreviewView's coordinator.
    private var frameTimes: [CFTimeInterval] = []

    /// Wall-clock time at which the current "clean" period started, or
    /// `nil` when conditions are not currently clean. Used to gate the
    /// `.reduced → .full` recovery on a continuous 5 s window of clean
    /// observations.
    private var cleanSinceTime: CFTimeInterval?

    /// Notification observer token. Held strongly so the observer
    /// outlives any local scope; released on deinit.
    private var thermalObserver: NSObjectProtocol?

    /// Production init: reads the current thermal state from
    /// ProcessInfo and subscribes to its change notification. Tests
    /// use the `init(initialThermalState:observeNotifications:)`
    /// overload below to skip the system observer (which a CI Mac
    /// running hot would otherwise fight against).
    convenience init() {
        self.init(initialThermalState: ProcessInfo.processInfo.thermalState,
                  observeNotifications: true)
    }

    /// Designated init. Tests pass `observeNotifications: false` and
    /// an explicit initial thermal state so the monitor's mode
    /// transitions are fully deterministic regardless of the host
    /// machine's actual thermal pressure.
    init(initialThermalState: ProcessInfo.ThermalState,
         observeNotifications: Bool) {
        self.thermalState = initialThermalState
        if observeNotifications {
            self.thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Hop to MainActor explicitly — the notification's
                // queue is .main but the closure is @Sendable; Task
                // hop guarantees isolation under Swift 6 strict
                // concurrency.
                Task { @MainActor [weak self] in
                    self?.handleThermalStateChange()
                }
            }
        }
        // Run an initial recompute so previewMode reflects the
        // supplied initial state at construction time.
        recompute(now: CACurrentMediaTime())
    }

    deinit {
        if let token = thermalObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Notification path. Re-reads `ProcessInfo.thermalState` and
    /// recomputes `previewMode`. Tests call the overload below to
    /// inject a specific state.
    func handleThermalStateChange() {
        handleThermalStateChange(ProcessInfo.processInfo.thermalState,
                                 now: CACurrentMediaTime())
    }

    /// Test entry point: inject a thermal state and an explicit wall
    /// clock. Production code reaches the no-arg overload above via
    /// the notification observer.
    func handleThermalStateChange(_ state: ProcessInfo.ThermalState,
                                  now: CFTimeInterval = CACurrentMediaTime()) {
        thermalState = state
        recompute(now: now)
    }

    /// Records a frame-time sample (in seconds). Drops the oldest
    /// sample once the rolling window is full. Also recomputes
    /// `previewMode` — feeding 60 slow frames in a row should be
    /// sufficient to flip into `.reduced`.
    func recordFrameTime(_ dt: CFTimeInterval,
                         now: CFTimeInterval = CACurrentMediaTime()) {
        // Defensive: a negative or zero dt (first sample with stale
        // lastTickHostTime, or a pairer hiccup) doesn't move the
        // rolling avg in a useful direction.
        guard dt > 0 else {
            recompute(now: now)
            return
        }
        frameTimes.append(dt)
        if frameTimes.count > Self.frameWindow {
            frameTimes.removeFirst(frameTimes.count - Self.frameWindow)
        }
        recompute(now: now)
    }

    /// Test introspection: rolling-mean frame time across the current
    /// window. Returns 0 when the window is empty. Production code
    /// doesn't read this — it's here so tests can sanity-check the
    /// rolling-mean math without poking the private buffer directly.
    var currentRollingMeanFrameTime: CFTimeInterval {
        guard !frameTimes.isEmpty else { return 0 }
        return frameTimes.reduce(0, +) / CFTimeInterval(frameTimes.count)
    }

    // MARK: - Mode computation

    /// Single source of truth for `previewMode`. Called from every
    /// state-changing entry point (init, notification, frame-time
    /// observation, test injection). Idempotent — calling repeatedly
    /// without state changes is a no-op modulo the cleanSinceTime
    /// timeline.
    private func recompute(now: CFTimeInterval) {
        let avgSlow = frameTimes.count >= Self.frameWindow
            && currentRollingMeanFrameTime > Self.slowFrameThresholdSeconds

        let thermalForcesReduced =
            (thermalState == .serious || thermalState == .critical)

        let isReducedDemanded = thermalForcesReduced || avgSlow

        // "Clean" = thermal nominal AND the rolling mean is healthy.
        // .fair without slow frames is NOT clean — we don't want to
        // recover from a forced .reduced just because we're in .fair
        // and the GPU isn't reporting slow frames; the issue is
        // explicit that recovery requires .nominal.
        let isClean = (thermalState == .nominal) && !avgSlow

        if isClean {
            if cleanSinceTime == nil {
                cleanSinceTime = now
            }
        } else {
            cleanSinceTime = nil
        }

        if isReducedDemanded {
            previewMode = .reduced
            return
        }

        if previewMode == .reduced {
            // Recovery gate: continuous clean window of at least
            // `recoveryWaitSeconds`.
            if let start = cleanSinceTime,
               (now - start) >= Self.recoveryWaitSeconds {
                previewMode = .full
            }
            return
        }

        // Already .full and not demanded reduced: stay .full. (.fair
        // without slow frames lands here.)
        previewMode = .full
    }
}
