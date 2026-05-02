//  AlignmentStateRestoreTests.swift
//
//  Verifies the slice-#11 hookup between AlignmentState and
//  SessionStore:
//   - Pre-populating a UserDefaults suite with known values means a
//     fresh `AlignmentState(store: SessionStore(defaults: suite))`
//     initializes with those values.
//   - Once the model has finished initializing, assigning a new value
//     to one of its properties writes through to UserDefaults — so a
//     subsequent `AlignmentState` over the same suite sees the
//     updated value.
//   - The init's restore path does NOT immediately re-write the
//     restored values back to UserDefaults (the `_persisting` /
//     `persistsToStore` flag pattern guards against the loop). To
//     exercise this, we record the suite's underlying dictionary
//     before AND after construction; only the keys we explicitly
//     pre-populated should be present, with the same values.
//   - `screenMode` is restored from `defaultScreenModeOnLaunch`, NOT
//     from the persisted last-used `screenMode`. This is the PRD
//     contract — the operator's launch experience matches their
//     preference rather than whatever mode they happened to leave
//     the app in.

import Foundation
import Testing
@testable import stereondi

@MainActor
struct AlignmentStateRestoreTests {

    @MainActor
    private static func withFreshSuite(_ body: (UserDefaults) -> Void) {
        let name = "stereondi.tests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: name) else {
            Issue.record("Failed to create UserDefaults suite \(name)")
            return
        }
        defer {
            suite.removePersistentDomain(forName: name)
        }
        body(suite)
    }

    // MARK: - Restore from pre-populated suite

    @Test
    func restoresConvergenceFineHITAndCropMode() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            store.convergence = 123.4
            store.leftFineHIT = -7.5
            store.rightFineHIT = 8.0
            store.cropMode = .off
            store.swapEyes = true

            let alignment = AlignmentState(store: store)

            #expect(alignment.convergence == 123.4)
            #expect(alignment.leftFineHIT == -7.5)
            #expect(alignment.rightFineHIT == 8.0)
            #expect(alignment.cropMode == .off)
            #expect(alignment.swapEyes == true)
        }
    }

    @Test
    func restoresScreenModeFromDefaultModeOnLaunchPreference() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            // Operator's last in-app session was anaglyph...
            store.screenMode = .anaglyph
            // ...but their preference is to launch in channelTest.
            store.defaultScreenModeOnLaunch = .channelTest

            let alignment = AlignmentState(store: store)

            // The PRD-specified launch experience is the preference,
            // not the last-used mode.
            #expect(alignment.screenMode == .channelTest)
        }
    }

    @Test
    func restoresDefaultsWhenSuiteIsEmpty() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            let alignment = AlignmentState(store: store)
            #expect(alignment.convergence == 0)
            #expect(alignment.leftFineHIT == 0)
            #expect(alignment.rightFineHIT == 0)
            #expect(alignment.cropMode == .auto)
            #expect(alignment.screenMode == .sbs)
            #expect(alignment.swapEyes == false)
        }
    }

    // MARK: - Write-through after init

    @Test
    func assigningConvergenceAfterInitWritesThroughToStore() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            let alignment = AlignmentState(store: store)
            alignment.convergence = 250

            let reader = SessionStore(defaults: suite)
            #expect(reader.convergence == 250)
        }
    }

    @Test
    func assigningCropModeAfterInitWritesThroughToStore() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            let alignment = AlignmentState(store: store)
            alignment.cropMode = .off

            let reader = SessionStore(defaults: suite)
            #expect(reader.cropMode == .off)
        }
    }

    @Test
    func assigningScreenModeAfterInitWritesThroughToStore() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            let alignment = AlignmentState(store: store)
            alignment.screenMode = .anaglyph

            let reader = SessionStore(defaults: suite)
            #expect(reader.screenMode == .anaglyph)
        }
    }

    @Test
    func assigningSwapEyesAfterInitWritesThroughToStore() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            let alignment = AlignmentState(store: store)
            alignment.swapEyes = true

            let reader = SessionStore(defaults: suite)
            #expect(reader.swapEyes == true)
        }
    }

    @Test
    func assigningFineHITAfterInitWritesThroughToStore() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            let alignment = AlignmentState(store: store)
            alignment.leftFineHIT = -3.5
            alignment.rightFineHIT = 4.25

            let reader = SessionStore(defaults: suite)
            #expect(reader.leftFineHIT == -3.5)
            #expect(reader.rightFineHIT == 4.25)
        }
    }

    @Test
    func resetAllWritesZerosThroughToStore() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            store.convergence = 100
            store.leftFineHIT = 50
            store.rightFineHIT = -50
            // cropMode preserved across resetAll, so set it to off
            // to confirm reset does NOT touch it.
            store.cropMode = .off

            let alignment = AlignmentState(store: store)
            alignment.resetAll()

            let reader = SessionStore(defaults: suite)
            #expect(reader.convergence == 0)
            #expect(reader.leftFineHIT == 0)
            #expect(reader.rightFineHIT == 0)
            // Crop preference survived the alignment reset.
            #expect(reader.cropMode == .off)
        }
    }

    // MARK: - Init does not echo restored values back to defaults

    @Test
    func initDoesNotReWriteRestoredValuesToDefaults() {
        // The `persistsToStore` flag is false during init so the
        // restore-time assignments don't immediately re-write the
        // same values back to defaults. Snapshot the suite's
        // dictionary before AND after construction; the only keys
        // present after init should be the ones pre-populated, with
        // their original values, and no new keys should appear.
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            store.convergence = 42

            let before = suite.dictionaryRepresentation()
                .filter { $0.key.hasPrefix("stereondi.") }
            let beforeKeyCount = before.count

            _ = AlignmentState(store: store)

            let after = suite.dictionaryRepresentation()
                .filter { $0.key.hasPrefix("stereondi.") }
            // No new keys appeared during the restore.
            #expect(after.count == beforeKeyCount)
            // The convergence value is unchanged.
            if let val = after["stereondi.alignment.convergence"] as? Double {
                #expect(val == 42)
            } else {
                Issue.record("Expected convergence key still present at 42")
            }
        }
    }
}
