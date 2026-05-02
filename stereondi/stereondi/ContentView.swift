//  ContentView.swift
//
//  Wires the two NDI receivers, the FramePairer, the StereoCompositor,
//  the MetalPreviewView, the SenderPipeline, the AlignmentState, and
//  the OutputStreamConfig together. Each side of `selection` drives
//  its own receiver via .onChange; the pairer pulls both at vsync,
//  the compositor draws their HIT-corrected SbS into the MTKView, and
//  on the same tick the SenderPipeline pushes a 1920×1080 UYVY copy
//  out via NDISender.
//
//  Slice #12 additions:
//   - `NetworkResilience` watches NWPathMonitor; on interface change
//     the `ReceiverWatchdog` calls `kickReconnect` on both receivers.
//   - `ReceiverWatchdog` ticks at 1 Hz, promotes `.live` → `.stalled`
//     at the 2 s mark, kicks reconnects every 2 s on `.stalled` and
//     `.disconnected`, and surfaces a per-side `SideStatus` for the
//     overlays.
//   - `SessionStatus` collects mismatch / interlace / alpha warnings
//     from FramePairer ticks; the WarningBanner overlays them.
//   - The pairer now hands the watchdog's per-side status into each
//     `StereoFramePair`, and freezes the last good frame per side
//     when the live capture goes nil but the receiver has been live
//     within the stall window.
//   - Per-eye `ReceiverStatusOverlay` views sit atop each preview
//     half so the operator sees "Reconnecting…" / "Stalled" /
//     "No source" without the Metal compositor having to draw text.
//
//  Slice #6 added the bottom alignment bar, the on-preview gesture
//  overlay (two-finger pan / pinch / double-tap), and threads a
//  shared AlignmentState through both render paths so HIT changes
//  reflect on the iPad screen and in the NDI output within one frame.
//
//  Slice #10 makes the output stream identity (name + groups) editable
//  from the Settings sheet (gear icon in TopBar). The
//  `OutputStreamConfig` model owns the raw + effective values; this
//  view's `.onChange` handlers feed each effective-value change into
//  `senderPipeline.reconfigure(...)`, which restarts the underlying
//  NDISender in place.
//
//  Slice #11 adds persistence + silent auto-reconnect:
//   - All four state owners (`selection`, `alignment`, `output`,
//     `favorites`) hydrate from `SessionStore.shared` at construction
//     time. Selection's restored value is the operator's last-picked
//     L/R pair from the previous session.
//   - SwiftUI's `.onChange` does NOT fire for the initial value, so
//     the restored selection wouldn't drive the receivers without an
//     explicit `apply(...)` at appear time. The `.task` block does
//     that apply, then waits 5 s and presents the source picker if
//     neither receiver has reached `.live`. (Per issue: "succeeds
//     silently if sources are present, falls back to picker after 5 s
//     timeout".)
//   - The picker presentation state is owned here (rather than inside
//     TopBar) so both the user-driven flow (TopBar source-button
//     taps) and the auto-present-on-reconnect-timeout flow drive the
//     same single sheet — iOS only allows one sheet per ancestor.
//   - Settings sheet now also gets `alignment` and `store` so the
//     "Reset session" action and "Default mode on launch" picker work.

