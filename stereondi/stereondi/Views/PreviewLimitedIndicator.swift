//  PreviewLimitedIndicator.swift
//
//  Slice #13. Small chrome badge that surfaces "the iPad screen
//  preview is throttled to 30 fps" without disturbing the operator's
//  alignment workflow. Visibility is bound to the
//  `ThermalMonitor.previewMode == .reduced` state; absent (returns
//  `EmptyView`) when the preview is running at full rate.
//
//  Visual: a single SF Symbol + short label inside an ultraThin
//  material capsule. Sits next to the gear in the TopBar (or wherever
//  ContentView mounts it).
//
//  Accessibility: VoiceOver reads
//  "Preview limited to 30 fps. NDI output unaffected." per the
//  issue's tooltip text.

import SwiftUI

struct PreviewLimitedIndicator: View {
    var thermal: ThermalMonitor

    var body: some View {
        if thermal.previewMode == .reduced {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                Text("Preview limited")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial,
                        in: Capsule(style: .continuous))
            .foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preview limited to 30 fps to manage device temperature. NDI output unaffected.")
        }
    }
}
