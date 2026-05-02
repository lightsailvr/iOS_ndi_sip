//  SettingsSheet.swift
//
//  Settings sheet stub. Slice #10 only contributes the two
//  output-stream-related fields (stream name + comma-separated NDI
//  groups). The full Settings sheet polish — NDI® attribution,
//  version info, source-rate vs 60p toggle, etc. — is the larger
//  Settings slice (#14).
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

import SwiftUI

struct SettingsSheet: View {
    @Bindable var output: OutputStreamConfig
    @Environment(\.dismiss) private var dismiss

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
        }
        .presentationDetents([.medium, .large])
    }
}
