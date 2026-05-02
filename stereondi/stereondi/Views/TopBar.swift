//  TopBar.swift
//
//  Top horizontal bar over the live preview. Shows the two source-picker
//  dropdowns (Left, Right), a Swap button between them, the iPad
//  screen-mode segmented control (SbS / Anaglyph / Channel Test), an
//  overflow menu that surfaces the swap-eyes toggle when in anaglyph
//  mode, and a Settings gear that presents the SettingsSheet.
//
//  Slice #3 wired the source pickers and the Swap button.
//  Slice #6 added the bottom-bar HIT controls (no TopBar change).
//  Slice #8 added the screen-mode + swap-eyes state to AlignmentState
//  and put a temporary debug menu in the BottomBar; slice #9 supersedes
//  that with the proper segmented control here. The NDI-output pipeline
//  is unaffected by screen-mode changes — `StereoCompositor`
//  `renderForSender(...)` is hard-wired to SbS regardless.
//
//  Slice #10 enables the gear: it now presents the SettingsSheet over
//  the bound `OutputStreamConfig`. ContentView's onChange handlers on
//  the config's effective values feed the SenderPipeline so a rename
//  hits the wire within one pairer tick.
//
//  The overflow menu is only mounted when `screenMode == .anaglyph` so
//  the swap-eyes toggle is hidden in modes where it has no effect (this
//  matches the AlignmentState contract: swapEyes is a no-op outside
//  anaglyph). When not in anaglyph, the bar collapses cleanly: the
//  segmented control sits between the source pickers (with a flexible
//  spacer on each side) and the gear.
//
//  Auto-hide-after-3s behavior is intentionally deferred to slice #13;
//  this bar is always visible.

import SwiftUI

struct TopBar: View {
    @Bindable var selection: SourceSelection
    @Bindable var alignment: AlignmentState
    @Bindable var output: OutputStreamConfig
    var discovered: DiscoveredSources

    @State private var presentingPickerForSide: SourcePickerSheet.Side?
    @State private var settingsPresented: Bool = false

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

            screenModePicker
                .frame(maxWidth: 320)

            if alignment.screenMode == .anaglyph {
                overflowMenu
            }

            Spacer(minLength: 8)

            Button {
                settingsPresented = true
            } label: {
                Image(systemName: "gear")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
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
        .sheet(isPresented: $settingsPresented) {
            SettingsSheet(output: output)
        }
    }

    // MARK: - Screen-mode segmented control

    private var screenModePicker: some View {
        Picker("Screen mode", selection: $alignment.screenMode) {
            Text("SbS").tag(ScreenMode.sbs)
            Text("Anaglyph").tag(ScreenMode.anaglyph)
            Text("Channel Test").tag(ScreenMode.channelTest)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("iPad screen mode")
        .accessibilityValue(screenModeAccessibilityValue)
    }

    private var screenModeAccessibilityValue: String {
        switch alignment.screenMode {
        case .sbs: return "Side by side"
        case .anaglyph: return "Anaglyph"
        case .channelTest: return "Channel test"
        }
    }

    // MARK: - Anaglyph overflow menu (swap-eyes lives here)

    private var overflowMenu: some View {
        Menu {
            Toggle("Swap eyes", isOn: $alignment.swapEyes)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Anaglyph options")
    }

    // MARK: - Source pickers

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
