//  SourcePickerSheet.swift
//
//  Modal source picker. Shows the current discovery list (live-updating
//  through the bound DiscoveredSources @Observable) and a manual-entry
//  row for typing an `ndi://host[:port]/StreamName` URL. Selection is
//  written through a binding to NDISource? and the sheet dismisses
//  itself; ContentView's onChange does the actual receiver hookup.

import SwiftUI

struct SourcePickerSheet: View {
    enum Side {
        case left
        case right

        var label: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            }
        }
    }

    let side: Side
    @Binding var selection: NDISource?
    var discovered: DiscoveredSources

    @Environment(\.dismiss) private var dismiss

    @State private var manualURL: String = ""
    @State private var manualError: String?

    var body: some View {
        NavigationStack {
            List {
                discoveredSection

                manualEntrySection

                if discovered.sources.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView()
                            Text("Searching… make sure your iPad is on the same network as your NDI sources.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Pick \(side.label) source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var discoveredSection: some View {
        Section("Discovered") {
            if discovered.sources.isEmpty {
                Text("No sources yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovered.sources, id: \.self) { source in
                    Button {
                        selection = source
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(source.urlAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var manualEntrySection: some View {
        Section("Manual entry") {
            TextField("ndi://host:port/StreamName", text: $manualURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: manualURL) { _, _ in
                    manualError = nil
                }

            Button {
                connectManual()
            } label: {
                Text("Connect")
            }
            .disabled(manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let manualError {
                Text(manualError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func connectManual() {
        guard let parsed = URLParseHelpers.parseNDIURL(manualURL) else {
            manualError = "Expected ndi://host[:port]/StreamName"
            return
        }
        let port = parsed.port ?? 5961
        let urlAddress = "\(parsed.host):\(port)"
        let displayName = "Manual (\(parsed.name))"
        selection = NDISource(name: displayName, urlAddress: urlAddress)
        dismiss()
    }
}
