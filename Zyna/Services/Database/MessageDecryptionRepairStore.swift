//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

/// Durable work queue and proofs, scoped by the owning account database.
/// SDK-hidden events and explicit app exclusions can remove placeholders.
enum MessageDecryptionRepairStore {
    /// Raw history bounds remain independent from admission to the chat.
    struct Focus: Equatable, Sendable {
        let oldest: TimeInterval
        let newest: TimeInterval
    }

    static func migratePresentation(_ db: Database) throws {
        // Early development builds already recorded v30 before the priority
        // column was added. Preserve their work and proofs when upgrading.
        if try !db.columns(in: "messageDecryptionRepair").contains(where: { $0.name == "priorityTimestamp" }) {
            try db.execute(sql: """
                ALTER TABLE messageDecryptionRepair ADD COLUMN priorityTimestamp REAL NOT NULL DEFAULT 0;
                UPDATE messageDecryptionRepair SET priorityTimestamp = coalesce((
                    SELECT timestamp FROM storedMessage m
                    WHERE m.id = messageDecryptionRepair.messageId
                      AND m.roomId = messageDecryptionRepair.roomId
                      AND m.eventId = messageDecryptionRepair.eventId
                ), 0);
                DROP INDEX IF EXISTS messageDecryptionRepair_due;
                CREATE INDEX messageDecryptionRepair_due
                    ON messageDecryptionRepair(roomId, isHidden, nextAttemptAt, priorityTimestamp DESC, eventId);
                """)
        }
        try db.execute(sql: """
            ALTER TABLE messageDecryptionRepair ADD COLUMN lastOutcome TEXT NOT NULL DEFAULT 'pending';
            CREATE INDEX messageDecryptionRepair_focus
                ON messageDecryptionRepair(roomId, isHidden, priorityTimestamp DESC);
            CREATE INDEX storedMessage_presentable
                ON storedMessage(roomId, timestamp, id)
                WHERE contentType != 'call' AND contentType != 'unableToDecrypt';
            """)
    }

    /// Used by boundary peeks; unresolved records cannot decorate a cluster.
    static let admittedSQL = """
        storedMessage.contentType != 'unableToDecrypt' AND NOT EXISTS (
            SELECT 1 FROM messageDecryptionRepair q
            WHERE q.roomId = storedMessage.roomId AND q.eventId = storedMessage.eventId
              AND q.messageId = storedMessage.id AND q.isHidden = 0
        )
        """

    /// Typed UTDs need no lookup. Only old localized candidates require a
    /// bounded proof lookup in the same snapshot as the stored rows.
    static func admitted(_ messages: [StoredMessage], in db: Database) throws -> [StoredMessage] {
        let legacy = messages.filter { $0.isLegacyDecryptionCandidate && $0.eventId != nil }
        var pending = Set<String>()
        for start in stride(from: 0, to: legacy.count, by: 200) {
            let group = legacy[start..<min(start + 200, legacy.count)]
            let ids = group.compactMap(\.eventId)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let values: [DatabaseValueConvertible] = [group.first!.roomId] + ids
            pending.formUnion(try String.fetchAll(db, sql: """
                SELECT messageId FROM messageDecryptionRepair
                WHERE roomId = ? AND isHidden = 0 AND eventId IN (\(placeholders))
                """, arguments: StatementArguments(values)))
        }
        return messages.filter { $0.decryptionFailure == nil && !pending.contains($0.id) }
    }
    struct Candidate: Sendable {
        let message: StoredMessage
        let generation: String
        let attemptCount: Int
    }

    struct ProjectionCursor: Sendable {
        let timestamp: TimeInterval
        let eventID: String
    }

    struct ProjectionCandidate: Sendable {
        let eventID: String
        let sender: String
        let cursor: ProjectionCursor
        let isProjection: Bool
    }

