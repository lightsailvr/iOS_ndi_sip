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

    init(pairer: FramePairer,
         compositor: StereoCompositor,
         device: MTLDevice,
         alignment: AlignmentState,
         senderPipeline: SenderPipeline? = nil) {
        self.pairer = pairer
        self.compositor = compositor
        self.device = device
        self.alignment = alignment
        self.senderPipeline = senderPipeline
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

        context.coordinator.attach(to: view, pairer: pairer, senderPipeline: senderPipeline)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.alignment = alignment
        context.coordinator.attach(to: uiView, pairer: pairer, senderPipeline: senderPipeline)
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        var compositor: StereoCompositor
        var alignment: AlignmentState
        private let commandQueue: MTLCommandQueue
        private weak var view: MTKView?
        private var latestPair: StereoFramePair = StereoFramePair(left: nil, right: nil, hostTime: 0)

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
                    senderPipeline: SenderPipeline?) {
            self.view = view
            // Replace the pairer's tick handler with one bound to this
            // Coordinator. The closure (a) caches the latest pair and
            // marks the MTKView as needing display, and (b) — if a
            // sender pipeline is wired up — kicks the UYVY encode +
            // NDI send on a separate command buffer so screen presents
            // and network sends never block each other.
            //
            // updateUIView re-runs this on every SwiftUI update, which
            // is safe: the assignment is just a closure swap.
            pairer.onTick = { [weak self, weak senderPipeline] pair in
                guard let self else { return }
                self.latestPair = pair
                self.view?.setNeedsDisplay()
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

            compositor.render(pair: latestPair,
                              alignment: alignment,
                              into: drawable.texture,
                              commandBuffer: commandBuffer)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
