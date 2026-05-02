//  SessionStore.swift
//
//  UserDefaults-backed persistence seam. The single place every slice
//  reads from / writes to when something needs to survive an app
//  relaunch. Pull the value out at construction time of an @Observable
//  model; write through on every change. The Observable models stay
//  the live source of truth for the UI; SessionStore is the durable
//  shadow that hydrates them on launch and absorbs every later change.
//
//  Why a class with typed properties instead of a key-value blob:
//   - Every field has a single canonical default that lives on the
//     getter (e.g. `convergence` defaults to 0). Callers never see a
//     "missing key" case — the default IS the absence-case.
//   - Enum-valued fields round-trip via `rawValue: String` so the
//     stored representation is greppable and survives reorderings of
//     the enum cases (rawValue is the contract, not the case index).
//   - Favorites round-trip via JSON (Codable). The serialized payload
//     is a single `Data` blob under one key — one favorite added,
//     deleted, or renamed is one Defaults write.
//
//  Why a `defaults: UserDefaults` injectable:
//   - Tests construct `SessionStore(defaults: UserDefaults(suiteName:
//     UUID().uuidString)!)` so per-test runs never pollute (or read)
//     the standard suite. Models that take `store:` in their init can
//     be exercised against a fresh store on every test method.
//
//  Key naming:
//   - All keys live in `private enum Keys` and are prefixed with
//     `stereondi.` and a sub-namespace (`alignment`, `output`,
//     `sources`, `favorites`, `session`). Greppable across the
//     codebase; no collision risk with future iOS framework keys.
//
//  Sanity checks (greppable elsewhere in the repo):
//   - No reference to `UserDefaults.standard` outside this file.
//   - Models in `Models/` consume `SessionStore` directly (passed in
//     via `init(store:)`); favorites and session-reset CRUD UI talks
//     to `SessionStore.shared` for convenience.

import Foundation

@MainActor
final class SessionStore {

    /// Process-wide singleton bound to `UserDefaults.standard`. Tests
    /// construct their own instances over a per-test `UserDefaults
    /// (suiteName:)`; production code uses this one.
    static let shared = SessionStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Sources (last-known L/R)

    /// Last L/R source identifiers — name and URL stored separately so
    /// reconstructing an `NDISource` on launch is a straight pair of
    /// reads. Both nil ⇒ no auto-reconnect attempted (the picker
    /// surfaces normally on first run).
    var lastLeftSourceName: String? {
        get { defaults.string(forKey: Keys.lastLeftSourceName) }
        set { setOptionalString(newValue, forKey: Keys.lastLeftSourceName) }
    }

    var lastLeftSourceURL: String? {
        get { defaults.string(forKey: Keys.lastLeftSourceURL) }
        set { setOptionalString(newValue, forKey: Keys.lastLeftSourceURL) }
    }

    var lastRightSourceName: String? {
        get { defaults.string(forKey: Keys.lastRightSourceName) }
        set { setOptionalString(newValue, forKey: Keys.lastRightSourceName) }
    }

    var lastRightSourceURL: String? {
        get { defaults.string(forKey: Keys.lastRightSourceURL) }
        set { setOptionalString(newValue, forKey: Keys.lastRightSourceURL) }
    }

    // MARK: - Alignment

    var convergence: Double {
        get { defaults.object(forKey: Keys.convergence) as? Double ?? 0 }
        set { defaults.set(newValue, forKey: Keys.convergence) }
    }

    var leftFineHIT: Double {
        get { defaults.object(forKey: Keys.leftFineHIT) as? Double ?? 0 }
        set { defaults.set(newValue, forKey: Keys.leftFineHIT) }
    }

    var rightFineHIT: Double {
        get { defaults.object(forKey: Keys.rightFineHIT) as? Double ?? 0 }
        set { defaults.set(newValue, forKey: Keys.rightFineHIT) }
    }

    var cropMode: CropMode {
        get {
            guard let raw = defaults.string(forKey: Keys.cropMode),
                  let value = CropMode(rawValue: raw) else {
                return .auto
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.cropMode) }
    }

