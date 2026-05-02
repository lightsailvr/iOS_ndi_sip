//  ContentView.swift
//
//  Wires the two NDI receivers, the FramePairer, the StereoCompositor
//  and the MetalPreviewView together. Each side of `selection` drives
//  its own receiver via .onChange; the pairer pulls both at vsync and
//  the compositor draws their SbS into the MTKView.

import Metal
import SwiftUI

struct ContentView: View {
    @State private var receiverLeft = NDIReceiver.receiver()
    @State private var receiverRight = NDIReceiver.receiver()
    @State private var selection = SourceSelection()
    @State private var discovered = DiscoveredSources()

    @State private var compositor: StereoCompositor?
    @State private var pairer: FramePairer?
    @State private var device: MTLDevice?
    @State private var initError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let pairer, let compositor, let device {
                MetalPreviewView(pairer: pairer, compositor: compositor, device: device)
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
        }
        .onChange(of: selection.leftSource) { _, newLeft in
            apply(source: newLeft, to: receiverLeft)
        }
        .onChange(of: selection.rightSource) { _, newRight in
            apply(source: newRight, to: receiverRight)
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
        do {
            let compositor = try StereoCompositor(device: device)
            let pairer = FramePairer(left: receiverLeft, right: receiverRight)
            pairer.start()
            self.device = device
            self.compositor = compositor
            self.pairer = pairer
        } catch {
            initError = "Failed to initialize compositor: \(error)"
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
