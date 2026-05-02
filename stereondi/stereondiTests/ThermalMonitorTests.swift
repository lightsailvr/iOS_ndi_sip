//  ThermalMonitorTests.swift
//
//  Pure-Swift unit tests for `ThermalMonitor`. Drives the public
//  test entry points — `handleThermalStateChange(_:now:)` and
//  `recordFrameTime(_:now:)` — with an explicit wall clock so the
//  hysteresis math is deterministic.
//
//  No SwiftUI / UIKit / Metal involved. Per the issue: "don't test
//  SwiftUI views directly (PRD says no snapshot tests)".

import Foundation
import Testing
@testable import stereondi

@MainActor
struct ThermalMonitorTests {

    /// Test factory — builds a ThermalMonitor seeded with .nominal
    /// and unsubscribed from system notifications, so the host CI
    /// machine's actual thermal pressure can't perturb the test.
    private static func makeMonitor() -> ThermalMonitor {
        ThermalMonitor(initialThermalState: .nominal,
                       observeNotifications: false)
    }

    // MARK: - Mode transitions for each thermal state

    @Test
    func nominalThermalStateMapsToFull() {
        let monitor = Self.makeMonitor()
        monitor.handleThermalStateChange(.nominal, now: 0)
        #expect(monitor.previewMode == .full)
    }

    @Test
    func fairThermalStateMapsToFull() {
        let monitor = Self.makeMonitor()
        monitor.handleThermalStateChange(.fair, now: 0)
        #expect(monitor.previewMode == .full)
    }

    @Test
    func seriousThermalStateMapsToReduced() {
        let monitor = Self.makeMonitor()
        monitor.handleThermalStateChange(.serious, now: 0)
        #expect(monitor.previewMode == .reduced)
    }

    @Test
    func criticalThermalStateMapsToReduced() {
        let monitor = Self.makeMonitor()
        monitor.handleThermalStateChange(.critical, now: 0)
        #expect(monitor.previewMode == .reduced)
    }

    // MARK: - Frame-time-trigger test

    @Test
    func slowFrameTimesPromoteToReducedEvenWhenThermalStateIsFair() {
        let monitor = Self.makeMonitor()
        // Pin the thermal side to .fair so the only signal driving
        // .reduced is the rolling frame-time mean.
        monitor.handleThermalStateChange(.fair, now: 0)
        #expect(monitor.previewMode == .full)

        // Feed a full window of slow frames (25 ms each → > 22 ms
        // threshold). The ThermalMonitor only tips on a FULL window
        // of samples; partial windows return .full so a transient
        // hiccup at app launch doesn't flip the mode.
        for i in 0..<ThermalMonitor.frameWindow {
            monitor.recordFrameTime(0.025, now: 0.025 * Double(i + 1))
        }
        #expect(monitor.previewMode == .reduced)
    }

    @Test
    func fastFrameTimesAloneStayFullUnderFairThermalState() {
        let monitor = Self.makeMonitor()
        monitor.handleThermalStateChange(.fair, now: 0)
        for i in 0..<ThermalMonitor.frameWindow {
            // 16 ms ≈ 62 fps — well below the 22 ms slow threshold.
            monitor.recordFrameTime(0.016, now: 0.016 * Double(i + 1))
        }
        #expect(monitor.previewMode == .full)
    }

    @Test
    func partialWindowOfSlowFramesDoesNotPromoteToReduced() {
        // The rolling mean only applies once the window is full —
        // slice #13 takes "60 frames" as the minimum sample size so a
        // single janky frame at app launch can't flip the mode.
        let monitor = Self.makeMonitor()
        monitor.handleThermalStateChange(.fair, now: 0)
        for i in 0..<10 {
            monitor.recordFrameTime(0.030, now: 0.030 * Double(i + 1))
        }
        #expect(monitor.previewMode == .full)
    }

    // MARK: - Hysteresis test