    /// Reuse the pending queue's priority index; inspect only one small page,
    /// including unresolved non-projections so they cannot force a full scan.
    /// This is independent of the network inspection retry deadline.
    static func projectionPage(in db: Database, roomID: String,
                               after: ProjectionCursor?) throws -> [ProjectionCandidate] {
        var arguments: [DatabaseValueConvertible] = [roomID]
        if let after { arguments += [after.timestamp, after.timestamp, after.eventID] }
        return try Row.fetchAll(db, sql: """
            SELECT q.eventId, q.priorityTimestamp, q.lastOutcome, m.senderId
            FROM messageDecryptionRepair q INDEXED BY messageDecryptionRepair_focus
            JOIN storedMessage m ON m.id = q.messageId AND m.roomId = q.roomId AND m.eventId = q.eventId
            WHERE q.roomId = ? AND q.isHidden = 0
            \(after == nil ? "" : "AND q.priorityTimestamp <= ? AND (q.priorityTimestamp < ? OR q.eventId < ?)")
            ORDER BY q.priorityTimestamp DESC, q.eventId DESC LIMIT 16
            """, arguments: StatementArguments(arguments)).map {
                let eventID: String = $0["eventId"]
                return ProjectionCandidate(eventID: eventID, sender: $0["senderId"],
                    cursor: ProjectionCursor(timestamp: $0["priorityTimestamp"], eventID: eventID),
                    isProjection: $0["lastOutcome"] as String == "projection")
            }
    }

    static func migrate(_ db: Database) throws {
        // Frozen SQL: future model changes must not affect old migrations.
        try db.execute(sql: """
            CREATE TABLE messageDecryptionRepair (
                roomId TEXT NOT NULL,
                eventId TEXT NOT NULL,
                messageId TEXT NOT NULL,
                generation TEXT NOT NULL,
                failureKey TEXT NOT NULL,
                isHidden INTEGER NOT NULL DEFAULT 0,
                attemptCount INTEGER NOT NULL DEFAULT 0,
                nextAttemptAt REAL NOT NULL DEFAULT 0,
                priorityTimestamp REAL NOT NULL,
                PRIMARY KEY (roomId, eventId)
            );
            CREATE INDEX messageDecryptionRepair_due
                ON messageDecryptionRepair(roomId, isHidden, nextAttemptAt, priorityTimestamp DESC, eventId);
            CREATE TRIGGER messageDecryptionRepair_delete AFTER DELETE ON storedMessage BEGIN
                DELETE FROM messageDecryptionRepair WHERE messageId = OLD.id AND roomId = OLD.roomId
                    AND eventId = OLD.eventId AND isHidden = 0;
            END;
            CREATE TRIGGER messageDecryptionRepair_identity AFTER UPDATE OF eventId, roomId ON storedMessage
                WHEN OLD.eventId IS NOT NEW.eventId OR OLD.roomId != NEW.roomId BEGIN
                DELETE FROM messageDecryptionRepair WHERE messageId = OLD.id AND roomId = OLD.roomId
                    AND eventId = OLD.eventId AND isHidden = 0;
            END;
            CREATE TRIGGER messageDecryptionRepair_resolved AFTER UPDATE OF contentType, contentBody ON storedMessage
                WHEN NEW.contentType != 'unableToDecrypt' AND
                    (OLD.contentType != NEW.contentType OR OLD.contentBody IS NOT NEW.contentBody) BEGIN
                DELETE FROM messageDecryptionRepair WHERE roomId = NEW.roomId AND eventId = NEW.eventId;
            END;
            INSERT INTO messageDecryptionRepair
                (roomId, eventId, messageId, generation, failureKey, priorityTimestamp)
            SELECT roomId, eventId, id, lower(hex(randomblob(16))),
                   contentType || ':' || coalesce(contentBody, ''), timestamp
            FROM storedMessage
            WHERE eventId IS NOT NULL AND eventId != '' AND (
                contentType = 'unableToDecrypt' OR (contentType = 'text' AND
                    contentBody IN ('Unable to decrypt message', 'Не удалось расшифровать сообщение'))
            );
            """)
    }

    static func suppresses(_ record: StoredMessage, in db: Database) throws -> Bool {
        guard record.decryptionFailure != nil, let eventID = record.eventId else { return false }
        return try Bool.fetchOne(db, sql: """
            SELECT isHidden FROM messageDecryptionRepair WHERE roomId = ? AND eventId = ?
            """, arguments: [record.roomId, eventID]) == true
    }

