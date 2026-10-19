//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

private let logPendingReaction = ScopedLog(.timeline, prefix: "[Reaction]")

enum PendingReactionState: String, Codable {
    case addQueued
    case addAccepted
    case removeQueued
    case removed
    case failed
}

struct PendingReactionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingReaction"

    var id: String
    var roomId: String
    var targetEventId: String
    var reactionKey: String
    var state: String
    /// User intent is independent of the request that must finish (or retry)
    /// with its original transaction ID before the next operation can start.
    var desiredPresence: Bool
    var transactionId: String?
    var reactionEventId: String?
    var redactionTransactionId: String?
    var redactionEventId: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastAttemptAt: TimeInterval?
    var attemptCount: Int

    init(
        id: String = UUID().uuidString,
        roomId: String,
        targetEventId: String,
        reactionKey: String,
        state: PendingReactionState,
        desiredPresence: Bool? = nil,
        transactionId: String? = nil,
        reactionEventId: String? = nil,
        redactionTransactionId: String? = nil,
        redactionEventId: String? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        lastAttemptAt: TimeInterval? = nil,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.roomId = roomId
        self.targetEventId = targetEventId
        self.reactionKey = reactionKey
        self.state = state.rawValue
        self.desiredPresence = desiredPresence ?? (state != .removeQueued && state != .removed)
        self.transactionId = transactionId
        self.reactionEventId = reactionEventId
        self.redactionTransactionId = redactionTransactionId
        self.redactionEventId = redactionEventId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAttemptAt = lastAttemptAt
        self.attemptCount = attemptCount
    }

    var decodedState: PendingReactionState {
        get { PendingReactionState(rawValue: state) ?? .failed }
        set { state = newValue.rawValue }
    }
}

final class PendingReactionService {

    static let shared = PendingReactionService()

    private let database: AccountDatabase?
    private var dbQueue: AccountDatabase { database ?? DatabaseService.shared.dbQueue }

    init(database: AccountDatabase? = nil) { self.database = database }

    static func migrateIntent(_ db: Database) throws {
        try db.alter(table: PendingReactionRecord.databaseTableName) {
            $0.add(column: "desiredPresence", .boolean).notNull().defaults(to: true)
        }
        try db.execute(sql: """
            UPDATE pendingReaction SET desiredPresence = 0
            WHERE state IN ('removeQueued', 'removed')
            """)
    }

    #if DEBUG
    func stateForAcceptance(roomId: String, eventId: String) -> [String: Any] {
        (try? dbQueue.read { db -> [String: Any] in
            guard let record = try PendingReactionRecord
                .filter(Column("roomId") == roomId && Column("targetEventId") == eventId && Column("reactionKey") == "👍")
                .order(Column("updatedAt").desc).fetchOne(db) else { return ["state": "absent"] }
            return ["state": record.state, "attempts": record.attemptCount, "desiredPresence": record.desiredPresence,
                "hasReactionID": record.reactionEventId != nil,
                "hasRedactionID": record.redactionEventId != nil]
        }) ?? ["state": "readError"]
    }
    #endif

    /// The row, not a possibly stale menu snapshot, serializes successive taps.
    func prepareToggle(roomId: String, targetEventId: String, key: String,
                       observedOwnReaction: Bool) -> Bool {
        prepareIntent(roomId: roomId, targetEventId: targetEventId, key: key) { record in
            !(record.map { $0.decodedState == .failed ? observedOwnReaction : $0.desiredPresence }
                ?? observedOwnReaction)
        }
    }

    func prepareDirectRawAdd(roomId: String, targetEventId: String, key: String) -> Bool {
        prepareIntent(roomId: roomId, targetEventId: targetEventId, key: key) { _ in true }
    }

    func prepareDirectRawRemoval(roomId: String, targetEventId: String, key: String) -> Bool {
        prepareIntent(roomId: roomId, targetEventId: targetEventId, key: key) { _ in false }
    }

    private func prepareIntent(roomId: String, targetEventId: String, key: String,
                               desired: (PendingReactionRecord?) -> Bool) -> Bool {
        guard DirectRawTextSender.isEnabled else { return false }
        do {
            return try dbQueue.write { db in
                var existing = try Self.latestRecord(roomId: roomId, targetEventId: targetEventId,
                                                     key: key, in: db)
                let presence = desired(existing)
                if existing == nil {
                    guard presence else { return false } // No local ID for a remote-only reaction.
                    existing = PendingReactionRecord(roomId: roomId, targetEventId: targetEventId,
                        reactionKey: key, state: .removed, desiredPresence: false)
                }
                guard var record = existing else { return false }
                if record.decodedState == .failed {
                    // Only an explicit new user action retries a terminal add failure.
                    // A lost legacy reaction ID cannot be reconstructed from a count.
                    guard presence || record.reactionEventId != nil else { return false }
                    record.decodedState = record.reactionEventId == nil ? .removed : .addAccepted
                }
                record.desiredPresence = presence
                Self.advance(&record)
                record.updatedAt = Date().timeIntervalSince1970
                try record.save(db)
                return true
            }
        } catch {
            logPendingReaction("intent prepare failed target=\(targetEventId) error=\(error)")
            return false
        }
    }

