//  SourceSelection.swift
//
//  Owns the operator's currently-picked Left and Right NDI sources.
//
//  Slice #11 scope: persistence. The selection now hydrates from a
//  `SessionStore` (last L/R name + URL) at init time and writes
//  through on every change. ContentView's `.task` reads the restored
//  values, constructs `NDISource`s, and assigns them straight into
//  this model — the existing `.onChange(of: selection.leftSource)`
//  handler in ContentView triggers the receiver connect, so silent
//  auto-reconnect "just works" through the same path the picker uses.
//
//  The `_persisting` flag pattern mirrors AlignmentState +
//  OutputStreamConfig: the init's restore assignments don't re-write
//  the values back to UserDefaults; only later mutations do.

import Foundation
import Observation

@MainActor
@Observable
final class SourceSelection {
    var leftSource: NDISource? {
        didSet {
            if persistsToStore {
                store.lastLeftSourceName = leftSource?.name
                store.lastLeftSourceURL = leftSource?.urlAddress
            }
        }
    }

    var rightSource: NDISource? {
        didSet {
            if persistsToStore {
                store.lastRightSourceName = rightSource?.name
                store.lastRightSourceURL = rightSource?.urlAddress
            }
        }
    }

    private let store: SessionStore
    private var persistsToStore: Bool = false

    init(store: SessionStore = .shared) {
        self.store = store
        if let name = store.lastLeftSourceName,
           let url = store.lastLeftSourceURL {
            self.leftSource = NDISource(name: name, urlAddress: url)
        }
        if let name = store.lastRightSourceName,
           let url = store.lastRightSourceURL {
            self.rightSource = NDISource(name: name, urlAddress: url)
        }
        self.persistsToStore = true
    }

    func swap() {
        (leftSource, rightSource) = (rightSource, leftSource)
    }
}
