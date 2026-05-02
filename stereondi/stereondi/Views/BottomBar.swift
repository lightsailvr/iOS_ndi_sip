//  BottomBar.swift
//
//  Always-visible bottom bar carrying the convergence slider (the hero
//  control of the app — PRD user story 24), ± nudge buttons (1 px and
//  0.1 px), Reset, a numeric readout, and a disclosure that reveals
//  the per-eye fine HIT sliders (PRD user story 7).
//
//  Slider granularity: SwiftUI sliders are continuous floats, which is
//  exactly what we want — the underlying convergence value retains
//  full sub-pixel precision so the shader bilinear filter delivers
//  PRD-spec'd 0.1 px sub-pixel resolution. The numeric readout is
//  rounded to integer px (per AC: "numeric readout (integer px)") on
//  the main row; the disclosure's per-eye readouts also display at
//  integer precision for symmetry.

import SwiftUI

struct BottomBar: View {
    @Bindable var alignment: AlignmentState

    @State private var disclosureOpen: Bool = false

    private static let nudgeFineStep: Double = 0.1
    private static let nudgeCoarseStep: Double = 1.0

    var body: some View {
        VStack(spacing: 8) {
            if disclosureOpen {
                disclosureContent
            }
            mainRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Main row

    private var mainRow: some View {
        HStack(spacing: 10) {
            Button {
                alignment.resetAll()
            } label: {
                Text("Reset")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Reset alignment")

            nudgeButton(label: "−1 px", delta: -Self.nudgeCoarseStep)
            nudgeButton(label: "−0.1 px", delta: -Self.nudgeFineStep)

            Slider(value: $alignment.convergence,
                   in: -AlignmentState.hitMaxAbsPixels...AlignmentState.hitMaxAbsPixels)
                .accessibilityLabel("Convergence")
                .accessibilityValue("\(Int(alignment.convergence.rounded())) pixels")

            Text(convergenceReadout)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 110, alignment: .trailing)
                .accessibilityHidden(true)

            nudgeButton(label: "+0.1 px", delta: +Self.nudgeFineStep)
            nudgeButton(label: "+1 px", delta: +Self.nudgeCoarseStep)

            Button {
                disclosureOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: disclosureOpen ? "chevron.down" : "chevron.up")
                    Text("Per-eye fine")
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Per-eye fine HIT")
        }
    }

    private var convergenceReadout: String {
        let rounded = Int(alignment.convergence.rounded())
        return "Convergence: \(rounded) px"
    }

    private func nudgeButton(label: String, delta: Double) -> some View {
        Button {
            alignment.nudgeConvergence(by: delta)
        } label: {
            Text(label)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 56)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Convergence \(label)")
    }

    // MARK: - Disclosure (per-eye fine sliders)

    private var disclosureContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 24) {
                perEyeSlider(label: "Left fine",
                             value: $alignment.leftFineHIT)
                perEyeSlider(label: "Right fine",
                             value: $alignment.rightFineHIT)
            }

            HStack {
                Text("Crop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Crop mode", selection: $alignment.cropMode) {
                    Text("Auto").tag(CropMode.auto)
                    Text("Off").tag(CropMode.off)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityLabel("Crop mode")
                .accessibilityValue(alignment.cropMode == .auto
                                    ? "Auto-crop common region"
                                    : "Full frame with black bars")
                Spacer()
            }
        }
        .padding(.bottom, 4)
    }

    private func perEyeSlider(label: String,
                              value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value,
                   in: -AlignmentState.hitMaxAbsPixels...AlignmentState.hitMaxAbsPixels)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) pixels")
        }
    }
}
