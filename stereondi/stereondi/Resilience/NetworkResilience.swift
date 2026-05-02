//  NetworkResilience.swift
//
//  Watches the device's network path via `NWPathMonitor` and surfaces
//  two pieces of information to the rest of the app:
//
//    - `isReachable`: a coarse "do we have any usable interface right
//      now" flag (mirrors `path.status == .satisfied`). Drives the
//      "no network" empty state in a future polish slice; today it's
//      mostly informational.
//    - `onInterfaceChange`: invoked on the main actor whenever the
//      *active* set of interfaces changes (WiFi handoff between APs,
//      WiFi → ethernet, gain/lose any interface). The
//      `ReceiverWatchdog` hooks this to call `kickReconnect` on both
//      receivers — production set crews move carts between APs all
//      day, and the FrameSync state inside an `NDIlib_recv_*` does
//      NOT survive an interface change cleanly without a recreate.
//
//  Why we compare interface signatures rather than firing on every
//  `pathUpdateHandler` callback: NWPathMonitor delivers spurious
//  updates (NIC state polls, service discovery flickers) several times
//  per second on iPad even on a stable WiFi network. Diff'ing the
//  *names* of `path.availableInterfaces` filters those out — a real
//  handoff changes the interface set, a spurious update doesn't.
//
//  Threading:
//   - `NWPathMonitor` requires a serial dispatch queue for its
//     callback. We give it a private one (`com.lsvr.stereondi.netmon`)
//     and hop to MainActor before publishing changes. The hop happens
//     once per *real* change, not once per spurious update, because
//     the diff happens on the netmon queue.
//
//  Lifecycle:
//   - `start()` is idempotent (multiple calls are no-ops). `stop()`
//     cancels the underlying monitor; a subsequent `start()` allocates
//     a fresh one. The model lives across scene-phase transitions in
//     `ContentView`, so wire `start()` once at appear and forget about
//     it; `stop()` exists for future scene-background work that wants
//     to silence the monitor while the app is backgrounded.

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkResilience {

    /// Most recent `NWPath` snapshot (delivered via the diff'ed
    /// pathUpdateHandler). Useful for surfacing "WiFi" vs "Ethernet"
    /// vs "no network" in a future status row.
    var currentPath: NWPath?

    /// True when at least one interface is satisfied. Mirrors
    /// `path.status == .satisfied`. Initialized false so a code path
    /// that observes this before the first NWPathMonitor callback
    /// reads a sane value.
    var isReachable: Bool = false

    /// Fired on the main actor whenever the set of *active* interfaces
    /// changes (handoff, gain, loss). The `ReceiverWatchdog` sets this
    /// to its own handler at construction time; ContentView never has
    /// to touch it directly.
    var onInterfaceChange: (@MainActor () -> Void)?

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.lsvr.stereondi.netmon")

    /// Last-observed interface signature (sorted names). Kept on the
    /// netmon queue so the diff happens on the same thread that
    /// receives the path update — no lock needed.
    private nonisolated(unsafe) var lastInterfaceSignature: [String]?

    init() {}

    deinit {
        monitor?.cancel()
    }

    /// Wire up the underlying NWPathMonitor and start receiving path
    /// updates. Idempotent: the second and later calls are no-ops.
    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { [weak self] path in
            // Runs on `queue` (the serial monitor queue). Diff here
            // before hopping to main so the MainActor isn't woken up
            // for every spurious NIC poll.
            self?.handlePathUpdateOnMonitorQueue(path)
        }
        m.start(queue: queue)
    }

    /// Cancel the monitor. A subsequent `start()` allocates a fresh
    /// one; the underlying NWPathMonitor is not designed for
    /// stop/restart, so we replace it.
    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    // MARK: - Path diffing

    /// Runs on the netmon serial queue. Compares interface names
    /// against the last-seen set; on change, hops to MainActor to
    /// publish the new path and fire `onInterfaceChange`.
    nonisolated private func handlePathUpdateOnMonitorQueue(_ path: NWPath) {
        let signature = path.availableInterfaces
            .map { $0.name }
            .sorted()
        let interfaceChanged: Bool
        if let lastInterfaceSignature {
            interfaceChanged = (lastInterfaceSignature != signature)
        } else {
            interfaceChanged = true
        }
        lastInterfaceSignature = signature

        let reachable = (path.status == .satisfied)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentPath = path
            self.isReachable = reachable
            if interfaceChanged {
                self.onInterfaceChange?()
            }
        }
    }
}
