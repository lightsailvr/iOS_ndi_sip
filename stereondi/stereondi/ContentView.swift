//  ContentView.swift
//
//  Wires the two NDI receivers, the FramePairer, the StereoCompositor,
//  the MetalPreviewView, and the SenderPipeline together. Each side of
//  `selection` drives its own receiver via .onChange; the pairer pulls
//  both at vsync, the compositor draws their SbS into the MTKView, and
//  on the same tick the SenderPipeline pushes a 1920×1080 UYVY copy
//  out via NDISender.
//
//  Slice #5 hardcodes the output stream name ("Stereo Preview") and
//  groups ("Public"); slice #10 makes both editable from Settings.

import Metal
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var receiverLeft = NDIReceiver.receiver()
    @State private var receiverRight = NDIReceiver.receiver()
    @State private var selection = SourceSelection()
    @State private var discovered = DiscoveredSources()

    @State private var compositor: StereoCompositor?
    @State private var pairer: FramePairer?
    @State private var device: MTLDevice?
    @State private var commandQueue: MTLCommandQueue?
    @State private var senderPipeline: SenderPipeline?
    @State private var initError: String?

    private static let defaultStreamName = "Stereo Preview"
    private static let defaultGroups = "Public"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let pairer, let compositor, let device {
                MetalPreviewView(pairer: pairer,
                                 compositor: compositor,
                                 device: device,
                                 senderPipeline: senderPipeline)
                    .ignoresSafeArea()
            } else if let initError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(initError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack {
                TopBar(selection: selection, discovered: discovered)
                Spacer()
            }

            if selection.leftSource == nil && selection.rightSource == nil {
                searchOverlay
            }
        }
        .onAppear {
            initializeRenderer()
        }
        .onDisappear {
            pairer?.stop()
            senderPipeline?.stop()
        }
        .onChange(of: selection.leftSource) { _, newLeft in
            apply(source: newLeft, to: receiverLeft)
        }
        .onChange(of: selection.rightSource) { _, newRight in
            apply(source: newRight, to: receiverRight)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                senderPipeline?.start()
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
                                                    commandQueue: queue,
                                                    streamName: Self.defaultStreamName,
                                                    groups: Self.defaultGroups)
            // The MetalPreviewView's Coordinator owns the per-tick
            // onTick closure and chains the SenderPipeline into it,
            // so we don't pre-set onTick here.
            let pairer = FramePairer(left: receiverLeft, right: receiverRight)
            pairer.start()
            self.device = device
            self.commandQueue = queue
            self.compositor = compositor
            self.pairer = pairer
            self.senderPipeline = senderPipeline
        } catch {
            initError = "Failed to initialize render pipeline: \(error)"
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
