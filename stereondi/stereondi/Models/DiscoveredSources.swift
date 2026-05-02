//  DiscoveredSources.swift
//
//  Bridges the long-lived ObjC NDIDiscovery singleton to the SwiftUI /
//  Observation world. Owns the start() call and republishes the list
//  on the main actor whenever NDIDiscovery's background find loop
//  reports a change.

import Foundation
import Observation

@MainActor
@Observable
final class DiscoveredSources {
    private(set) var sources: [NDISource] = []

    init() {
        let discovery = NDIDiscovery.shared()
        sources = discovery.currentSources()
        discovery.onSourcesChanged = { [weak self] s in
            Task { @MainActor in
                self?.sources = s
            }
        }
        discovery.start()
    }
}
