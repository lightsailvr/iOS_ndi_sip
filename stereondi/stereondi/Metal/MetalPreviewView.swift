//  MetalPreviewView.swift
//
//  SwiftUI wrapper around an MTKView that renders the stereo SbS
//  composite of a FramePairer's latest pair via the StereoCompositor.
//
//  Wire-up: the FramePairer drives a CADisplayLink that ticks on main
//  and (a) caches the latest StereoFramePair on this Coordinator,
//  (b) marks the MTKView as needing display. The MTKView's draw(in:)
//  callback is the only place compositor.render() runs, so the Metal
//  command buffer's submission cadence and the pairer's pull cadence
//  are always in lockstep.
//
//  Slice #6: the AlignmentState is threaded through to both the
//  on-screen draw and the optional SenderPipeline. The Coordinator
//  holds a reference (not a copy) so a slider drag or a two-finger
//  pan reflects in the very next rendered frame.
//
//  Slice #8: the on-screen draw routes through `renderScreen(...)`
//  which honors `alignment.screenMode` (.sbs / .anaglyph /
//  .channelTest); the SenderPipeline keeps calling
//  `renderForSender(...)` which is always SbS, so the iPad operator
//  can flip into anaglyph or channel-test without disturbing the
//  Quest viewer's stream.
//
//  Slice #13: the optional `thermal: ThermalMonitor` lets the on-
//  screen redraw be throttled to 30 Hz under thermal pressure WHILE
//  the SenderPipeline keeps firing every pairer tick. Decoupled this
//  way (rather than dropping `mtkView.preferredFramesPerSecond` to
//  30) so the NDI output rate stays at the display-link's 60 Hz —
//  the PRD's "NDI output rate unaffected by thermal preview drop"
//  contract isn't satisfiable any other way with the current shared-
//  display-link architecture. The pairer's CADisplayLink keeps
//  ticking at the display max; the Coordinator skips
//  `view.setNeedsDisplay()` on alternate ticks when
//  `thermal.previewMode == .reduced`. The pairer's `hostTime` deltas
//  are also fed into `thermal.recordFrameTime(_:)` as the rolling-
//  average secondary signal documented on `ThermalMonitor`.

import Metal
import MetalKit
import QuartzCore
import SwiftUI

struct MetalPreviewView: UIViewRepresentable {
    let pairer: FramePairer
    let compositor: StereoCompositor
    let device: MTLDevice
    let alignment: AlignmentState
    /// Optional NDI sender pipeline; when present, the pairer's tick
    /// triggers a UYVY encode + send in addition to the on-screen
    /// redraw. Slice #5's wiring; nil in test/preview contexts.
    let senderPipeline: SenderPipeline?
    /// Optional thermal monitor (slice #13). When provided, the
    /// Coordinator (a) feeds frame-time deltas into the monitor's
    /// rolling buffer and (b) skips the on-screen `setNeedsDisplay`
    /// on alternate pairer ticks when `previewMode == .reduced`. The
    /// SenderPipeline keeps firing every tick regardless.
    let thermal: ThermalMonitor?

    init(pairer: FramePairer,
         compositor: StereoCompositor,
         device: MTLDevice,
         alignment: AlignmentState,
         senderPipeline: SenderPipeline? = nil,
         thermal: ThermalMonitor? = nil) {
        self.pairer = pairer
        self.compositor = compositor
        self.device = device
        self.alignment = alignment
        self.senderPipeline = senderPipeline
        self.thermal = thermal
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(compositor: compositor, device: device, alignment: alignment)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 0
        // Display-link-driven by the FramePairer's tick rather than the
        // MTKView's own internal display link.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = context.coordinator

        context.coordinator.attach(to: view,
                                   pairer: pairer,
                                   senderPipeline: senderPipeline,
                                   thermal: thermal)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.alignment = alignment
        context.coordinator.attach(to: uiView,
                                   pairer: pairer,
                                   senderPipeline: senderPipeline,
                                   thermal: thermal)
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        var compositor: StereoCompositor
        var alignment: AlignmentState
        private let commandQueue: MTLCommandQueue
        private weak var view: MTKView?
        private var latestPair: StereoFramePair = StereoFramePair(left: nil, right: nil, hostTime: 0)

        /// Wall clock (CFTimeInterval / hostTime from CADisplayLink) of
        /// the previous tick. Used to feed frame-time deltas into the
        /// optional ThermalMonitor's rolling buffer. Reset (0) on
        /// attach so the first tick's delta is dropped (the rolling
        /// mean would otherwise eat a stale gap on first appear).
        private var lastTickHostTime: CFTimeInterval = 0

        /// Slice #13: alternates true / false on each tick when the
        /// thermal monitor is in `.reduced` mode, so the on-screen
        /// `setNeedsDisplay` fires every other tick (≈ 30 Hz on a
        /// 60 Hz display). The sender path is unaffected — it fires
        /// every tick regardless.
        private var redrawGate: Bool = true

        init(compositor: StereoCompositor, device: MTLDevice, alignment: AlignmentState) {
            self.compositor = compositor
            self.device = device
            self.alignment = alignment
            guard let queue = device.makeCommandQueue() else {
                fatalError("Failed to create Metal command queue")
            }
            self.commandQueue = queue
            super.init()
        }

        func attach(to view: MTKView,
                    pairer: FramePairer,
                    senderPipeline: SenderPipeline?,
                    thermal: ThermalMonitor?) {
            self.view = view
            // Reset the per-tick bookkeeping on every attach so a
            // SwiftUI updateUIView triggered re-attach doesn't carry a
            // stale lastTickHostTime / redrawGate across the swap.
            self.lastTickHostTime = 0
            self.redrawGate = true
            // Replace the pairer's tick handler with one bound to this
            // Coordinator. The closure (a) caches the latest pair and
            // marks the MTKView as needing display, (b) — if a sender
            // pipeline is wired up — kicks the UYVY encode + NDI send
            // on a separate command buffer so screen presents and
            // network sends never block each other, and (c) — if a
            // thermal monitor is wired up — feeds the per-tick
            // wall-clock delta into the rolling buffer and consults
            // `previewMode` to decide whether to redraw the MTKView
            // this tick.
            //
            // updateUIView re-runs this on every SwiftUI update, which
            // is safe: the assignment is just a closure swap.
            pairer.onTick = { [weak self, weak senderPipeline, weak thermal] pair in
                guard let self else { return }
                self.latestPair = pair

                if let thermal {
                    if self.lastTickHostTime > 0 {
                        let dt = pair.hostTime - self.lastTickHostTime
                        if dt > 0 {
                            thermal.recordFrameTime(dt)
                        }
                    }
                    self.lastTickHostTime = pair.hostTime
                }

                let shouldRedraw: Bool
                if thermal?.previewMode == .reduced {
                    self.redrawGate.toggle()
                    shouldRedraw = self.redrawGate
                } else {
                    shouldRedraw = true
                }
                if shouldRedraw {
                    self.view?.setNeedsDisplay()
                }

                if let senderPipeline {
                    senderPipeline.send(pair: pair,
                                        alignment: self.alignment,
                                        compositor: self.compositor)
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            compositor.renderScreen(pair: latestPair,
                                    alignment: alignment,
                                    into: drawable.texture,
                                    commandBuffer: commandBuffer)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