import Metal
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var receiverLeft = NDIReceiver.receiver()
    @State private var receiverRight = NDIReceiver.receiver()
    @State private var selection = SourceSelection()
    @State private var discovered = DiscoveredSources()
    @State private var alignment = AlignmentState()
    @State private var output = OutputStreamConfig()
    @State private var favorites = FavoritesViewModel()
    @State private var status = SessionStatus()
    @State private var network = NetworkResilience()
    @State private var watchdog: ReceiverWatchdog?
    @State private var zoom: CGFloat = 1.0

    @State private var compositor: StereoCompositor?
    @State private var pairer: FramePairer?
    @State private var device: MTLDevice?
    @State private var commandQueue: MTLCommandQueue?
    @State private var senderPipeline: SenderPipeline?
    @State private var initError: String?

    /// Source-picker presentation. Lifted from TopBar so the auto-
    /// reconnect timeout can also present the picker without fighting
    /// TopBar over which sheet is on top.
    @State private var pickerSide: SourcePickerSheet.Side?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let pairer, let compositor, let device {
                MetalPreviewView(pairer: pairer,
                                 compositor: compositor,
                                 device: device,
                                 alignment: alignment,
                                 senderPipeline: senderPipeline)
                    .scaleEffect(zoom)
                    .ignoresSafeArea()
            } else if let initError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(initError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Per-eye status overlays sit between the Metal preview
            // and the gesture overlay so the "Reconnecting…" /
            // "Stalled" / "No source" text is legible without
            // dimming the gesture surface. Hidden when both sides
            // are .live (the EmptyView in ReceiverStatusOverlay).
            if let watchdog {
                HStack(spacing: 0) {
                    ReceiverStatusOverlay(side: .left,
                                          status: watchdog.leftStatus)
                    ReceiverStatusOverlay(side: .right,
                                          status: watchdog.rightStatus)
                }
                .allowsHitTesting(false)
            }

            // Gesture overlay sits between the preview and the
            // chrome bars; two-finger pans and pinches are captured
            // here, single-finger touches fall through to the chrome.
            PreviewGestureOverlay(alignment: alignment, zoom: $zoom)
                .ignoresSafeArea()

            VStack {
                TopBar(selection: selection,
                       alignment: alignment,
                       output: output,
                       discovered: discovered,
                       pickerSide: $pickerSide)
                WarningBanner(status: status)
                Spacer()
                BottomBar(alignment: alignment)
            }

            if selection.leftSource == nil && selection.rightSource == nil {
                searchOverlay
            }
        }
        .sheet(item: $pickerSide) { side in
            SourcePickerSheet(
                side: side,
                selection: selection,
                discovered: discovered,
                favorites: favorites,
                alignment: alignment
            )
        }
        .onAppear {
            initializeRenderer()
        }
        .task {
            await silentAutoReconnect()
        }
        .onDisappear {
            pairer?.stop()
            senderPipeline?.stop()
            watchdog?.stop()
            network.stop()
        }
        .onChange(of: selection.leftSource) { _, newLeft in
            apply(source: newLeft, to: receiverLeft)
        }
        .onChange(of: selection.rightSource) { _, newRight in
            apply(source: newRight, to: receiverRight)
        }
        .onChange(of: output.effectiveStreamName) { _, newName in
            senderPipeline?.reconfigure(streamName: newName,
                                        groups: output.effectiveGroups)
        }
        .onChange(of: output.effectiveGroups) { _, newGroups in
            senderPipeline?.reconfigure(streamName: output.effectiveStreamName,
                                        groups: newGroups)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Re-apply current identity on foreground rather than
                // a bare start() — keeps the rename-mid-session and
                // resume-from-background paths through the single
                // reconfigure(...) entry point.
                senderPipeline?.reconfigure(streamName: output.effectiveStreamName,
                                            groups: output.effectiveGroups)
            case .background:
                senderPipeline?.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private var searchOverlay: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Pick Left and Right sources from the top bar")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func initializeRenderer() {
        guard pairer == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            initError = "Metal is unavailable on this device"
            return
        }
        guard let queue = device.makeCommandQueue() else {
            initError = "Metal command queue creation failed"
            return
        }
        do {
            let compositor = try StereoCompositor(device: device)
            let senderPipeline = try SenderPipeline(device: device,
                                                    commandQueue: queue)
            // First start uses the OutputStreamConfig defaults
            // ("Stereo Preview" / "Public") via the same reconfigure
            // path that the Settings sheet edit and scene-foreground
            // transitions go through — one canonical entry point.
            senderPipeline.reconfigure(streamName: output.effectiveStreamName,
                                       groups: output.effectiveGroups)

            // Slice #12: stand the watchdog up alongside the network
            // monitor. The watchdog ticks at 1 Hz, kicks reconnects on
            // .stalled / .disconnected, and surfaces SideStatus to
            // both the FramePairer (for freeze-frame fallback) and
            // the ReceiverStatusOverlay (for the per-eye text).
            let watchdog = ReceiverWatchdog(left: receiverLeft,
                                            right: receiverRight,
                                            network: network)
            watchdog.start()
            network.start()

            // The MetalPreviewView's Coordinator owns the per-tick
            // onTick closure and chains the SenderPipeline into it,
            // so we don't pre-set onTick here. The pairer's status
            // wiring is set unconditionally because it doesn't
            // depend on the MTKView lifecycle.
            let pairer = FramePairer(
                left: receiverLeft,
                right: receiverRight,
                statusProvider: { [weak watchdog] in
                    guard let watchdog else {
                        return (left: .empty, right: .empty)
                    }
                    return (left: watchdog.leftStatus,
                            right: watchdog.rightStatus)
                },
                statusObserver: { [status] leftSize, rightSize, leftIL, rightIL, leftA, rightA in
                    status.update(leftSize: leftSize,
                                  rightSize: rightSize,
                                  leftInterlaced: leftIL,
                                  rightInterlaced: rightIL,
                                  leftHasAlpha: leftA,
                                  rightHasAlpha: rightA)
                }
            )
            pairer.start()
            self.device = device
            self.commandQueue = queue
            self.compositor = compositor
            self.pairer = pairer
            self.senderPipeline = senderPipeline
            self.watchdog = watchdog
        } catch {
            initError = "Failed to initialize render pipeline: \(error)"
        }
    }

    /// Silent auto-reconnect (slice #11). Apply the persisted L/R
    /// selection to the receivers immediately, then wait 5 s and
    /// present the picker if neither side has reached `.live`. With
    /// no persisted selection (cold first launch) there's nothing to
    /// reconnect to — present the picker immediately rather than
    /// waste 5 s of staring at the search overlay.
    private func silentAutoReconnect() async {
        // SwiftUI .onChange doesn't fire on the initial value, so
        // explicitly drive the receivers from the restored selection.
        // For the cold-launch case both sides are nil; apply(...) is
        // a no-op and the receivers stay idle.
        apply(source: selection.leftSource, to: receiverLeft)
        apply(source: selection.rightSource, to: receiverRight)

        guard selection.leftSource != nil || selection.rightSource != nil else {
            pickerSide = .left
            return
        }

        try? await Task.sleep(for: .seconds(5))

        if receiverLeft.state != .live && receiverRight.state != .live {
            pickerSide = .left
        }
    }

    private func apply(source: NDISource?, to receiver: NDIReceiver) {
        if let source {
            receiver.connect(toSourceName: source.name, urlAddress: source.urlAddress)
        } else {
            receiver.disconnect()
        }
    }
}

#Preview {
    ContentView()
}