    static func isPendingLegacy(_ record: StoredMessage, in db: Database) throws -> Bool {
        guard record.isLegacyDecryptionCandidate, let eventID = record.eventId else { return false }
        return try Bool.fetchOne(db, sql: """
            SELECT isHidden = 0 FROM messageDecryptionRepair WHERE roomId = ? AND eventId = ? AND messageId = ?
            """, arguments: [record.roomId, eventID, record.id]) == true
    }

    /// Called with the final merged SDK projection, in its write transaction.
    /// A real text message with the old error label is never newly enqueued.
    static func didProject(_ record: StoredMessage, in db: Database) throws {
        guard let eventID = record.eventId, !eventID.isEmpty else { return }
        guard record.decryptionFailure != nil else {
            try db.execute(sql: "DELETE FROM messageDecryptionRepair WHERE roomId = ? AND eventId = ?",
                           arguments: [record.roomId, eventID])
            return
        }
        try db.execute(sql: """
            INSERT INTO messageDecryptionRepair
                (roomId, eventId, messageId, generation, failureKey, priorityTimestamp)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(roomId, eventId) DO UPDATE SET
                messageId = excluded.messageId, generation = excluded.generation,
                failureKey = excluded.failureKey, attemptCount = 0, nextAttemptAt = 0, lastOutcome = 'pending'
            WHERE isHidden = 0 AND (messageId != excluded.messageId OR failureKey != excluded.failureKey)
            """, arguments: [record.roomId, eventID, record.id, UUID().uuidString,
                              record.contentType + ":" + (record.contentBody ?? ""), record.timestamp])
    }

