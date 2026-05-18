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

    private var dbQueue: DatabaseQueue { DatabaseService.shared.dbQueue }

    private init() {}

    func prepareDirectRawAdd(
        roomId: String,
        targetEventId: String,
        key: String
    ) -> Bool {
        guard DirectRawTextSender.isEnabled else { return false }

        do {
            return try dbQueue.write { db in
                let now = Date().timeIntervalSince1970
                var record = try Self.latestRecord(
                    roomId: roomId,
                    targetEventId: targetEventId,
                    key: key,
                    in: db
                )

                let existingTransactionId: String?
                if record?.decodedState == .addQueued {
                    existingTransactionId = record?.transactionId
                } else {
                    existingTransactionId = nil
                }

                guard let transactionId = DirectRawTextSender
                    .prepareReactionTransactionId(existingTransactionId: existingTransactionId)
                else {
                    return false
                }

                if record == nil {
                    record = PendingReactionRecord(
                        roomId: roomId,
                        targetEventId: targetEventId,
                        reactionKey: key,
                        state: .addQueued,
                        transactionId: transactionId,
                        createdAt: now,
                        updatedAt: now
                    )
                } else {
                    record?.decodedState = .addQueued
                    record?.transactionId = transactionId
                    record?.reactionEventId = nil
                    record?.redactionTransactionId = nil
                    record?.redactionEventId = nil
                    record?.updatedAt = now
                }

                try record?.save(db)
                logPendingReaction(
                    "direct add queued target=\(targetEventId) key=\(key) tx=\(transactionId)"
                )
                return true
            }
        } catch {
            logPendingReaction("direct add prepare failed target=\(targetEventId) error=\(error)")
            return false
        }
    }

    func prepareDirectRawRemoval(
        roomId: String,
        targetEventId: String,
        key: String
    ) -> Bool {
        guard DirectRawTextSender.isEnabled else { return false }

        do {
            return try dbQueue.write { db in
                guard var record = try Self.latestRecord(
                    roomId: roomId,
                    targetEventId: targetEventId,
                    key: key,
                    in: db
                ),
                let reactionEventId = record.reactionEventId,
                !reactionEventId.isEmpty else {
                    return false
                }

                guard let transactionId = DirectRawTextSender
                    .prepareRedactionTransactionId(
                        existingTransactionId: record.redactionTransactionId
                    )
                else {
                    return false
                }

                record.decodedState = .removeQueued
                record.redactionTransactionId = transactionId
                record.redactionEventId = nil
                record.updatedAt = Date().timeIntervalSince1970
                try record.save(db)
                logPendingReaction(
                    "direct remove queued target=\(targetEventId) reaction=\(reactionEventId) key=\(key) tx=\(transactionId)"
                )
                return true
            }
        } catch {
            logPendingReaction("direct remove prepare failed target=\(targetEventId) error=\(error)")
            return false
        }
    }

    func outboxCandidates() -> [PendingReactionRecord] {
        (try? dbQueue.read { db in
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
        (try? dbQueue.read { db in
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
                switch record.decodedState {
                case .removeQueued, .removed:
                    result[record.targetEventId, default: []].insert(record.reactionKey)
                case .addQueued, .addAccepted, .failed:
                    break
                }
            }
            return result
        }) ?? [:]
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

    func markAddFailed(id: String) {
        updateRecord(id: id) { record in
            record.decodedState = .failed
            record.updatedAt = Date().timeIntervalSince1970
        }
    }

    func markRemovalFailed(id: String) {
        updateRecord(id: id) { record in
            record.decodedState = .addAccepted
            record.redactionTransactionId = nil
            record.redactionEventId = nil
            record.updatedAt = Date().timeIntervalSince1970
        }
    }

    private func updateRecord(
        id: String,
        _ update: (inout PendingReactionRecord) -> Void
    ) {
        do {
            try dbQueue.write { db in
                guard var record = try PendingReactionRecord.fetchOne(db, key: id) else {
                    return
                }
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
                    && Column("state") != PendingReactionState.removed.rawValue
            )
            .order(Column("updatedAt").desc)
            .fetchOne(db)
    }
}
