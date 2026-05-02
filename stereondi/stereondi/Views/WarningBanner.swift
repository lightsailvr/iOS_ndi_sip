//  WarningBanner.swift
//
//  Top-of-preview banner stack that surfaces SessionStatus warnings.
//  Auto-shows when any of (resolution mismatch, interlaced, alpha)
//  fires; auto-hides when all clear. Each warning is its own row so a
//  multi-source-mismatch session can show all three at once without
//  collapsing them into a single ambiguous message.
//
//  Layout: stacked at the top of the preview ZStack, BELOW the TopBar
//  so the operator's source pickers stay reachable. Uses
//  `.ultraThinMaterial` for subtle in-context contrast — these aren't
//  alerts, they're status indicators that the operator should notice
//  without being interrupted by them.
//
//  Slice #12 scope: render the three warning rows (resolution,
//  interlaced, alpha) plus per-eye reconnecting/stalled indicators
//  via the `ReceiverStatusOverlay` neighbor view. Polish (animations,
//  accessibility customization) lives in the ContentView mounting
//  rather than here.

import SwiftUI

struct WarningBanner: View {
    @Bindable var status: SessionStatus

    var body: some View {
        VStack(spacing: 6) {
            if let mismatch = status.resolutionMismatch {
                row(systemImage: "rectangle.compress.vertical",
                    text: resolutionText(mismatch),
                    tint: .orange)
            }
            if status.interlacedWarning {
                row(systemImage: "rectangle.3.group",
                    text: "Interlaced source — deinterlaced upstream",
                    tint: .orange)
            }
            if status.hasAlphaWarning {
                row(systemImage: "square.on.square",
                    text: "Alpha source — premultiplied against black",
                    tint: .blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    private func resolutionText(_ mismatch: SessionStatus.ResolutionMismatch) -> String {
        let l = mismatch.leftSize
        let r = mismatch.rightSize
        return "Mismatch: \(Int(l.width))×\(Int(l.height))  /  \(Int(r.width))×\(Int(r.height))"
    }

    private func row(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
