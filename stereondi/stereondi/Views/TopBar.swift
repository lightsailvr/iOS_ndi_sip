//  TopBar.swift
//
//  Top horizontal bar over the live preview. Shows two source-picker
//  dropdowns (Left, Right), a Swap button between them, and a disabled
//  Settings gear placeholder. Tapping a dropdown opens a
//  SourcePickerSheet bound to that side's selection.
//
//  Slice #3 wires only the Left source through to the live preview;
//  Right is shown so the operator can pre-pick the second source ahead
//  of the dual-receiver / FramePairer slice.
//
//  Auto-hide-after-3s behavior is intentionally deferred to slice #13;
//  this bar is always visible.

import SwiftUI

struct TopBar: View {
    @Bindable var selection: SourceSelection
    var discovered: DiscoveredSources

    @State private var presentingPickerForSide: SourcePickerSheet.Side?

    var body: some View {
        HStack(spacing: 12) {
            sourceButton(side: .left, source: selection.leftSource)

            Button {
                selection.swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .disabled(selection.leftSource == nil || selection.rightSource == nil)
            .accessibilityLabel("Swap left and right")

            sourceButton(side: .right, source: selection.rightSource)

            Spacer(minLength: 8)

            Button(action: {}) {
                Image(systemName: "gear")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .sheet(item: $presentingPickerForSide) { side in
            SourcePickerSheet(
                side: side,
                selection: binding(for: side),
                discovered: discovered
            )
        }
    }

    private func sourceButton(side: SourcePickerSheet.Side, source: NDISource?) -> some View {
        Button {
            presentingPickerForSide = side
        } label: {
            HStack(spacing: 6) {
                Text(source?.name ?? "Pick \(side.label)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Pick \(side.label) source")
    }

    private func binding(for side: SourcePickerSheet.Side) -> Binding<NDISource?> {
        switch side {
        case .left:
            return Binding(
                get: { selection.leftSource },
                set: { selection.leftSource = $0 }
            )
        case .right:
            return Binding(
                get: { selection.rightSource },
                set: { selection.rightSource = $0 }
            )
        }
    }
}

extension SourcePickerSheet.Side: Identifiable {
    var id: String { label }
}
