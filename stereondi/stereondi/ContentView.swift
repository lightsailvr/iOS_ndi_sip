//  ContentView.swift

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "camera.metering.matrix")
                    .imageScale(.large)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                Text("Stereo NDI Preview")
                    .font(.title2.weight(.semibold))
                Text("NDI runtime: \(NDIRuntime.version())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("CPU supported: \(NDIRuntime.isSupportedCPU() ? "yes" : "no")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
