//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Network

/// Observes network reachability via NWPathMonitor. Singleton —
/// a single monitor instance is sufficient for the whole app.
///
/// Usage:
/// ```
/// NetworkReachability.shared.onRestored = { /* retry pending work */ }
/// NetworkReachability.shared.start()
/// ```
///
/// ## Important limitations
///
/// `isReachable` reflects only whether the OS has a routable network
/// interface — **not** whether any specific server is actually
/// reachable. In particular:
///
/// - **VPN**: when a VPN tunnel is up, `NWPathMonitor` reports the path
///   as `.satisfied` regardless of whether the underlying physical
///   network works. A device in Airplane Mode with a stale VPN
///   configuration can still appear "online" here. Do **not** treat
///   `isReachable == true` as a guarantee that outgoing requests
///   will succeed — always combine with a per-request timeout or
///   rely on actual request outcomes.
///
/// - **Captive portals / dead uplinks**: the OS can report satisfied
///   even when the uplink is present but unusable (needs sign-in,
///   packet loss, DNS broken).
///
/// Use this class as a *hint* for scheduling retries and gating
/// background work, not as authoritative connectivity truth.
final class NetworkReachability {

    static let shared = NetworkReachability()

    // MARK: - State

    /// True if a usable network path is currently available.
    /// Reads are thread-safe (protected by the monitor's queue).
    private(set) var isReachable: Bool = true

    // MARK: - Callbacks

    /// Called on a background queue when the network transitions from
    /// unreachable → reachable. Intended for retry-on-reconnect logic.
    var onRestored: (() -> Void)?

    /// Called on a background queue when the network transitions from
    /// reachable → unreachable.
    var onLost: (() -> Void)?

    // MARK: - Private

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.zyna.network.reachability")
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Starts observing network paths. Safe to call multiple times.
    func start() {
        guard !started else { return }
        started = true

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let nowReachable = path.status == .satisfied
            let wasReachable = self.isReachable
            self.isReachable = nowReachable

            if !wasReachable && nowReachable {
                self.onRestored?()
            } else if wasReachable && !nowReachable {
                self.onLost?()
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        monitor.cancel()
        started = false
    }
}
