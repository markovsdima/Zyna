//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Producer-level counters for SDK media calls made through the attachments
/// pipeline. Incremented right before `client.getMedia…`, so they do not
/// depend on which UI consumer survives to report a result. Whether a call
/// was served from the SDK's SQLite cache or the network is still unknown
/// here; the SDK's HTTP tracing is the source of truth for that.
final class AttachmentFetchMeter: @unchecked Sendable {

    struct Snapshot: Equatable {
        struct Entry: Equatable {
            /// Started.
            var calls = 0
            /// Finished (success or failure); `totalMs` is over these only.
            var completed = 0
            var failures = 0
            var bytes = 0
            var totalMs: Double = 0

            var averageMs: Double {
                completed > 0 ? totalMs / Double(completed) : 0
            }
        }

        var byRequest: [String: Entry] = [:]
        var inFlight = 0
        /// Producers that reached the gate after every consumer had left.
        var skippedNoDemand = 0

        var totalCalls: Int {
            byRequest.values.reduce(0) { $0 + $1.calls }
        }
    }

    static let shared = AttachmentFetchMeter()

    private let lock = NSLock()
    private var snapshot = Snapshot()
    /// Bumped by `reset()`; a call that began in an earlier epoch must not
    /// touch the counters of the current one.
    private var epoch = 0

    /// Returns the epoch the call belongs to; pass it back to `end`.
    func begin(_ label: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        snapshot.inFlight += 1
        snapshot.byRequest[label, default: Snapshot.Entry()].calls += 1
        return epoch
    }

    /// `bytes` nil marks a failed call.
    func end(_ label: String, epoch callEpoch: Int, bytes: Int?, ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard callEpoch == epoch else { return }
        snapshot.inFlight = max(0, snapshot.inFlight - 1)
        guard var entry = snapshot.byRequest[label] else { return }
        entry.completed += 1
        entry.totalMs += ms
        if let bytes {
            entry.bytes += bytes
        } else {
            entry.failures += 1
        }
        snapshot.byRequest[label] = entry
    }

    func currentEpoch() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// A producer that reached the gate after every consumer left. Ignored
    /// when it belongs to an epoch that `reset()` has since closed.
    func skippedForLackOfDemand(epoch callEpoch: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard callEpoch == epoch else { return }
        snapshot.skippedNoDemand += 1
    }

    func current() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        snapshot = Snapshot()
        epoch += 1
    }
}
