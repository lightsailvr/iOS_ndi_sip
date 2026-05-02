//  StatusRow.swift
//
//  Slice #13. Per-eye status row sitting just below the TopBar:
//  source name, resolution, frame rate, and a colored connection-state
//  dot. Two columns (left side / right side); each column reads from
//  `SourceSelection` for the operator-picked NDISource name and from
//  `ReceiverWatchdog.SideStatus` for the live dimensions / framerate /
//  state.
//
//  Per the issue:
//    Left:  RIG-A (Cam-L)    1920×1080 @ 59.94 fps    ● Live
//    Right: RIG-A (Cam-R)    1920×1080 @ 59.94 fps    ● Reconnecting
//
//  The status dot color reflects state:
//   .live          → green
//   .connecting    → amber
//   .reconnecting  → amber
//   .stalled       → red
//   .disconnected  → red  (surfaced as .reconnecting via the watchdog
//                          so the operator sees the active recovery
//                          attempt, NOT a dead-source label)
//   .empty         → gray
//
//  The actual `.disconnected` state never reaches this view because
//  `ReceiverWatchdog.evaluate(...)` collapses it into `.reconnecting`
//  for the overlay/status surface — the operator only cares that we're
//  trying to reconnect, not the underlying transport state. The mapping
//  in `dotColor(for:)` covers `.reconnecting` red; `.disconnected` is
//  documented above as a not-actually-seen state for completeness.
//
//  Auto-hide is composed at the ContentView level via the
//  `chromeVisible` state owned there (the single timer also drives
//  the TopBar's visibility). The bottom bar is intentionally
//  unaffected — convergence is always reachable per PRD user story 24.
//
//  Formatting (frame-rate rounding, "No source" empty case) is
//  factored into `StatusRowFormatter` below so the unit tests can
//  exercise the strings without standing up SwiftUI.

import SwiftUI

struct StatusRow: View {
    var selection: SourceSelection
    var watchdog: ReceiverWatchdog?

    var body: some View {
        HStack(spacing: 16) {
            cell(side: .left,
                 source: selection.leftSource,
                 status: watchdog?.leftStatus ?? .empty)
            Divider().frame(height: 18)
            cell(side: .right,
                 source: selection.rightSource,
                 status: watchdog?.rightStatus ?? .empty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func cell(side: SourcePickerSheet.Side,
                      source: NDISource?,
                      status: ReceiverWatchdog.SideStatus) -> some View {
        HStack(spacing: 8) {
            Text(side.shortLabel + ":")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(StatusRowFormatter.sourceLabel(name: source?.name))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            Text(StatusRowFormatter.metricsLabel(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Circle()
                .fill(StatusRowFormatter.dotColor(for: status))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(StatusRowFormatter.stateLabel(for: status))
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StatusRowFormatter.accessibilityLabel(
            side: side,
            sourceName: source?.name,
            status: status))
    }
}

private extension SourcePickerSheet.Side {
    /// "L" / "R" — the StatusRow uses the short form to keep both
    /// columns visible on the iPad's landscape width without
    /// truncating the source name.
    var shortLabel: String {
        switch self {
        case .left: return "L"
        case .right: return "R"
        }
    }
}

// MARK: - Formatting helpers

/// Pure string + Color helpers for the StatusRow. Lifted out of the
/// SwiftUI view so `StatusRowFormattingTests.swift` can drive them
/// without standing up SwiftUI, MetalKit, or the NDI bridge.
enum StatusRowFormatter {

    /// Source-name cell. `nil` (no source assigned) collapses to a
    /// muted "No source" — matches the `.empty` state surfaced by the
    /// watchdog when the operator hasn't picked anything for that side.
    static func sourceLabel(name: String?) -> String {
        guard let name, !name.isEmpty else { return "No source" }
        return name
    }

    /// Resolution + framerate cell, e.g. "1920×1080 @ 60.0 fps".
    /// Rendered only for `.live`; other statuses return an empty
    /// string so the row collapses to the source name + state text.
    /// Frame rate is shown to one decimal place ("60.0 fps", "59.9 fps")
    /// — picked over "59.94 fps" because the operator-visible value
    /// for sub-Hz precision is dominated by the FrameSync delivery
    /// jitter, and a single decimal places matches the bottom-bar
    /// convergence formatting style elsewhere in the app.
    static func metricsLabel(for status: ReceiverWatchdog.SideStatus) -> String {
        switch status {
        case .live(let width, let height, let frameRate):
            let fpsPart: String
            if frameRate > 0 {
                fpsPart = " @ \(formatFrameRate(frameRate)) fps"
            } else {
                fpsPart = ""
            }
            return "\(width)×\(height)\(fpsPart)"
        case .reconnecting, .stalled, .connecting, .empty:
            return ""
        }
    }

    /// Single-decimal frame-rate formatting using the `en_US_POSIX`
    /// locale so an operator on a non-period-decimal locale still sees
    /// "59.9" rather than "59,9" (which a downstream tool reading the
    /// debug log would misparse).
    static func formatFrameRate(_ frameRate: Double) -> String {
        let formatter = Self.frameRateFormatter
        return formatter.string(from: NSNumber(value: frameRate))
            ?? String(format: "%.1f", frameRate)
    }

    /// "Live" / "Reconnecting" / "Stalled" / "Connecting" / "No source"
    /// label that sits next to the dot.
    static func stateLabel(for status: ReceiverWatchdog.SideStatus) -> String {
        switch status {
        case .live: return "Live"
        case .reconnecting: return "Reconnecting"
        case .stalled: return "Stalled"
        case .connecting: return "Connecting"
        case .empty: return "No source"
        }
    }

    /// Color for the ● dot. See file header for the mapping rationale.
    static func dotColor(for status: ReceiverWatchdog.SideStatus) -> Color {
        switch status {
        case .live: return .green
        case .connecting, .reconnecting: return .yellow
        case .stalled: return .red
        case .empty: return .gray
        }
    }

    /// Composed VoiceOver label that combines side + source + state +
    /// metrics into a single utterance.
    static func accessibilityLabel(side: SourcePickerSheet.Side,
                                   sourceName: String?,
                                   status: ReceiverWatchdog.SideStatus) -> String {
        let side = side.label
        let source = sourceLabel(name: sourceName)
        let state = stateLabel(for: status)
        let metrics = metricsLabel(for: status)
        if metrics.isEmpty {
            return "\(side): \(source), \(state)"
        }
        return "\(side): \(source), \(metrics), \(state)"
    }

    private static let frameRateFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.usesGroupingSeparator = false
        return f
    }()
}
