//  SessionStoreTests.swift
//
//  Round-trip tests for every persisted field on SessionStore. The
//  shape is uniform: construct a per-test SessionStore over a fresh
//  `UserDefaults(suiteName: UUID().uuidString)!`, write a value, read
//  it back through a brand-new SessionStore over the SAME suite, and
//  assert equality. Re-instantiating the store in between proves the
//  value is actually durable in the underlying Defaults plist rather
//  than just sitting in an in-memory cache on the original instance.
//
//  Per-test suites: never share a UserDefaults across tests, never
//  pollute the standard suite. Each test gets a brand-new UUID-named
//  suite, which iOS allocates lazily and which is removed via
//  `removePersistentDomain(forName:)` at the end of each test through
//  the `withFreshSuite(_:)` helper.
//
//  Slice #11 acceptance criteria covered here:
//   - "Round-trip unit tests for every field through UserDefaults"
//   - "resetSession() clears HIT but preserves sources, favorites,
//      mode, output config"

import Foundation
import Testing
@testable import stereondi

@MainActor
struct SessionStoreTests {

    // MARK: - Per-test suite helpers

    /// Construct a fresh UserDefaults suite, run the test against it,
    /// then tear the suite down so the iOS plist doesn't accumulate
    /// orphan suites across runs. The suite name uses a UUID so
    /// parallel test runs never collide on the same suite name.
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

    // MARK: - Sources

    @Test
    func roundTripLastLeftSource() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.lastLeftSourceName = "RIG-A (Cam-L)"
            writer.lastLeftSourceURL = "10.0.0.5:5961"

