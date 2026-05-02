//  SettingsSheet.swift
//
//  Slice #14 reorganizes the Settings sheet into the four sections
//  required by the issue: Network (NDI output stream identity),
//  Display (default-mode-on-launch + on-screen toggles that aren't
//  bound to gestures), Session (Reset session destructive action),
//  About (NDI® attribution + version info).
//
//  History:
//   - Slice #10 introduced the stub with the two output-stream fields.
//   - Slice #11 added the "Reset session" action and the
//     "Default mode on launch" picker. Both routed through the same
//     `SessionStore` + `AlignmentState` references they still use.
//   - Slice #14 (this slice) finishes the polish: renames "NDI Output"
//     → "Network" per the issue, surfaces Channel test + Swap eyes in
//     the Display section so operators have a non-gesture path to
//     them, and turns the About section from a placeholder into the
//     real NDI® attribution + version block (PRD's "Further Notes" →
//     "NDI license attribution" requirement).
//
//  TextField bindings still target the raw `streamName` / `groups`
//  strings on `OutputStreamConfig` (not the trimmed `effective…`
//  values) so the cursor / keyboard behavior is unsurprising;
//  sanitization happens at read time inside `OutputStreamConfig`.
//
//  "Reset session" routes through `alignment.resetAll()` AND
//  `store.resetSession()` for belt-and-suspenders parity with the
//  slice #11 wiring — `resetAll()` updates the live model (UI snaps
//  to zero immediately) and its didSet write-through clears the
//  persisted convergence / fine values too; `store.resetSession()`
//  is a direct removal so even if the model isn't bound to the same
//  store the action's view is, the persisted values still clear.
//
//  Drag-down dismiss is the default sheet behavior; nothing to do.

import Darwin
import SwiftUI
import UIKit

struct SettingsSheet: View {
    @Bindable var output: OutputStreamConfig
    @Bindable var alignment: AlignmentState
    let store: SessionStore

    @Environment(\.dismiss) private var dismiss

    /// Local mirror of the persisted preference. SwiftUI Picker
    /// requires a `Binding`; we read from `store` on appear and write
    /// back through onChange so the value persists immediately
    /// regardless of whether the operator dismisses the sheet.
    @State private var defaultModeOnLaunch: ScreenMode = .sbs

    var body: some View {
        NavigationStack {
            Form {
                networkSection
                displaySection
                sessionSection
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                defaultModeOnLaunch = store.defaultScreenModeOnLaunch
            }
            .onChange(of: defaultModeOnLaunch) { _, newValue in
                store.defaultScreenModeOnLaunch = newValue
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Network

    private var networkSection: some View {
        Section("Network") {
            TextField("Stream name", text: $output.streamName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityLabel("Output stream name")
            TextField("Groups (comma-separated)", text: $output.groups)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityLabel("NDI groups, comma separated")
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            Picker("Default mode on launch", selection: $defaultModeOnLaunch) {
                ForEach(ScreenMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityLabel("Default screen mode on launch")

            // Surfaced here for operators who can't (or don't want to)
            // hit the TopBar's segmented control mid-take. Swap eyes
            // is a no-op outside anaglyph mode by AlignmentState
            // contract; we leave it enabled here so the operator can
            // pre-set it before flipping into anaglyph.
            Toggle("Swap eyes (Anaglyph)", isOn: $alignment.swapEyes)
                .accessibilityHint("Swaps the red and cyan eye assignment in anaglyph mode.")

            // Channel test mode (solid red on left, solid cyan on
            // right) verifies the operator's anaglyph glasses are
            // oriented correctly. Tapping flips the iPad screen into
            // channel-test mode and dismisses; the NDI output is
            // unaffected (always SbS by StereoCompositor contract).
            Button {
                alignment.screenMode = .channelTest
                dismiss()
            } label: {
                HStack {
                    Text("Channel test")
                    Spacer()
                    Image(systemName: "checkerboard.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("Switches the iPad screen to a solid red / cyan channel-test pattern.")
        }
    }

    // MARK: - Session

    private var sessionSection: some View {
        Section("Session") {
            Button(role: .destructive) {
                // Clears HIT only — convergence and per-eye fine.
                // Preserves sources, favorites, modes, output config
                // (per issue #11 acceptance criteria). Both paths
                // converge on the same effect; see file header.
                alignment.resetAll()
                store.resetSession()
            } label: {
                Text("Reset session")
            }
            .accessibilityHint("Clears HIT only — sources and favorites are preserved.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App version", value: Self.appVersion)
            LabeledContent("Build", value: Self.buildNumber)
            LabeledContent("iOS", value: Self.iosVersion)
            LabeledContent("iPad model", value: Self.deviceModelIdentifier)
                .font(.footnote)
            LabeledContent("NDI runtime", value: NDIRuntime.version())
            NavigationLink("NDI® attribution") {
                NDIAttributionScreen()
            }
            .accessibilityHint("Opens the NDI trademark and SDK license attribution.")
        }
    }

    // MARK: - About helpers

    /// CFBundleShortVersionString — the user-facing marketing version
    /// (e.g. "1.0"). Falls back to "—" when the Info.plist key is
    /// missing in a dev build.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
    }

    /// CFBundleVersion — the build number (e.g. "42"). Same fallback
    /// strategy as `appVersion`.
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
    }

    /// `UIDevice.current.systemVersion` — the iOS / iPadOS version
    /// the app is currently running on (e.g. "17.4").
    static var iosVersion: String {
        UIDevice.current.systemVersion
    }

    /// Hardware identifier from sysctl (e.g. "iPad13,8" for an 11"
    /// iPad Pro M1). Used as a small-text supplementary line so a
    /// support bug report carries enough info to identify the device
    /// without the operator having to dig through Settings → General.
    static var deviceModelIdentifier: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "—" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}
