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
//
//  Slice #13 additions:
//   - The `.empty` case becomes a tappable button that calls back
//     into ContentView to present the SourcePickerSheet for that
//     side. Composes cleanly with the EmptyState surface (which
//     handles the both-sides-nil case): the per-half overlay covers
//     "single-source partial preview" — one eye live, the other half
//     showing "No source — tap to pick".
//   - The "live" eye still renders no overlay (so a single live eye
//     fills its half with the actual frame; the other half gets the
//     tap-to-pick prompt).

import SwiftUI

struct ReceiverStatusOverlay: View {
    let side: Side
    let status: ReceiverWatchdog.SideStatus
    /// Slice #13: invoked when the operator taps the `.empty` overlay
    /// (single-source partial preview case). ContentView wires this
    /// to set `pickerSide = .left` / `.right`. nil disables the tap
    /// (the overlay still shows "No <side> source" text).
    var onTapEmpty: (() -> Void)? = nil

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
                emptyOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Single-source partial preview overlay: a tappable button that
    /// covers the missing half. The whole half is hit-testable (per
    /// the issue: "Place a button covering that half") so the
    /// operator can tap anywhere in the dark side to surface the
    /// picker. When `onTapEmpty` is nil the overlay is informational
    /// only (the both-sides-nil path uses the dedicated EmptyState
    /// surface, not this).
    @ViewBuilder
    private var emptyOverlay: some View {
        if let onTapEmpty {
            Button(action: onTapEmpty) {
                ZStack {
                    Color.black.opacity(0.001)
                    badge(systemImage: "video.slash",
                          spinner: false,
                          text: "No \(side.label) source — tap to pick",
                          tint: .secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Pick \(side.label) source")
            .accessibilityHint("No source assigned to the \(side.label.lowercased()) eye. Tap to pick a source.")
        } else {
            badge(systemImage: "video.slash",
                  spinner: false,
                  text: "No \(side.label) source",
                  tint: .secondary)
        }
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