    static func retrySoon(eventID: String, roomID: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE messageDecryptionRepair SET nextAttemptAt = 0
            WHERE roomId = ? AND eventId = ? AND isHidden = 0 AND nextAttemptAt > 0
            """, arguments: [roomID, eventID])
    }

    static func retryPage(in db: Database, roomID: String, focus: Focus?) throws {
        var values: [DatabaseValueConvertible] = [roomID, roomID]
        if let focus { values += [focus.oldest, focus.newest] }
        try db.execute(sql: """
            UPDATE messageDecryptionRepair SET nextAttemptAt = 0, lastOutcome = 'pending'
            WHERE roomId = ? AND eventId IN (
                SELECT eventId FROM messageDecryptionRepair WHERE roomId = ? AND isHidden = 0
                \(focus == nil ? "" : "AND priorityTimestamp BETWEEN ? AND ?")
                ORDER BY priorityTimestamp DESC LIMIT 32
            )
            """, arguments: StatementArguments(values))
    }

    static func candidates(in db: Database, roomID: String, now: TimeInterval, limit: Int = 8,
                           focus: Focus? = nil) throws -> [Candidate] {
        if let focus {
            let focused = try fetchCandidates(in: db, roomID: roomID, now: now, limit: limit, focus: focus)
            if !focused.isEmpty { return focused }
        }
        return try fetchCandidates(in: db, roomID: roomID, now: now, limit: limit, focus: nil)
    }

    private static func fetchCandidates(in db: Database, roomID: String, now: TimeInterval,
                                        limit: Int, focus: Focus?) throws -> [Candidate] {
        // The queue index bounds the read independently of room history size.
        var values: [DatabaseValueConvertible] = [roomID, now]
        if let focus { values += [focus.oldest, focus.newest] }
        values.append(limit)
        return try Row.fetchAll(db, sql: """
            SELECT m.*, q.generation AS repairGeneration, q.attemptCount AS repairAttemptCount
            FROM messageDecryptionRepair q \(focus == nil ? "" : "INDEXED BY messageDecryptionRepair_focus") JOIN storedMessage m
              ON m.id = q.messageId AND m.roomId = q.roomId AND m.eventId = q.eventId
            WHERE q.roomId = ? AND q.isHidden = 0 AND q.nextAttemptAt <= ?
            \(focus == nil ? "" : "AND q.priorityTimestamp BETWEEN ? AND ?")
            ORDER BY q.nextAttemptAt, q.priorityTimestamp DESC, q.eventId LIMIT ?
            """, arguments: StatementArguments(values)).map {
                Candidate(message: try StoredMessage(row: $0), generation: $0["repairGeneration"],
                          attemptCount: $0["repairAttemptCount"])
            }
    }

    /// Compare both the queue generation and the complete current row. A
    /// delayed result cannot replace a newer projection or a recreated UTD.
    @discardableResult
    static func apply(_ inspection: RoomTimelineEventInspection?, to candidate: Candidate,
                      in db: Database, now: TimeInterval) throws -> Bool {
        try applyWithImpact(inspection, to: candidate, in: db, now: now) != .none
    }

    enum Impact { case none, unadmittedRows, presentation }

    /// Classify the committed mutation, not just the SDK disposition: a
    /// visible result may remove a carrier or admit a real error-label text.
    static func applyWithImpact(_ inspection: RoomTimelineEventInspection?, to candidate: Candidate,
                                in db: Database, now: TimeInterval) throws -> Impact {
        let message = candidate.message
        guard let eventID = message.eventId,
              let row = try Row.fetchOne(db, sql: """
                SELECT generation, isHidden FROM messageDecryptionRepair WHERE roomId = ? AND eventId = ?
                """, arguments: [message.roomId, eventID]),
              row["generation"] as String == candidate.generation, row["isHidden"] as Bool == false
        else { return .none }
        let current = try StoredMessage.fetchOne(db, key: message.id)
        guard let current, current.roomId == message.roomId, current.eventId == eventID,
              current.decryptionFailure != nil || current.isLegacyDecryptionCandidate else {
            try db.execute(sql: "DELETE FROM messageDecryptionRepair WHERE roomId = ? AND eventId = ?",
                           arguments: [message.roomId, eventID])
            return .none
        }
        guard current == message else { return .none }

        // SDK checks identity too; keeping this boundary explicit also makes
        // accidental cross-room use of the worker harmless.
        let valid = inspection.flatMap { value -> RoomTimelineEventInspection? in
            guard value.event.roomId == message.roomId, value.event.eventId == eventID,
                  value.event.sender == message.senderId else { return nil }
            return value
        }
        let exclusion = valid.flatMap { ChatEventVisibility.exclusion(for: $0) }
        if valid?.disposition == .hidden || exclusion != nil {
            try db.execute(sql: """
                UPDATE messageDecryptionRepair SET isHidden = 1, lastOutcome = ?
                WHERE roomId = ? AND eventId = ?
                """, arguments: [exclusion?.rawValue ?? "hidden", message.roomId, eventID])
            _ = try StoredMessage.deleteOne(db, key: message.id)
            return .unadmittedRows
        }

        var changed = false
        if let valid, valid.disposition == .unableToDecrypt, let failure = valid.decryptionFailure {
            var updated = message
            updated.contentType = "unableToDecrypt"
            updated.contentBody = ChatDecryptionFailure(failure).rawValue
            if updated != message {
                try updated.update(db)
                changed = true
            }
        } else if let valid, valid.disposition == .visible, message.isLegacyDecryptionCandidate,
                  valid.event.eventType == "m.room.message",
                  let content = try? JSONSerialization.jsonObject(with: Data(valid.event.contentJson.utf8)) as? [String: Any],
                  content["body"] as? String == message.contentBody {
            // A user really sent the error label. Keep it as ordinary text.
            try db.execute(sql: "DELETE FROM messageDecryptionRepair WHERE roomId = ? AND eventId = ?",
                           arguments: [message.roomId, eventID])
            return .presentation
        }
        // `visible` is not an aggregated timeline item. Leave hydration to
        // normal SDK diffs; errors, unknown events, and missing keys stay too.
        let delay = min(300.0, 15.0 * pow(2.0, Double(min(candidate.attemptCount, 5))))
        try db.execute(sql: """
            UPDATE messageDecryptionRepair SET attemptCount = attemptCount + 1, nextAttemptAt = ?, lastOutcome = ?
            WHERE roomId = ? AND eventId = ?
            """, arguments: [now + delay, outcome(valid), message.roomId, eventID])
        return changed ? .unadmittedRows : .none
    }

    private static func outcome(_ inspection: RoomTimelineEventInspection?) -> String {
        switch inspection?.disposition {
        case .unableToDecrypt: return "keys"
        case .visible: return "projection"
        case .indeterminate: return "unknown"
        case .hidden: return "hidden"
        case nil: return "failed"
        }
    }
}
