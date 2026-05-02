//  stereondiApp.swift

import SwiftUI

@main
struct stereondiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var holdsNDIRefcount = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            switch newPhase {
            case .active:
                if !holdsNDIRefcount {
                    _ = NDIRuntime.start()
                    holdsNDIRefcount = true
                }
            case .background:
                if holdsNDIRefcount {
                    NDIRuntime.stop()
                    holdsNDIRefcount = false
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
