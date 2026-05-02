//  SettingsSheet.swift
//
//  Settings sheet stub. Slice #10 contributed the two output-stream-
//  related fields (stream name + comma-separated NDI groups). The
//  full Settings sheet polish — NDI® attribution, version info,
//  source-rate vs 60p toggle, etc. — is the larger Settings slice
//  (#14). Slice #11 adds two persistence-related rows: a "Reset
//  session" destructive action that clears HIT but preserves
//  sources, favorites, modes, and output config; and a "Default mode
//  on launch" picker that controls which `ScreenMode` the app boots
//  into the next time it launches (per PRD's persistence section).
//
//  The TextFields bind directly to the raw `streamName` / `groups`
//  strings on `OutputStreamConfig` (not to the trimmed `effective…`
//  values) so the operator can type freely without losing the cursor
//  on each keystroke. Sanitization happens at read time inside
//  `OutputStreamConfig`, which the SenderPipeline consumes via the
//  ContentView's `.onChange(of: output.effective…)` reconfigure path.
//
//  No `.onSubmit` plumbing is needed — Observation propagates each
//  edit immediately, and ContentView's `.onChange` debounces against
//  the trimmed value so trailing whitespace typed mid-edit doesn't
//  thrash the underlying NDISender restart.
//
//  Why "Reset session" routes through `alignment.resetAll()` AND
//  `store.resetSession()`: `resetAll()` updates the live model
//  (UI snaps to zero immediately) and its didSet write-through clears
//  the persisted convergence / fine values too. `store.resetSession()`
//  is a belt-and-suspenders direct removal — covers the unlikely
//  case where the model isn't bound to the same store the action's
//  view is. In production both paths converge on the same effect.

import SwiftUI

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
                Section("NDI Output") {
                    TextField("Stream name", text: $output.streamName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityLabel("Output stream name")
                    TextField("Groups (comma-separated)", text: $output.groups)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityLabel("NDI groups, comma separated")
                }

                Section("Display") {
                    Picker("Default mode on launch", selection: $defaultModeOnLaunch) {
                        ForEach(ScreenMode.allCases, id: \.self) { mode in
                            Text(displayLabel(for: mode)).tag(mode)
                        }
                    }
                    .accessibilityLabel("Default screen mode on launch")
                }

                Section("Session") {
                    Button(role: .destructive) {
                        // Clears HIT only — convergence and per-eye
                        // fine. Preserves sources, favorites, modes,
                        // output config (per issue #11 acceptance
                        // criteria). Both paths converge on the same
                        // effect; see file header.
                        alignment.resetAll()
                        store.resetSession()
                    } label: {
                        Text("Reset session")
                    }
                    .accessibilityHint("Clears HIT only — sources and favorites are preserved.")
                }

                Section("About") {
                    Text("Settings sheet polish (NDI® attribution, etc.) lands in slice #14.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
        .presentationDetents([.medium, .large])
    }

    private func displayLabel(for mode: ScreenMode) -> String {
        switch mode {
        case .sbs: return "Side by side"
        case .anaglyph: return "Anaglyph"
        case .channelTest: return "Channel test"
        }
    }
}
