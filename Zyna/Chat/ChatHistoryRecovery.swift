//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import GRDB

/// Main-queue presentation of a bounded observation in the account store.
/// Individual unresolved events never become chat rows, even after a delay.
final class ChatHistoryRecovery: ObservableObject {
    struct Snapshot: Equatable, Sendable {
        var pending = false
        var waitingForKeys = false
        var waitingForProjection = false
        var lookupFailed = false
        var unknown = false
        var isEmpty: Bool { !pending && !waitingForKeys && !waitingForProjection && !lookupFailed && !unknown }

        static func fetch(in db: Database, roomID: String) throws -> Self {
            let outcomes = try String.fetchAll(db, sql: """
                SELECT lastOutcome FROM messageDecryptionRepair
                WHERE roomId = ? AND isHidden = 0
                ORDER BY nextAttemptAt, priorityTimestamp DESC, eventId LIMIT 201
                """, arguments: [roomID])
            return Self(pending: outcomes.contains("pending"), waitingForKeys: outcomes.contains("keys"),
                waitingForProjection: outcomes.contains("projection"), lookupFailed: outcomes.contains("failed"),
                unknown: outcomes.contains { !["pending", "keys", "projection", "failed"].contains($0) })
        }
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isNoticeVisible = false
    private var observation: AnyDatabaseCancellable?
    private var revealWork: DispatchWorkItem?
    private var stopped = false

    init(roomID: String, database: AccountDatabase, revealDelay: TimeInterval = 1.5) {
        #if DEBUG
        let trace = HistoryPerformanceTrace.capture(database: database)
        #endif
        observation = database.observe(ValueObservation.tracking { db in
            try Snapshot.fetch(in: db, roomID: roomID)
        }, on: .main, onError: { _ in }, onChange: { [weak self] snapshot in
            guard let self, !self.stopped else { return }
            #if DEBUG
            // Reuse the observation's bounded read; diagnostics add no SQL.
            if let trace {
                trace.gauge(.recoveryPending, snapshot.pending ? 1 : 0)
                trace.gauge(.recoveryKeys, snapshot.waitingForKeys ? 1 : 0)
                trace.gauge(.recoveryProjection, snapshot.waitingForProjection ? 1 : 0)
                trace.gauge(.recoveryFailed, snapshot.lookupFailed ? 1 : 0)
                trace.gauge(.recoveryUnknown, snapshot.unknown ? 1 : 0)
            }
            #endif
            if self.snapshot != snapshot { self.snapshot = snapshot }
            if snapshot.isEmpty {
                self.revealWork?.cancel()
                self.revealWork = nil
                self.isNoticeVisible = false
            } else if !self.isNoticeVisible, self.revealWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.stopped, database.isActive else { return }
                    self.revealWork = nil
                    self.isNoticeVisible = !self.snapshot.isEmpty
                }
                self.revealWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay, execute: work)
            }
        })
    }

    var explanation: String {
        var paragraphs = [String(localized: "Some history is still being recovered. Available messages appear automatically.")]
        if snapshot.waitingForKeys {
            paragraphs.append(String(localized: "Encryption keys are still missing for part of the history. Restoring your encrypted history may help."))
        }
        if snapshot.lookupFailed {
            paragraphs.append(String(localized: "Some history could not be checked. Check your connection and try again."))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    func stop() {
        stopped = true
        observation?.cancel()
        observation = nil
        revealWork?.cancel()
        revealWork = nil
    }

    deinit { stop() }
}
