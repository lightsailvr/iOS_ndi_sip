//  MetalPreviewView.swift
//
//  SwiftUI wrapper around an MTKView that pulls frames from an NDIReceiver
//  at the iPad's vsync cadence and renders them via Core Image. Slice #2
//  intentionally uses Core Image — slice #4 replaces this stage with a
//  hand-rolled Metal compositor that samples UYVY directly. Until then
//  Core Image gives us aspect-fit, color-space-correct UYVY/BGRA output
//  for free.
//
//  MTKView dispatches its delegate callbacks on the main thread by
//  default. NDIReceiver.latestFrame is documented thread-safe so the
//  cross-thread guarantees this would need anyway are already in place.

import CoreImage
import Metal
import MetalKit
import SwiftUI

struct MetalPreviewView: UIViewRepresentable {
    let receiver: NDIReceiver

    func makeCoordinator() -> Coordinator {
        Coordinator(receiver: receiver)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.metalDevice
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 0
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.receiver = receiver
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let metalDevice: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let ciContext: CIContext
        var receiver: NDIReceiver

        init(receiver: NDIReceiver) {
            self.receiver = receiver
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue() else {
                fatalError("Metal is unavailable on this device")
            }
            self.metalDevice = device
            self.commandQueue = queue
            self.ciContext = CIContext(
                mtlCommandQueue: queue,
                options: [
                    .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                    .cacheIntermediates: false,
                ]
            )
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            let drawableSize = view.drawableSize
            let texture = drawable.texture

            if let renderPass = view.currentRenderPassDescriptor {
                renderPass.colorAttachments[0].loadAction = .clear
                renderPass.colorAttachments[0].clearColor = view.clearColor
                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
                    encoder.endEncoding()
                }
            }

            if let frame = receiver.latestFrame() {
                let pixelBuffer = frame.pixelBuffer
                let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
                let fitted = aspectFit(sourceImage,
                                       sourceSize: CGSize(width: frame.width, height: frame.height),
                                       into: drawableSize)
                let destination = CIRenderDestination(
                    width: Int(drawableSize.width),
                    height: Int(drawableSize.height),
                    pixelFormat: view.colorPixelFormat,
                    commandBuffer: commandBuffer,
                    mtlTextureProvider: { texture }
                )
                destination.isFlipped = false
                _ = try? ciContext.startTask(toRender: fitted, to: destination)
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func aspectFit(_ image: CIImage,
                               sourceSize: CGSize,
                               into target: CGSize) -> CIImage {
            guard sourceSize.width > 0,
                  sourceSize.height > 0,
                  target.width > 0,
                  target.height > 0 else {
                return image
            }
            let scale = min(target.width / sourceSize.width,
                            target.height / sourceSize.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let scaledExtent = scaled.extent
            let dx = (target.width - scaledExtent.width) / 2.0 - scaledExtent.origin.x
            let dy = (target.height - scaledExtent.height) / 2.0 - scaledExtent.origin.y
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }
    }
}