    /// Last-used screen mode. The launch path reads
    /// `defaultScreenModeOnLaunch` instead — this property exists for
    /// tests and for any future "resume in last mode" preference.
    var screenMode: ScreenMode {
        get {
            guard let raw = defaults.string(forKey: Keys.screenMode),
                  let value = ScreenMode(rawValue: raw) else {
                return .sbs
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.screenMode) }
    }

    var swapEyes: Bool {
        get { defaults.object(forKey: Keys.swapEyes) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.swapEyes) }
    }

    /// What `screenMode` is set to at app launch. Per PRD's "default
    /// mode on launch" preference. The Settings sheet binds to this;
    /// `AlignmentState.init(store:)` reads it instead of `screenMode`
    /// so the operator's launch experience matches their preference
    /// rather than whatever mode they happened to leave the app in.
    var defaultScreenModeOnLaunch: ScreenMode {
        get {
            guard let raw = defaults.string(forKey: Keys.defaultScreenModeOnLaunch),
                  let value = ScreenMode(rawValue: raw) else {
                return .sbs
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.defaultScreenModeOnLaunch) }
    }

    // MARK: - Output stream

    var streamName: String {
        get {
            defaults.string(forKey: Keys.streamName)
                ?? OutputStreamConfig.defaultStreamName
        }
        set { defaults.set(newValue, forKey: Keys.streamName) }
    }

    var groups: String {
        get {
            defaults.string(forKey: Keys.groups)
                ?? OutputStreamConfig.defaultGroups
        }
        set { defaults.set(newValue, forKey: Keys.groups) }
    }

    // MARK: - Favorites

    /// Round-tripped via `JSONEncoder` → `Data` → `defaults.set(...)`.
    /// A decode failure returns an empty list rather than throwing —
    /// this lets the app survive a future schema change that drops a
    /// field (the operator can re-save from the working state).
    var favorites: [Favorite] {
        get {
            guard let data = defaults.data(forKey: Keys.favorites) else {
                return []
            }
            return (try? JSONDecoder().decode([Favorite].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.favorites)
            }
        }
    }

    // MARK: - Actions

    /// Clears HIT only — convergence and per-eye fine — and intentionally
    /// preserves sources, favorites, modes, output config. Maps onto
    /// the operator's "reset session" intent: I want the next take to
    /// start from zero parallax but I don't want to re-pick sources.
    func resetSession() {
        defaults.removeObject(forKey: Keys.convergence)
        defaults.removeObject(forKey: Keys.leftFineHIT)
        defaults.removeObject(forKey: Keys.rightFineHIT)
    }

    // MARK: - Helpers

    /// `defaults.set(nil, forKey:)` is a removeObject — explicit removal
    /// keeps the per-key inspector clean and matches the "absent key
    /// → default" model used elsewhere in this file.
    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Keys

    /// Every persisted key in one greppable list. Namespaced
    /// `stereondi.<area>.<field>` so a future framework that also
    /// uses UserDefaults can never collide.
    private enum Keys {
        static let lastLeftSourceName = "stereondi.sources.lastLeftName"
        static let lastLeftSourceURL = "stereondi.sources.lastLeftURL"
        static let lastRightSourceName = "stereondi.sources.lastRightName"
        static let lastRightSourceURL = "stereondi.sources.lastRightURL"

        static let convergence = "stereondi.alignment.convergence"
        static let leftFineHIT = "stereondi.alignment.leftFineHIT"
        static let rightFineHIT = "stereondi.alignment.rightFineHIT"
        static let cropMode = "stereondi.alignment.cropMode"
        static let screenMode = "stereondi.alignment.screenMode"
        static let swapEyes = "stereondi.alignment.swapEyes"
        static let defaultScreenModeOnLaunch = "stereondi.alignment.defaultScreenModeOnLaunch"

        static let streamName = "stereondi.output.streamName"
        static let groups = "stereondi.output.groups"

        static let favorites = "stereondi.favorites.list"
    }
}
