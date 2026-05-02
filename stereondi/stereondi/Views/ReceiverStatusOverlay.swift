//  ReceiverStatusOverlay.swift
//
//  Per-eye translucent overlay that appears when a side is in any
//  non-`.live` status. The Metal compositor doesn't draw text — that
//  would require font atlases and a separate text pipeline; SwiftUI
//  handles the labels above the preview at no GPU cost.
//
//  Visual contract:
//   - `.live`: nothing drawn (no overlay).
//   - `.connecting`: spinner + "Connecting…"
//   - `.reconnecting`: spinner + "Reconnecting…" (the side has a
//     frozen previous frame underneath; the overlay sits atop that).
//   - `.stalled`: warning icon + "Stalled" (frozen frame underneath
//     too; the operator should know the source went zombie rather
//     than fully disconnect).
//   - `.empty`: muted "No source" prompt, no spinner.
//
//  The overlay sits in the same coordinate space as the preview's
//  per-eye half. ContentView splits the preview area in two and
//  mounts one of these on each half.

import SwiftUI

struct ReceiverStatusOverlay: View {
    let side: Side
    let status: ReceiverWatchdog.SideStatus

    enum Side: Equatable {
        case left
        case right

        var label: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            }
        }
    }

    var body: some View {
        Group {
            switch status {
            case .live:
                EmptyView()
            case .connecting:
                badge(systemImage: nil,
                      spinner: true,
                      text: "Connecting…",
                      tint: .secondary)
            case .reconnecting:
                badge(systemImage: nil,
                      spinner: true,
                      text: "Reconnecting…",
                      tint: .yellow)
            case .stalled:
                badge(systemImage: "exclamationmark.triangle.fill",
                      spinner: false,
                      text: "Stalled",
                      tint: .orange)
            case .empty:
                badge(systemImage: "video.slash",
                      spinner: false,
                      text: "No \(side.label) source",
                      tint: .secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch status {
        case .live: return "\(side.label) live"
        case .connecting: return "\(side.label) connecting"
        case .reconnecting: return "\(side.label) reconnecting"
        case .stalled: return "\(side.label) stalled"
        case .empty: return "\(side.label) no source"
        }
    }

    private func badge(systemImage: String?,
                       spinner: Bool,
                       text: String,
                       tint: Color) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
