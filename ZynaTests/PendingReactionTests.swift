// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Persistent reaction intent")
struct PendingReactionTests {
    private let room = "!reactions:test"
    private let target = "$message"
    private let key = "👍"

    private func database(path: String? = nil) throws -> AccountDatabase {
        let queue = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pendingReaction (
                    id TEXT PRIMARY KEY, roomId TEXT NOT NULL, targetEventId TEXT NOT NULL,
                    reactionKey TEXT NOT NULL, state TEXT NOT NULL, desiredPresence BOOLEAN NOT NULL,
                    transactionId TEXT, reactionEventId TEXT, redactionTransactionId TEXT,
                    redactionEventId TEXT, createdAt DOUBLE NOT NULL, updatedAt DOUBLE NOT NULL,
                    lastAttemptAt DOUBLE, attemptCount INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS reactionTarget ON pendingReaction(roomId, targetEventId, reactionKey);
                """)
        }
        return AccountDatabase(queue)
    }

    private func current(_ db: AccountDatabase) throws -> PendingReactionRecord {
        try #require(db.read { try PendingReactionRecord.fetchOne($0) })
    }

    private func toggle(_ service: PendingReactionService, observed: Bool = false) -> Bool {
        service.prepareToggle(roomId: room, targetEventId: target, key: key, observedOwnReaction: observed)
    }

    private func acceptAdd(_ service: PendingReactionService, _ record: PendingReactionRecord,
                           event: String = "$reaction") throws -> Bool {
        service.applyAcceptedAdd(id: record.id, transactionId: try #require(record.transactionId), reactionEventId: event)
    }

    private func acceptRemoval(_ service: PendingReactionService, _ record: PendingReactionRecord) throws -> Bool {
        service.applyAcceptedRemoval(id: record.id, redactionTransactionId: try #require(record.redactionTransactionId),
                                     redactionEventId: "$redaction")
    }

    @Test("An accepted add keeps its ID when a stale snapshot is toggled again")
    func staleSnapshotAfterAcceptance() throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(toggle(service))
        let addition = try current(db)
        #expect(try acceptAdd(service, addition))
        // Reproduced on both live fixtures: the menu still sees no own reaction.
        #expect(toggle(service, observed: false))
        let removal = try current(db)
        #expect(removal.decodedState == .removeQueued)
        #expect(!removal.desiredPresence)
        #expect(removal.transactionId == addition.transactionId)
        #expect(removal.reactionEventId == "$reaction")
        #expect(removal.redactionTransactionId != nil)
        #expect(try acceptRemoval(service, removal))
        #expect(try current(db).decodedState == .removed)
    }

    @Test("Explicit add is idempotent and never discards an accepted ID")
    func repeatedAdd() throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(service.prepareDirectRawAdd(roomId: room, targetEventId: target, key: key))
        let sent = try current(db)
        #expect(try acceptAdd(service, sent))
        #expect(service.prepareDirectRawAdd(roomId: room, targetEventId: target, key: key))
        let current = try current(db)
        #expect(current.decodedState == .addAccepted)
        #expect(current.reactionEventId == "$reaction")
        #expect(current.transactionId == sent.transactionId)
    }

    @Test("Taps during an outstanding add preserve its operation and settle to the last intent", arguments: [2, 3, 6, 7])
    func pendingAdd(taps: Int) async throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(toggle(service))
        let original = try current(db)
        for _ in 1..<taps { #expect(toggle(service)) }
        let pending = try current(db)
        #expect(pending.decodedState == .addQueued)
        #expect(pending.transactionId == original.transactionId)
        #expect(pending.desiredPresence == (taps % 2 == 1))
        #expect(try acceptAdd(service, original))
        let acknowledged = try current(db)
        #expect(acknowledged.reactionEventId == "$reaction")
        if taps % 2 == 0 {
            #expect(acknowledged.decodedState == .removeQueued)
            #expect(await service.outboxCandidates().map(\.id) == [original.id])
            #expect(try acceptRemoval(service, acknowledged))
        } else {
            #expect(acknowledged.decodedState == .addAccepted)
        }
        #expect(await service.outboxCandidates().isEmpty)
        #expect(try await db.read { try PendingReactionRecord.fetchCount($0) } == 1)
    }

    @Test("Re-add waits for a pending removal, then uses a fresh transaction")
    func reverseRemoval() throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(toggle(service))
        let first = try current(db)
        #expect(try acceptAdd(service, first))
        #expect(toggle(service, observed: true))
        let removal = try current(db)
        #expect(toggle(service, observed: true))
        let reversed = try current(db)
        #expect(reversed.decodedState == .removeQueued)
        #expect(reversed.desiredPresence)
        #expect(reversed.redactionTransactionId == removal.redactionTransactionId)
        #expect(reversed.reactionEventId == "$reaction")
        #expect(try acceptRemoval(service, removal))
        let second = try current(db)
        #expect(second.decodedState == .addQueued)
        #expect(second.transactionId != first.transactionId)
        #expect(second.reactionEventId == nil)
        #expect(try acceptAdd(service, second, event: "$second"))
        #expect(try current(db).reactionEventId == "$second")
    }

    @Test("A second reversal while removing does not send a new add")
    func reverseRemovalTwice() async throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(toggle(service)); #expect(try acceptAdd(service, current(db)))
        #expect(toggle(service)); let removal = try current(db)
        #expect(toggle(service)); #expect(toggle(service))
        #expect(try acceptRemoval(service, removal))
        #expect(try current(db).decodedState == .removed)
        #expect(await service.outboxCandidates().isEmpty)
        // A stale post-redaction snapshot may still show the old reaction.
        #expect(toggle(service, observed: true))
        #expect(try current(db).decodedState == .addQueued)
    }

    @Test("Delayed successes and failures cannot overwrite a newer operation")
    func staleCompletions() throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(toggle(service)); let oldAdd = try current(db)
        #expect(try acceptAdd(service, oldAdd))
        #expect(toggle(service)); let oldRemove = try current(db)
        #expect(toggle(service)); #expect(try acceptRemoval(service, oldRemove))
        let newAdd = try current(db)
        #expect(try !acceptAdd(service, oldAdd, event: "$stale"))
        #expect(try !acceptRemoval(service, oldRemove))
        service.markAddFailed(id: oldAdd.id, transactionId: oldAdd.transactionId)
        service.markRemovalFailed(id: oldRemove.id, transactionId: oldRemove.redactionTransactionId)
        #expect(try current(db).transactionId == newAdd.transactionId)
        #expect(try current(db).decodedState == .addQueued)
        #expect(try acceptAdd(service, newAdd, event: "$new"))
        #expect(toggle(service)); let newRemove = try current(db)
        service.markRemovalFailed(id: oldRemove.id, transactionId: oldRemove.redactionTransactionId)
        #expect(try current(db).redactionTransactionId == newRemove.redactionTransactionId)
        #expect(try current(db).decodedState == .removeQueued)
    }

    @Test("Terminal failures roll back presentation without erasing the accepted reaction")
    func terminalFailures() throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(toggle(service)); let first = try current(db)
        service.markAddFailed(id: first.id, transactionId: first.transactionId)
        #expect(try current(db).decodedState == .failed)
        #expect(toggle(service)); let retry = try current(db)
        #expect(retry.transactionId != first.transactionId)
        #expect(try acceptAdd(service, retry))
        #expect(toggle(service)); let removal = try current(db)
        service.markRemovalFailed(id: removal.id, transactionId: removal.redactionTransactionId)
        #expect(try current(db).decodedState == .addAccepted)
        #expect(try current(db).desiredPresence)
        #expect(try current(db).reactionEventId == "$reaction")
        #expect(service.pendingRemovalKeysByEventId(roomId: room).isEmpty)
    }

    @Test("Desired removals and reversals drive the overlay independently of network progress")
    func presentationIntent() throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(toggle(service)); #expect(toggle(service))
        #expect(service.pendingRemovalKeysByEventId(roomId: room)[target] == [key])
        #expect(toggle(service))
        #expect(service.pendingRemovalKeysByEventId(roomId: room).isEmpty)
        #expect(try acceptAdd(service, current(db)))
        #expect(toggle(service)); #expect(toggle(service))
        #expect(service.pendingRemovalKeysByEventId(roomId: room).isEmpty)
    }

    @Test("Cancelled requests resume after reopening with the same transaction and latest intent")
    func reopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        var operation: PendingReactionRecord!
        do {
            let db = try database(path: url.path), service = PendingReactionService(database: db)
            #expect(toggle(service)); operation = try current(db)
            #expect(toggle(service)) // network completion is deliberately absent
        }
        do {
            let db = try database(path: url.path), service = PendingReactionService(database: db)
            #expect(try current(db).transactionId == operation.transactionId)
            #expect(try !current(db).desiredPresence)
            #expect(try acceptAdd(service, operation))
            operation = try current(db)
            #expect(toggle(service)) // re-add while redaction's response is missing
        }
        let db = try database(path: url.path), service = PendingReactionService(database: db)
        #expect(try current(db).redactionTransactionId == operation.redactionTransactionId)
        #expect(try current(db).desiredPresence)
        #expect(try acceptRemoval(service, operation))
        #expect(try current(db).decodedState == .addQueued)
    }

    @Test("SQLite write failures keep the operation and intent retryable")
    func rollback() throws {
        let db = try database(), service = PendingReactionService(database: db)
        #expect(toggle(service)); let initial = try current(db)
        try db.write { try $0.execute(sql: "CREATE TRIGGER fail_update BEFORE UPDATE ON pendingReaction BEGIN SELECT RAISE(ABORT, 'test'); END") }
        #expect(!toggle(service))
        #expect(try !acceptAdd(service, initial))
        #expect(try current(db).desiredPresence)
        #expect(try current(db).transactionId == initial.transactionId)
        #expect(try current(db).decodedState == .addQueued)
        try db.write { try $0.execute(sql: "DROP TRIGGER fail_update") }
        #expect(try acceptAdd(service, initial))
        #expect(try current(db).reactionEventId == "$reaction")
    }

    @Test("Other rooms, targets and keys do not share intent")
    func isolation() throws {
        let db = try database(), service = PendingReactionService(database: db)
        for (r, t, k) in [(room, target, key), ("!other:test", target, key), (room, "$other", key), (room, target, "🔥")] {
            #expect(service.prepareToggle(roomId: r, targetEventId: t, key: k, observedOwnReaction: false))
        }
        #expect(toggle(service))
        let rows = try db.read { try PendingReactionRecord.fetchAll($0) }
        #expect(rows.count == 4)
        #expect(rows.filter { !$0.desiredPresence }.count == 1)
        #expect(service.pendingRemovalKeysByEventId(roomId: "!other:test").isEmpty)
    }

    @Test("v37 preserves IDs and derives intent for all existing states")
    func migration() async throws {
        try await Task.detached {
            let db = try DatabaseQueue(), migrator = DatabaseService.migrator
            try migrator.migrate(db, upTo: "v36_roomAttachmentListCatalogs")
            let states = ["addQueued", "addAccepted", "removeQueued", "removed", "failed"]
            try db.write { db in
                for state in states {
                    try db.execute(sql: """
                        INSERT INTO pendingReaction(id, roomId, targetEventId, reactionKey, state,
                            transactionId, reactionEventId, redactionTransactionId, createdAt, updatedAt)
                        VALUES (?, '!r:test', '$target', 'x', ?, 'keep-tx', 'keep-event', 'keep-redaction', 1, 2)
                        """, arguments: [state, state])
                }
            }
            try migrator.migrate(db)
            try db.read { db in
                let rows = try PendingReactionRecord.fetchAll(db)
                #expect(rows.count == states.count)
                for row in rows {
                    #expect(row.desiredPresence == !["removeQueued", "removed"].contains(row.state))
                    #expect(row.transactionId == "keep-tx")
                    #expect(row.reactionEventId == "keep-event")
                    #expect(row.redactionTransactionId == "keep-redaction")
                    #expect(row.updatedAt == 2)
                }
            }
        }.value
    }
}
