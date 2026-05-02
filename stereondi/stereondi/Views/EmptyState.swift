//  EmptyState.swift
//
//  Slice #13. Full-screen "you have no sources" prompt shown when
//  both `selection.leftSource` and `selection.rightSource` are nil
//  AND the discovery + silent-auto-reconnect grace window has
//  elapsed (no "false empty" flash on launch — see ContentView's
//  `showEmptyState` gate).
//
//  Replaces slice #11's "Pick Left and Right sources from the top
//  bar" overlay. The two large pick buttons here funnel into the
//  same `pickerSide` Binding that the TopBar uses, so the operator's
//  source-pick flow lands in the same SourcePickerSheet regardless
//  of which surface they tapped.
//
//  Per the issue's copy:
//    [ Camera icon ]
//    "No sources connected"
//    "Pick a left and right NDI source to start previewing."
//
//    [Pick Left source] [Pick Right source]   (large buttons)
//
//    (small text)
//    "Make sure your iPad and the NDI cameras are on the same Wi-Fi network."

import SwiftUI

struct EmptyState: View {
    @Binding var pickerSide: SourcePickerSheet.Side?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "video.slash")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("No sources connected")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Pick a left and right NDI source to start previewing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                pickButton(side: .left)
                pickButton(side: .right)
            }

            Text("Make sure your iPad and the NDI cameras are on the same Wi-Fi network.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 560)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func pickButton(side: SourcePickerSheet.Side) -> some View {
        Button {
            pickerSide = side
        } label: {
            Label("Pick \(side.label) source", systemImage: side.iconName)
                .font(.body.weight(.semibold))
                .frame(minWidth: 180)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel("Pick \(side.label) source")
    }
}

extension SourcePickerSheet.Side {
    /// SF Symbol name shorthand used by EmptyState's pick buttons.
    /// Kept on the Side enum so future surfaces (StatusRow, picker
    /// titles) can reuse the same glyphs without duplicating the
    /// mapping.
    var iconName: String {
        switch self {
        case .left: return "arrow.left.to.line"
        case .right: return "arrow.right.to.line"
        }
    }
}