    /// Never replace an in-flight operation. A contrary intent is reconciled
    /// atomically with its acknowledgement, including after an app restart.
    private static func advance(_ record: inout PendingReactionRecord) {
        switch record.decodedState {
        case .removed where record.desiredPresence:
            record.decodedState = .addQueued
            record.transactionId = UUID().uuidString
            record.reactionEventId = nil
            record.redactionTransactionId = nil
            record.redactionEventId = nil
            record.attemptCount = 0
            record.lastAttemptAt = nil
        case .addAccepted where !record.desiredPresence:
            record.decodedState = .removeQueued
            record.redactionTransactionId = UUID().uuidString
            record.redactionEventId = nil
            record.attemptCount = 0
            record.lastAttemptAt = nil
        default:
            break
        }
    }

    func outboxCandidates() async -> [PendingReactionRecord] {
        (try? await dbQueue.read { db in
            try PendingReactionRecord.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM pendingReaction
                    WHERE state = ?
                       OR (
                            state = ?
                            AND reactionEventId IS NOT NULL
                            AND redactionTransactionId IS NOT NULL
                       )
                    ORDER BY updatedAt ASC
                """,
                arguments: [
                    PendingReactionState.addQueued.rawValue,
                    PendingReactionState.removeQueued.rawValue
                ]
            )
        }) ?? []
    }

    func record(id: String) -> PendingReactionRecord? {
        try? dbQueue.read { db in
            try PendingReactionRecord.fetchOne(db, key: id)
        }
    }

    func pendingRemovalKeysByEventId(roomId: String) -> [String: Set<String>] {
        (try? dbQueue.read { try Self.pendingRemovalKeysByEventId(roomId: roomId, in: $0) }) ?? [:]
    }

    static func pendingRemovalKeysByEventId(roomId: String, in db: Database) throws -> [String: Set<String>] {
        let records = try PendingReactionRecord
            .filter(Column("roomId") == roomId)
            .order(Column("updatedAt").asc)
            .fetchAll(db)
        var latestByTargetAndKey: [String: PendingReactionRecord] = [:]
        for record in records {
            latestByTargetAndKey[
                "\(record.targetEventId)\u{1F}\(record.reactionKey)"
            ] = record
        }

        var result: [String: Set<String>] = [:]
        for record in latestByTargetAndKey.values {
            if !record.desiredPresence, record.decodedState != .failed {
                result[record.targetEventId, default: []].insert(record.reactionKey)
            }
        }
        return result
    }

    func markAttemptStarted(id: String) {
        do {
            try dbQueue.write { db in
                guard var record = try PendingReactionRecord.fetchOne(db, key: id) else {
                    return
                }
                record.lastAttemptAt = Date().timeIntervalSince1970
                record.attemptCount += 1
                try record.save(db)
            }
        } catch {
            logPendingReaction("attempt metadata failed id=\(id) error=\(error)")
        }
    }

    func applyAcceptedAdd(
        id: String,
        transactionId: String,
        reactionEventId: String
    ) -> Bool {
        let didChange = (try? dbQueue.write { db in
            guard var record = try PendingReactionRecord.fetchOne(db, key: id),
                  record.transactionId == transactionId,
                  record.decodedState == .addQueued else {
                return false
            }
            record.decodedState = .addAccepted
            record.reactionEventId = reactionEventId
            Self.advance(&record)
            record.updatedAt = Date().timeIntervalSince1970
            try record.save(db)
            return true
        }) ?? false

        if didChange {
            logPendingReaction(
                "direct add accepted id=\(id) reaction=\(reactionEventId) tx=\(transactionId)"
            )
        }
        return didChange
    }

    func applyAcceptedRemoval(
        id: String,
        redactionTransactionId: String,
        redactionEventId: String?
    ) -> Bool {
        let didChange = (try? dbQueue.write { db in
            guard var record = try PendingReactionRecord.fetchOne(db, key: id),
                  record.redactionTransactionId == redactionTransactionId,
                  record.decodedState == .removeQueued else {
                return false
            }
            record.decodedState = .removed
            record.redactionEventId = redactionEventId
            Self.advance(&record)
            record.updatedAt = Date().timeIntervalSince1970
            try record.save(db)
            return true
        }) ?? false

        if didChange {
            logPendingReaction(
                "direct remove accepted id=\(id) redaction=\(redactionEventId ?? "-") tx=\(redactionTransactionId)"
            )
        }
        return didChange
    }

    func markAddFailed(id: String, transactionId: String?) {
        updateRecord(id: id) { record in
            guard record.decodedState == .addQueued,
                  record.transactionId == transactionId else { return }
            record.decodedState = .failed
            record.updatedAt = Date().timeIntervalSince1970
        }
    }

    func markRemovalFailed(id: String, transactionId: String?) {
        updateRecord(id: id) { record in
            guard record.decodedState == .removeQueued,
                  record.redactionTransactionId == transactionId else { return }
            record.decodedState = .addAccepted
            record.desiredPresence = true
            record.redactionTransactionId = nil
            record.redactionEventId = nil
            record.updatedAt = Date().timeIntervalSince1970
        }
    }

    private func updateRecord(id: String, _ update: (inout PendingReactionRecord) -> Void) {
        do {
            try dbQueue.write { db in
                guard var record = try PendingReactionRecord.fetchOne(db, key: id) else { return }
                update(&record)
                try record.save(db)
            }
        } catch {
            logPendingReaction("update failed id=\(id) error=\(error)")
        }
    }

    private static func latestRecord(
        roomId: String,
        targetEventId: String,
        key: String,
        in db: Database
    ) throws -> PendingReactionRecord? {
        try PendingReactionRecord
            .filter(
                Column("roomId") == roomId
                    && Column("targetEventId") == targetEventId
                    && Column("reactionKey") == key
            )
            .order(Column("updatedAt").desc)
            .fetchOne(db)
    }
}