            let reader = SessionStore(defaults: suite)
            #expect(reader.lastLeftSourceName == "RIG-A (Cam-L)")
            #expect(reader.lastLeftSourceURL == "10.0.0.5:5961")
        }
    }

    @Test
    func roundTripLastRightSource() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.lastRightSourceName = "RIG-A (Cam-R)"
            writer.lastRightSourceURL = "10.0.0.6:5961"

            let reader = SessionStore(defaults: suite)
            #expect(reader.lastRightSourceName == "RIG-A (Cam-R)")
            #expect(reader.lastRightSourceURL == "10.0.0.6:5961")
        }
    }

    @Test
    func sourceNamesDefaultToNilOnEmptySuite() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.lastLeftSourceName == nil)
            #expect(store.lastLeftSourceURL == nil)
            #expect(store.lastRightSourceName == nil)
            #expect(store.lastRightSourceURL == nil)
        }
    }

    @Test
    func clearingSourceNameRemovesIt() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.lastLeftSourceName = "RIG-A"
            writer.lastLeftSourceName = nil

            let reader = SessionStore(defaults: suite)
            #expect(reader.lastLeftSourceName == nil)
        }
    }

    // MARK: - Alignment

    @Test
    func roundTripConvergence() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.convergence = 47.5

            let reader = SessionStore(defaults: suite)
            #expect(reader.convergence == 47.5)
        }
    }

    @Test
    func convergenceDefaultsToZero() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.convergence == 0)
        }
    }

    @Test
    func roundTripFineHIT() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.leftFineHIT = -12.3
            writer.rightFineHIT = 8.75

            let reader = SessionStore(defaults: suite)
            #expect(reader.leftFineHIT == -12.3)
            #expect(reader.rightFineHIT == 8.75)
        }
    }

    @Test
    func fineHITDefaultsToZero() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.leftFineHIT == 0)
            #expect(store.rightFineHIT == 0)
        }
    }

    @Test
    func roundTripCropMode() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.cropMode = .off

            let reader = SessionStore(defaults: suite)
            #expect(reader.cropMode == .off)
        }
    }

    @Test
    func cropModeDefaultsToAuto() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.cropMode == .auto)
        }
    }

    @Test
    func roundTripScreenMode() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.screenMode = .anaglyph

            let reader = SessionStore(defaults: suite)
            #expect(reader.screenMode == .anaglyph)
        }
    }

    @Test
    func screenModeDefaultsToSbS() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.screenMode == .sbs)
        }
    }

    @Test
    func roundTripSwapEyes() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.swapEyes = true

            let reader = SessionStore(defaults: suite)
            #expect(reader.swapEyes == true)
        }
    }

    @Test
    func swapEyesDefaultsToFalse() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.swapEyes == false)
        }
    }

    @Test
    func roundTripDefaultScreenModeOnLaunch() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.defaultScreenModeOnLaunch = .channelTest

            let reader = SessionStore(defaults: suite)
            #expect(reader.defaultScreenModeOnLaunch == .channelTest)
        }
    }

    @Test
    func defaultScreenModeOnLaunchDefaultsToSbS() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.defaultScreenModeOnLaunch == .sbs)
        }
    }

    // MARK: - Output stream

    @Test
    func roundTripStreamName() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.streamName = "Stage A 3D"

            let reader = SessionStore(defaults: suite)
            #expect(reader.streamName == "Stage A 3D")
        }
    }

    @Test
    func streamNameDefaultsToOutputStreamConfigDefault() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.streamName == OutputStreamConfig.defaultStreamName)
        }
    }

    @Test
    func roundTripGroups() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.groups = "Public, Studio2"

            let reader = SessionStore(defaults: suite)
            #expect(reader.groups == "Public, Studio2")
        }
    }

    @Test
    func groupsDefaultsToOutputStreamConfigDefault() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.groups == OutputStreamConfig.defaultGroups)
        }
    }

    // MARK: - Favorites (JSON round-trip)

    @Test
    func favoritesDefaultsToEmptyArray() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            #expect(store.favorites.isEmpty)
        }
    }

    @Test
    func roundTripSingleFavorite() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            let id = UUID()
            let favorite = Favorite(
                id: id,
                name: "Stage A",
                leftSourceName: "RIG-A (Cam-L)",
                leftSourceURL: "10.0.0.5:5961",
                rightSourceName: "RIG-A (Cam-R)",
                rightSourceURL: "10.0.0.6:5961",
                convergence: 47.5,
                leftFineHIT: -2.0,
                rightFineHIT: 1.5,
                cropMode: .off
            )
            writer.favorites = [favorite]

            let reader = SessionStore(defaults: suite)
            #expect(reader.favorites.count == 1)
            guard let restored = reader.favorites.first else { return }
            #expect(restored.id == id)
            #expect(restored.name == "Stage A")
            #expect(restored.leftSourceName == "RIG-A (Cam-L)")
            #expect(restored.leftSourceURL == "10.0.0.5:5961")
            #expect(restored.rightSourceName == "RIG-A (Cam-R)")
            #expect(restored.rightSourceURL == "10.0.0.6:5961")
            #expect(restored.convergence == 47.5)
            #expect(restored.leftFineHIT == -2.0)
            #expect(restored.rightFineHIT == 1.5)
            #expect(restored.cropMode == .off)
        }
    }

    @Test
    func roundTripMultipleFavoritesPreservesOrder() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            let a = Favorite(name: "A",
                             leftSourceName: "L1", leftSourceURL: "u1",
                             rightSourceName: "R1", rightSourceURL: "v1",
                             convergence: 10, leftFineHIT: 0, rightFineHIT: 0,
                             cropMode: .auto)
            let b = Favorite(name: "B",
                             leftSourceName: "L2", leftSourceURL: "u2",
                             rightSourceName: "R2", rightSourceURL: "v2",
                             convergence: -5, leftFineHIT: 1, rightFineHIT: -1,
                             cropMode: .off)
            let c = Favorite(name: "C",
                             leftSourceName: "L3", leftSourceURL: "u3",
                             rightSourceName: "R3", rightSourceURL: "v3",
                             convergence: 0, leftFineHIT: 0, rightFineHIT: 0,
                             cropMode: .auto)
            writer.favorites = [a, b, c]

            let reader = SessionStore(defaults: suite)
            #expect(reader.favorites.map(\.name) == ["A", "B", "C"])
            #expect(reader.favorites[0].id == a.id)
            #expect(reader.favorites[1].id == b.id)
            #expect(reader.favorites[2].id == c.id)
            #expect(reader.favorites[1].cropMode == .off)
        }
    }

    @Test
    func clearingFavoritesRoundTripsEmpty() {
        Self.withFreshSuite { suite in
            let writer = SessionStore(defaults: suite)
            writer.favorites = [
                Favorite(name: "X",
                         leftSourceName: "L", leftSourceURL: "u",
                         rightSourceName: "R", rightSourceURL: "v",
                         convergence: 0, leftFineHIT: 0, rightFineHIT: 0,
                         cropMode: .auto)
            ]
            writer.favorites = []

            let reader = SessionStore(defaults: suite)
            #expect(reader.favorites.isEmpty)
        }
    }

    // MARK: - resetSession

    @Test
    func resetSessionClearsHITButPreservesEverythingElse() {
        Self.withFreshSuite { suite in
            let store = SessionStore(defaults: suite)
            // Populate every persisted field with a non-default value
            // so we can prove reset only touches HIT.
            store.lastLeftSourceName = "RIG-A (Cam-L)"
            store.lastLeftSourceURL = "10.0.0.5:5961"
            store.lastRightSourceName = "RIG-A (Cam-R)"
            store.lastRightSourceURL = "10.0.0.6:5961"
            store.convergence = 47.5
            store.leftFineHIT = -2
            store.rightFineHIT = 1.5
            store.cropMode = .off
            store.screenMode = .anaglyph
            store.swapEyes = true
            store.defaultScreenModeOnLaunch = .anaglyph
            store.streamName = "Stage A 3D"
            store.groups = "Public, Studio2"
            store.favorites = [
                Favorite(name: "X",
                         leftSourceName: "L", leftSourceURL: "u",
                         rightSourceName: "R", rightSourceURL: "v",
                         convergence: 10, leftFineHIT: 0, rightFineHIT: 0,
                         cropMode: .auto)
            ]

            store.resetSession()

            // Reread via a fresh SessionStore so we're testing
            // durability on disk, not in-memory state of `store`.
            let reader = SessionStore(defaults: suite)

            // HIT cleared.
            #expect(reader.convergence == 0)
            #expect(reader.leftFineHIT == 0)
            #expect(reader.rightFineHIT == 0)

            // Sources preserved.
            #expect(reader.lastLeftSourceName == "RIG-A (Cam-L)")
            #expect(reader.lastLeftSourceURL == "10.0.0.5:5961")
            #expect(reader.lastRightSourceName == "RIG-A (Cam-R)")
            #expect(reader.lastRightSourceURL == "10.0.0.6:5961")

            // Modes preserved.
            #expect(reader.cropMode == .off)
            #expect(reader.screenMode == .anaglyph)
            #expect(reader.swapEyes == true)
            #expect(reader.defaultScreenModeOnLaunch == .anaglyph)

            // Output config preserved.
            #expect(reader.streamName == "Stage A 3D")
            #expect(reader.groups == "Public, Studio2")

            // Favorites preserved.
            #expect(reader.favorites.count == 1)
            #expect(reader.favorites.first?.name == "X")
        }
    }
}
