//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Distinguishes history commits visible to a DB snapshot from notifications
/// already delivered to main. Only history/reset commits affect whether a
/// focused live redaction may animate. This is separate from window revision.
///
/// Snapshot consistency relies on DatabaseQueue serializing reads with
/// writes and their commit callbacks. Read `current` inside the snapshot's
/// database read. With DatabasePool, the revision would need to live in the
/// database and advance in the same transaction as the history changes.
///
/// Scoped to one TimelineDiffBatcher and its ordered flush notifications.
/// Commits from another batcher, even for the same room, are not tracked.
/// Supporting concurrent writers would require shared revision tracking
/// and notification provenance, not just sharing this counter.
final class TimelineHistoryRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func observeCommit(_ summary: TimelineFlushSummary, in db: Database) {
        guard summary.hasHistoryOrResetShape else { return }
        db.afterNextTransaction(onCommit: { [self] _ in
            lock.lock()
            revision &+= 1
            lock.unlock()
        })
    }
}
