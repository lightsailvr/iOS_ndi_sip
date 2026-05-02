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
//
//  Slice #13 additions:
//   - `EmptyState` replaces the old "Pick from the top bar" overlay
//     when both sides are nil. Gated on `emptyStateEligible` so a
//     persisted-pair launch doesn't flash the empty surface during
//     the silent-auto-reconnect grace window.
//   - `StatusRow` sits below the TopBar showing per-eye name +
//     resolution + framerate + state-dot.
//   - Top-edge chrome (TopBar + StatusRow + WarningBanner) auto-hides
//     after 3 s of no operator interaction. The visibility timer is
//     poked by single-tap on the preview gesture overlay (two-finger
//     pan does NOT bump it — alignment sessions want hidden chrome
//     per the issue's sanity-check section). The bottom bar is
//     intentionally NOT bound to chromeVisible (PRD user story 24:
//     convergence slider always visible).
//   - `ThermalMonitor` drives a `PreviewLimitedIndicator` next to the
//     TopBar's gear and is threaded into `MetalPreviewView` so the
//     on-screen redraw alternates ticks while the NDI sender keeps
//     firing every tick.
//   - The per-eye `ReceiverStatusOverlay` for an `.empty` side is now
//     a tap target that presents the SourcePickerSheet for that side
//     (single-source partial preview case).

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
    @State private var thermal = ThermalMonitor()
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

    // MARK: - Slice #13 chrome auto-hide + empty-state gate

    /// Visibility of the top-edge chrome stack (TopBar + StatusRow +
    /// WarningBanner). Bumped on any single-tap on the preview
    /// gesture overlay; reset to false after a 3 s idle window per
    /// PRD user story 23. The bottom bar is intentionally NOT bound
    /// to this state — convergence is always reachable.
    @State private var chromeVisible: Bool = true

    /// Long-lived MainActor task that flips `chromeVisible` to false
    /// after the auto-hide delay. Replaced (cancelled + recreated) on
    /// every visibility bump so a fresh tap restarts the countdown.
    @State private var chromeHideTask: Task<Void, Never>?

    /// True once enough time has passed since launch (or since both
    /// sides were last cleared) to safely show the EmptyState. Without
    /// this gate, a persisted-pair launch would flash the empty
    /// surface during the silent-auto-reconnect grace window — the
    /// operator should see the "Pick…" prompt only when the app has
    /// genuinely settled into "no sources connectable".
    @State private var emptyStateEligible: Bool = false

    /// Auto-hide delay per PRD user story 23. 3 seconds.
    private static let chromeAutoHideSeconds: Double = 3.0

    /// Match the silent-auto-reconnect window (slice #11) so the
    /// EmptyState surface only appears after the receiver-warm-up
    /// grace period the rest of the app already commits to.
    private static let emptyStateGraceSeconds: Double = 5.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let pairer, let compositor, let device {
                MetalPreviewView(pairer: pairer,
                                 compositor: compositor,
                                 device: device,
                                 alignment: alignment,
                                 senderPipeline: senderPipeline,
                                 thermal: thermal)
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

            // Gesture overlay sits between the Metal preview and
            // everything tappable above it. Two-finger pans and
            // pinches are captured here. A single-tap callback
            // bumps the chrome visibility timer per PRD user story
            // 23 (auto-hide after 3 s); two-finger drags do NOT bump
            // visibility (the operator wants the bars hidden while
            // alignment is happening — issue sanity-check section).
            PreviewGestureOverlay(alignment: alignment,
                                  zoom: $zoom,
                                  onSingleTap: { bumpChromeVisibility() })
                .ignoresSafeArea()

            // Per-eye status overlays sit ABOVE the gesture overlay
            // so the `.empty`-side tap-to-pick button (slice #13)
            // can receive single-finger taps before the gesture
            // overlay's tap-bumps-chrome handler. The non-tappable
            // overlay states (.live / .connecting / .reconnecting /
            // .stalled) render small material badges that don't
            // intercept taps outside their content shape — taps in
            // those regions still fall through to the gesture
            // overlay (and bump the chrome timer).
            if let watchdog {
                HStack(spacing: 0) {
                    ReceiverStatusOverlay(
                        side: .left,
                        status: watchdog.leftStatus,
                        onTapEmpty: { pickerSide = .left }
                    )
                    ReceiverStatusOverlay(
                        side: .right,
                        status: watchdog.rightStatus,
                        onTapEmpty: { pickerSide = .right }
                    )
                }
            }

            VStack(spacing: 4) {
                topChrome
                Spacer()
                BottomBar(alignment: alignment)
            }

            if showEmptyState {
                EmptyState(pickerSide: $pickerSide)
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
            // Ensure the chrome is visible on first appear and start
            // the auto-hide countdown.
            bumpChromeVisibility()
        }
        .task {
            await silentAutoReconnect()
        }
        .task {
            await openEmptyStateGate()
        }
        .onDisappear {
            pairer?.stop()
            senderPipeline?.stop()
            watchdog?.stop()
            network.stop()
            chromeHideTask?.cancel()
            chromeHideTask = nil
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
        .onChange(of: pickerSide) { _, newSide in
            // Sheets keep the chrome visible — the operator just
            // dismissed the picker, they need to see the bars to take
            // their next action. Cancel the hide timer while a sheet
            // is up; restart on dismissal.
            if newSide != nil {
                chromeHideTask?.cancel()
                chromeHideTask = nil
                chromeVisible = true
            } else {
                bumpChromeVisibility()
            }
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

    // MARK: - Top chrome (auto-hides per PRD user story 23)

    private var topChrome: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TopBar(selection: selection,
                       alignment: alignment,
                       output: output,
                       discovered: discovered,
                       pickerSide: $pickerSide)
                PreviewLimitedIndicator(thermal: thermal)
                    .padding(.trailing, 8)
            }
            StatusRow(selection: selection, watchdog: watchdog)
            WarningBanner(status: status)
        }
        .opacity(chromeVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        // When hidden, the chrome must not eat taps — let them fall
        // through to the gesture overlay (which bumps visibility on
        // single-tap, surfacing the chrome again).
        .allowsHitTesting(chromeVisible)
    }

    /// Whether the EmptyState surface should be mounted right now.
    /// True iff:
    ///   - both sides are nil (operator has no sources picked), AND
    ///   - the empty-state grace window has elapsed.
    /// Without the second clause, a persisted-pair launch would flash
    /// the EmptyState briefly while the receivers warm up.
    private var showEmptyState: Bool {
        return emptyStateEligible
            && selection.leftSource == nil
            && selection.rightSource == nil
    }

    // MARK: - Chrome auto-hide

    /// Mark the chrome visible and (re-)start the 3 s hide countdown.
    /// Called on appear, on any single-tap on the gesture overlay,
    /// and after the source-picker sheet is dismissed.
    private func bumpChromeVisibility() {
        chromeVisible = true
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(Self.chromeAutoHideSeconds))
            } catch {
                return
            }
            if Task.isCancelled { return }
            // Don't auto-hide while a sheet is up — the operator
            // dismissing the sheet will re-arm the timer.
            guard pickerSide == nil else { return }
            // Don't auto-hide while the operator has no sources
            // picked — the chrome (and the EmptyState surface, once
            // its grace window opens) IS the UI in that state. We
            // also keep the chrome visible during the empty-state
            // grace window so cold launch doesn't briefly show a
            // black screen with no surfaces.
            guard selection.leftSource != nil || selection.rightSource != nil else { return }
            chromeVisible = false
        }
    }

    // MARK: - Empty state grace window

    /// Wait `emptyStateGraceSeconds` after launch before letting the
    /// EmptyState surface appear. This matches the silent-auto-
    /// reconnect window (slice #11) so a persisted-pair launch
    /// doesn't flash the empty surface during the warm-up window.
    private func openEmptyStateGate() async {
        try? await Task.sleep(for: .seconds(Self.emptyStateGraceSeconds))
        emptyStateEligible = true
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
    ///
    /// Slice #13: cold-launch path no longer auto-presents the
    /// picker. The EmptyState surface (mounted after the empty-
    /// state grace window elapses) carries the prompt. Operators
    /// can tap one of the EmptyState pick buttons to open the picker
    /// when they're ready.
    private func silentAutoReconnect() async {
        // SwiftUI .onChange doesn't fire on the initial value, so
        // explicitly drive the receivers from the restored selection.
        // For the cold-launch case both sides are nil; apply(...) is
        // a no-op and the receivers stay idle.
        apply(source: selection.leftSource, to: receiverLeft)
        apply(source: selection.rightSource, to: receiverRight)

        guard selection.leftSource != nil || selection.rightSource != nil else {
            // Cold launch: don't auto-present the picker; the
            // EmptyState surface (via openEmptyStateGate) will
            // surface the pick buttons.
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
