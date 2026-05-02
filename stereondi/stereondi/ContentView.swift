//  ContentView.swift

import SwiftUI

struct ContentView: View {
    @State private var receiver = NDIReceiver.receiver()
    @State private var selection = SourceSelection()
    @State private var discovered = DiscoveredSources()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalPreviewView(receiver: receiver).ignoresSafeArea()

            VStack {
                TopBar(selection: selection, discovered: discovered)
                Spacer()
            }

            if selection.leftSource == nil {
                searchOverlay
            }
        }
        .onChange(of: selection.leftSource) { _, newLeft in
            if let left = newLeft {
                receiver.connect(toSourceName: left.name, urlAddress: left.urlAddress)
            } else {
                receiver.disconnect()
            }
        }
    }

    private var searchOverlay: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Pick a source from the top bar")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
