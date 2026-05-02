//  OutputStreamConfig.swift
//
//  Holds the operator's configuration for the NDI *output* stream that
//  the iPad advertises on the LAN: the human-readable stream name (the
//  suffix that follows `<machine-name>` in NDI receivers) and the
//  comma-separated NDI groups list (studios commonly segment their NDI
//  traffic across groups like `Public, StudioA, OnAir`).
//
//  Sanitization lives on this type so the SwiftUI `TextField` can bind
//  directly to the raw `streamName` / `groups` strings — letting the
//  operator type freely without losing the cursor — while the sender
//  consumes only the trimmed `effectiveStreamName` / `effectiveGroups`
//  values. An empty / whitespace-only stream name silently falls back
//  to "Stereo Preview" rather than asking the SDK to advertise an
//  empty name (which would likely fail or produce a cryptic name).
//
//  Persistence (round-trip across launches via `UserDefaults`) is
//  intentionally NOT in this slice — slice #11 (`SessionStore`) handles
//  it. Renaming the stream and relaunching the app loses the
//  customization until then.
//
//  Slice #10 scope: the two output-stream-related fields. The full
//  Settings sheet polish — NDI® attribution, version info, etc. — is
//  the larger Settings slice (#14).

import Foundation
import Observation

@MainActor
@Observable
final class OutputStreamConfig {
    static let defaultStreamName = "Stereo Preview"
    static let defaultGroups = "Public"

    /// Raw, user-editable stream-name string. Bound directly to the
    /// Settings sheet's `TextField` so the cursor / keyboard behavior
    /// is unsurprising; the sender consumes `effectiveStreamName`.
    var streamName: String = OutputStreamConfig.defaultStreamName

    /// Raw, user-editable comma-separated groups string. NDI accepts
    /// the comma-separated form natively (`NDIlib_send_create`'s
    /// `p_groups` is "comma-separated list of groups"), so we don't
    /// need to parse it into an array — only sanitize.
    var groups: String = OutputStreamConfig.defaultGroups

    /// Trimmed stream name, falling back to the default when the
    /// operator clears the field entirely. The sender is never asked
    /// to advertise an empty name.
    var effectiveStreamName: String {
        let trimmed = streamName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultStreamName : trimmed
    }

    /// Trimmed groups string, or nil if the operator cleared the field
    /// — `nil` lets the NDI SDK fall back to its built-in default
    /// (`Public`). No further parsing: the SDK takes the raw
    /// comma-separated string.
    var effectiveGroups: String? {
        let trimmed = groups.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
