//  ContentView.swift

import SwiftUI

struct ContentView: View {
    @State private var receiver = NDIReceiver.receiver()
    @State private var browser: NDIDiscoveryFirstSource? = nil
    @State private var connectedSourceName: String? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalPreviewView(receiver: receiver).ignoresSafeArea()
            if connectedSourceName == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Searching for NDI sources…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await locateFirstSource()
        }
    }

    private func locateFirstSource() async {
        let browser = NDIDiscoveryFirstSource.startBrowsing()
        self.browser = browser
        browser.waitForFirstSource(30.0) { name, url in
            guard let name, let url else { return }
            receiver.connect(toSourceName: name, urlAddress: url)
            connectedSourceName = name
        }
    }
}

#Preview {
    ContentView()
}