    @Test
    func recoveringFromReducedRequiresFiveSecondsOfNominalAndCleanFrames() {
        let monitor = Self.makeMonitor()

        // Force into .reduced via the thermal side.
        monitor.handleThermalStateChange(.serious, now: 0)
        #expect(monitor.previewMode == .reduced)

        // Move thermal back to .nominal AND start feeding fast frames.
        // The recovery wait is 5 s — at 4.99 s of clean observations
        // we should still be .reduced.
        monitor.handleThermalStateChange(.nominal, now: 0)
        // Fill the rolling window with fast frames so the secondary
        // signal is also clean.
        for i in 0..<ThermalMonitor.frameWindow {
            monitor.recordFrameTime(0.016, now: 0.016 * Double(i + 1))
        }
        // The clean window opened at the .nominal handover (now=0).
        // recordFrameTime calls don't advance the recovery clock past
        // their own `now`; advance the clock to just under 5 s and
        // verify we're still .reduced.
        monitor.recordFrameTime(0.016, now: 4.99)
        #expect(monitor.previewMode == .reduced)

        // Past the 5 s window, recovery happens.
        monitor.recordFrameTime(0.016, now: 5.5)
        #expect(monitor.previewMode == .full)
    }

    @Test
    func fastFramesAloneDoNotRecoverFromReducedWhileThermalStateRemainsSerious() {
        let monitor = Self.makeMonitor()
        monitor.handleThermalStateChange(.serious, now: 0)
        #expect(monitor.previewMode == .reduced)

        // Feed plenty of fast frames over a long elapsed window.
        // Without a thermal handover to .nominal, the recovery gate
        // never opens.
        for i in 0..<ThermalMonitor.frameWindow * 2 {
            monitor.recordFrameTime(0.014, now: 0.014 * Double(i + 1))
        }
        // 14 ms × 120 = 1.68 s — well under 5 s, but advance the
        // clock further to make the point that thermal state alone
        // gates recovery.
        monitor.recordFrameTime(0.014, now: 30.0)
        #expect(monitor.previewMode == .reduced)
    }

    @Test
    func slowFrameInRecoveryWindowResetsTheCleanCounter() {
        let monitor = Self.makeMonitor()
        // Get into .reduced via slow frames under .fair thermal state
        // (the secondary signal).
        monitor.handleThermalStateChange(.fair, now: 0)
        for i in 0..<ThermalMonitor.frameWindow {
            monitor.recordFrameTime(0.025, now: 0.025 * Double(i + 1))
        }
        #expect(monitor.previewMode == .reduced)

        // Hand thermal to .nominal and start feeding fast frames so
        // the rolling mean drops back below 22 ms.
        monitor.handleThermalStateChange(.nominal, now: 1.5)
        for i in 0..<ThermalMonitor.frameWindow {
            monitor.recordFrameTime(0.014, now: 1.5 + 0.014 * Double(i + 1))
        }
        // 4 s into the clean window — close to but under 5 s.
        monitor.recordFrameTime(0.014, now: 5.4)
        #expect(monitor.previewMode == .reduced)

        // Inject a single very-slow frame to bump the rolling mean
        // back over 22 ms (the window contains 60 entries; one big
        // outlier at this size matters: 25 × 1 + 14 × 59 ≈ 14.18 ms,
        // still under 22 ms — we'd need many slow frames). Bump in
        // a flurry of slow frames to cleanly cross the threshold.
        for i in 0..<ThermalMonitor.frameWindow {
            monitor.recordFrameTime(0.030, now: 5.5 + 0.030 * Double(i + 1))
        }
        // The rolling mean is now 30 ms, the clean window collapsed
        // (avgSlow = true ⇒ NOT clean), and we're forcibly demanded
        // .reduced again.
        #expect(monitor.previewMode == .reduced)
    }

    // MARK: - Sanity / introspection

    @Test
    func defaultPreviewModeIsFull() {
        let monitor = Self.makeMonitor()
        #expect(monitor.previewMode == .full)
    }

    @Test
    func zeroOrNegativeFrameTimeIsIgnoredInRollingMean() {
        let monitor = Self.makeMonitor()
        monitor.handleThermalStateChange(.fair, now: 0)
        // A negative dt could arrive on the very first tick if the
        // Coordinator's lastTickHostTime is uninitialized; the
        // monitor must not crash and the rolling mean must remain
        // empty.
        monitor.recordFrameTime(-0.5, now: 0)
        monitor.recordFrameTime(0, now: 0)
        #expect(monitor.currentRollingMeanFrameTime == 0)
        #expect(monitor.previewMode == .full)
    }
}
