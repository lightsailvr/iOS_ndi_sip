//  SourcePickerSheet.swift
//
//  Modal source picker. Shows the current discovery list (live-updating
//  through the bound DiscoveredSources @Observable) and a manual-entry
//  row for typing an `ndi://host[:port]/StreamName` URL. Selection
//  writes go through `SourceSelection` directly; ContentView's
//  `.onChange(of: selection.leftSource / .rightSource)` does the
//  actual receiver hookup.
//
//  Slice #11 changes:
//   - Picker takes the full `SourceSelection` (not just a single-side
//     binding) so it can read the OTHER side when saving a favorite
//     and set BOTH sides when applying one.
//   - New "Favorites" section: list of saved Favorites with
//     swipe-to-delete + a "Save current pair as favorite…" row that
//     prompts for a name. Tapping a favorite sets both sources AND
//     the favorite's saved alignment values; ContentView's onChange
//     handlers fire through the receiver-connect path.
//   - Saving requires both sources to be selected — the alignment
//     snapshot is meaningless without two sources to align between.

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
    @Bindable var selection: SourceSelection
    var discovered: DiscoveredSources

    /// Slice #11: applying a favorite touches BOTH sides of selection
    /// and the AlignmentState; saving a favorite reads them.
    @Bindable var favorites: FavoritesViewModel
    @Bindable var alignment: AlignmentState

    @Environment(\.dismiss) private var dismiss

    @State private var manualURL: String = ""
    @State private var manualError: String?

    @State private var savePromptPresented: Bool = false
    @State private var pendingFavoriteName: String = ""

    var body: some View {
        NavigationStack {
            List {
                discoveredSection

                manualEntrySection

                favoritesSection

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
            .alert("Save favorite", isPresented: $savePromptPresented) {
                TextField("Name (e.g. Stage A)", text: $pendingFavoriteName)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {
                    pendingFavoriteName = ""
                }
                Button("Save") {
                    favorites.saveCurrent(name: pendingFavoriteName,
                                          selection: selection,
                                          alignment: alignment)
                    pendingFavoriteName = ""
                }
            } message: {
                Text("Saves both Left and Right sources plus current alignment (convergence, fine HIT, crop).")
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Discovered

    private var discoveredSection: some View {
        Section("Discovered") {
            if discovered.sources.isEmpty {
                Text("No sources yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovered.sources, id: \.self) { source in
                    Button {
                        applySingleSide(source)
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

    // MARK: - Manual entry

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

    // MARK: - Favorites

    private var favoritesSection: some View {
        Section("Favorites") {
            if favorites.favorites.isEmpty {
                Text("No favorites saved yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(favorites.favorites) { favorite in
                    Button {
                        favorites.apply(favorite,
                                        to: selection,
                                        alignment: alignment)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(favorite.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("L: \(favorite.leftSourceName)  ·  R: \(favorite.rightSourceName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    favorites.delete(at: offsets)
                }
            }

            Button {
                pendingFavoriteName = ""
                savePromptPresented = true
            } label: {
                Label("Save current pair as favorite…", systemImage: "star")
            }
            .disabled(canSaveCurrent == false)
        }
    }

    /// Saving a favorite needs both sides present — otherwise the
    /// alignment snapshot is meaningless (no second source to align
    /// against).
    private var canSaveCurrent: Bool {
        selection.leftSource != nil && selection.rightSource != nil
    }

    // MARK: - Routing helpers

    private func applySingleSide(_ source: NDISource) {
        switch side {
        case .left: selection.leftSource = source
        case .right: selection.rightSource = source
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
        applySingleSide(NDISource(name: displayName, urlAddress: urlAddress))
        dismiss()
    }
}
