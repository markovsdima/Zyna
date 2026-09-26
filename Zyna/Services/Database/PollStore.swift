//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import GRDB
import MatrixRustSDK

struct StoredRoomPoll: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "roomPoll"
    var roomId: String
    var eventId: String
    var timestamp: TimeInterval
    var senderId: String
    var senderName: String?
    var snapshotJSON: String
    var isRedacted: Bool

    var snapshot: PollSnapshot? { PollCoding.decode(PollSnapshot.self, from: snapshotJSON) }
}

struct PendingPollOperation: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingPollOperation"
    enum State: String { case queued, sending, retrying, accepted, failed }

    var id: String
    var sequence: Int64
    var roomId: String
    var pollStartEventId: String?
    var envelopeId: String?
    var sessionId: String
    var kind: String
    var definitionJSON: String?
    var answersJSON: String?
    var text: String?
    var transactionId: String
    var eventId: String?
    var state: String
    var attemptCount: Int
    var retryAt: TimeInterval?
    var confirmationCursor: String? = nil
    var serverTimestamp: Int64? = nil
    var confirmationAt: TimeInterval? = nil
    var confirmationSawOwnEvent: Bool = false
    var confirmationEditEventID: String? = nil
    var failureReason: String? = nil

    var operationKind: PollOperationKind? { PollOperationKind(rawValue: kind) }
    var definition: PollDefinition? { PollCoding.decode(PollDefinition.self, from: definitionJSON) }
    var answers: [String]? { PollCoding.decode([String].self, from: answersJSON) }
    var targetKey: String { roomId + "\u{1F}" + (pollStartEventId ?? envelopeId ?? id) }
}

/// One persistent poll catalog for chat and the future attachments tab.
/// `storedMessage.contentPollJSON` is only a materialized presentation cache;
/// confirmed state and pending intent are always kept separate here.
final class PollStore {
    static let shared = PollStore()
    let roomDidUpdate = PassthroughSubject<String, Never>()
    private let queue = DispatchQueue(label: "com.zyna.polls.store", qos: .userInitiated)
    private let database: () -> DatabaseQueue
    static let confirmationDelay: TimeInterval = 15
    static let confirmationPageDelay: TimeInterval = 2
    static let confirmationRetryDelay: TimeInterval = 30

    init(database: @escaping () -> DatabaseQueue = { DatabaseService.shared.dbQueue }) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.alter(table: "storedMessage") { t in
            t.add(column: "contentPollJSON", .text)
        }
        try db.create(table: "roomPoll") { t in
            t.column("roomId", .text).notNull()
            t.column("eventId", .text).notNull()
            t.column("timestamp", .double).notNull()
            t.column("senderId", .text).notNull()
            t.column("senderName", .text)
            t.column("snapshotJSON", .text).notNull()
            t.column("isRedacted", .boolean).notNull().defaults(to: false)
            t.primaryKey(["roomId", "eventId"])
        }
        try db.execute(sql: """
            CREATE INDEX roomPoll_active_room_date ON roomPoll(roomId, timestamp, eventId) WHERE isRedacted = 0
            """)
        try db.create(table: "pendingPollOperation") { t in
            t.primaryKey("id", .text)
            t.column("sequence", .integer).notNull().unique()
            t.column("roomId", .text).notNull()
            t.column("pollStartEventId", .text)
            t.column("envelopeId", .text)
                .references("pendingMediaGroup", onDelete: .cascade)
            t.column("sessionId", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("definitionJSON", .text)
            t.column("answersJSON", .text)
            t.column("text", .text)
            t.column("transactionId", .text).notNull().unique()
            t.column("eventId", .text)
            t.column("state", .text).notNull()
            t.column("attemptCount", .integer).notNull().defaults(to: 0)
            t.column("retryAt", .double)
            t.column("confirmationCursor", .text)
            t.column("serverTimestamp", .integer)
            t.column("confirmationAt", .double)
            t.column("confirmationSawOwnEvent", .boolean).notNull().defaults(to: false)
            t.column("confirmationEditEventID", .text)
            t.column("failureReason", .text)
        }
        try db.create(index: "pollOperation_target", on: "pendingPollOperation", columns: ["roomId", "pollStartEventId", "sequence"])
    }

    static func isPollStartEvent(originalJSON: String?) -> Bool {
        guard let data = originalJSON?.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return event["type"] as? String == "org.matrix.msc3381.poll.start"
    }

    /// Called inside the timeline batcher's write transaction, off-main.
    static func ingest(_ record: inout StoredMessage, isPollStart: Bool = false, in db: Database) throws {
        guard let eventId = record.eventId else { return }
        let key: [String: DatabaseValueConvertible] = ["roomId": record.roomId, "eventId": eventId]
        if record.contentType == "redacted" {
            let previous = try StoredRoomPoll.fetchOne(db, key: key)
            let knownPoll = isPollStart || previous != nil
            if !knownPoll {
                // An encrypted redaction can arrive before the start is indexed,
                // but an accepted local creation still identifies it as a poll.
                guard try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM pendingMediaGroup g JOIN pendingMediaGroupItem i ON i.groupId = g.id
                    WHERE g.roomId = ? AND g.kind = 'poll' AND i.eventId = ?)
                    """, arguments: [record.roomId, eventId]) == true else { return }
            }
            record.contentBody = nil
            record.contentPollJSON = nil
            guard previous?.isRedacted != true else { return }
            // Only known polls belong in this catalog. Unknown encrypted
            // redactions remain protected by the ordinary storedMessage row.
            try StoredRoomPoll(roomId: record.roomId, eventId: eventId, timestamp: record.timestamp,
                senderId: record.senderId, senderName: record.senderDisplayName,
                snapshotJSON: "{}", isRedacted: true).save(db)
            try deleteOperations(roomId: record.roomId, eventId: eventId, in: db)
            try deleteCreation(roomId: record.roomId, eventId: eventId, in: db)
            return
        }
        guard record.contentType == "poll",
              var snapshot = PollCoding.decode(PollSnapshot.self, from: record.contentPollJSON) else { return }
        let previous = try StoredRoomPoll.fetchOne(db, key: key)
        if previous == nil, try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM storedMessage WHERE roomId = ? AND eventId = ? AND contentType = 'redacted')
            """, arguments: [record.roomId, eventId]) == true {
            record.contentType = "redacted"
            try ingest(&record, isPollStart: true, in: db)
            return
        }
        if let previous {
            if previous.isRedacted {
                record.contentType = "redacted"
                record.contentBody = nil
                record.contentPollJSON = nil
                return
            }
            // A recreated timeline may initially know the start but not its
            // end. Ending is irreversible; never reopen a cached closed poll.
            if let prior = previous.snapshot, prior.hasEnded, !snapshot.hasEnded {
                snapshot = prior
            } else if let prior = previous.snapshot, prior.isEdited, !snapshot.isEdited {
                snapshot.definition = prior.definition
                snapshot.isEdited = true
                snapshot.latestEditEventID = prior.latestEditEventID
            }
        }
        snapshot.pending = nil
        let poll = StoredRoomPoll(roomId: record.roomId, eventId: eventId,
            timestamp: record.timestamp, senderId: record.senderId, senderName: record.senderDisplayName,
            snapshotJSON: try PollCoding.encode(snapshot), isRedacted: false)
        if previous != poll { try poll.save(db) }
        try reconcile(snapshot, roomId: record.roomId, eventId: eventId, in: db)
        record.contentPollJSON = try PollCoding.encode(presentation(snapshot, roomId: record.roomId, eventId: eventId, in: db))
    }

    static func presentation(_ snapshot: PollSnapshot, roomId: String, eventId: String, in db: Database) throws -> PollSnapshot {
        let operation = try PendingPollOperation
            .filter(Column("roomId") == roomId && Column("pollStartEventId") == eventId)
            .order(Column("sequence").desc).fetchOne(db)
        return presentation(snapshot, operation: operation)
    }

    private static func presentation(_ snapshot: PollSnapshot, operation: PendingPollOperation?) -> PollSnapshot {
        var value = snapshot
        guard !snapshot.hasEnded, let operation, let kind = operation.operationKind else { return value }
        let failed = operation.state == PendingPollOperation.State.failed.rawValue
        value.pending = PollPendingPresentation(operationID: operation.id, kind: kind,
            answers: kind == .response && !failed ? operation.answers : nil,
            failed: failed, awaitingSync: operation.state == PendingPollOperation.State.accepted.rawValue,
            failureReason: operation.failureReason.flatMap(PollFailureReason.init(rawValue:)))
        if kind == .edit, !failed, let definition = operation.definition {
            value.definition = definition
        }
        return value
    }

    private static func reconcile(_ snapshot: PollSnapshot, roomId: String, eventId: String, in db: Database) throws {
        if snapshot.hasEnded {
            // A confirmed end makes further actions obsolete. In-flight HTTP
            // completions cannot recreate operations deleted here.
            try deleteOperations(roomId: roomId, eventId: eventId, in: db)
            return
        }
        let operations = try PendingPollOperation
            .filter(Column("roomId") == roomId && Column("pollStartEventId") == eventId)
            .order(Column("sequence").asc).fetchAll(db)
        // A newer confirmed response supersedes all earlier accepted responses.
        var confirmedResponseSequence: Int64?
        for operation in operations {
            if operation.state == PendingPollOperation.State.failed.rawValue,
               operation.failureReason == PollFailureReason.staleSession.rawValue,
               operation.operationKind == .response, operation.attemptCount > 0,
               let answers = operation.answers, Set(answers) == Set(snapshot.selectedAnswerIDs) {
                // The old request's result is unknown, but its intended choice
                // is already confirmed. Retire only this intent without sending
                // again or treating it as proof of delivery for older actions.
                try operation.delete(db)
                continue
            }
            guard operation.state == PendingPollOperation.State.accepted.rawValue else { continue }
            let matches: Bool
            switch operation.operationKind {
            case .response:
                matches = snapshot.hasEnded || Set(operation.answers ?? []) == Set(snapshot.selectedAnswerIDs)
                if matches { confirmedResponseSequence = operation.sequence }
            case .edit:
                matches = snapshot.isEdited && (snapshot.definition == operation.definition
                    || (operation.eventId != nil && snapshot.latestEditEventID == operation.eventId)
                    || (operation.confirmationEditEventID != nil
                        && snapshot.latestEditEventID == operation.confirmationEditEventID))
            case .end: matches = snapshot.hasEnded
            default: matches = false
            }
            if matches { try operation.delete(db) }
        }
        if let sequence = confirmedResponseSequence {
            try db.execute(sql: "DELETE FROM pendingPollOperation WHERE roomId = ? AND pollStartEventId = ? AND kind = 'response' AND state = 'accepted' AND sequence <= ?",
                           arguments: [roomId, eventId, sequence])
        }
    }

    private static func deleteOperations(roomId: String, eventId: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM pendingPollOperation WHERE roomId = ? AND pollStartEventId = ?",
                       arguments: [roomId, eventId])
    }

    private static func deleteCreation(roomId: String, eventId: String, in db: Database) throws {
        // A sent creation envelope may still be waiting for the chat to open
        // and retire it. Its payload must not outlive a confirmed redaction.
        try db.execute(sql: """
            DELETE FROM pendingMediaGroup WHERE roomId = ? AND kind = 'poll'
            AND id IN (SELECT groupId FROM pendingMediaGroupItem WHERE eventId = ?)
            """, arguments: [roomId, eventId])
    }

    private static func refreshPresentation(roomId: String, eventId: String?, in db: Database) throws {
        guard let eventId,
              let poll = try StoredRoomPoll.fetchOne(db, key: ["roomId": roomId, "eventId": eventId]),
              !poll.isRedacted, let snapshot = poll.snapshot else { return }
        try reconcile(snapshot, roomId: roomId, eventId: eventId, in: db)
        let rendered = try presentation(snapshot, roomId: roomId, eventId: eventId, in: db)
        try db.execute(sql: "UPDATE storedMessage SET contentPollJSON = ? WHERE roomId = ? AND eventId = ? AND contentType = 'poll'",
                       arguments: [try PollCoding.encode(rendered), roomId, eventId])
    }

    @MainActor
    func create(roomId: String, definition: PollDefinition, sessionId: String) async throws -> String {
        let definition = definition.normalized
        guard definition.isValidForCreation else { throw PollError.invalidContent }
        let id = UUID().uuidString
        try await perform { db in
            let payload = OutgoingEnvelopePayload.poll(definition)
            let envelope = OutgoingEnvelopeRecord(id: id, roomId: roomId, caption: nil,
                captionPlacement: CaptionPlacement.bottom.rawValue, expectedItemCount: 1,
                createdAt: Date().timeIntervalSince1970, replyEventId: nil, replySenderId: nil,
                replySenderName: nil, replyBody: nil, kind: OutgoingEnvelopeKind.poll.rawValue,
                state: OutgoingTransportState.queued.rawValue, payloadJSON: payload.encodeJSON(),
                zynaAttributesJSON: nil, matrixSessionId: sessionId)
            let item = OutgoingEnvelopeItemRecord(id: OutgoingEnvelopeItemRecord.makeId(groupId: id, itemIndex: 0),
                groupId: id, itemIndex: 0, bindingToken: nil, transactionId: id, eventId: nil,
                mediaSourceJSON: nil, previewImageData: nil, previewWidth: nil, previewHeight: nil,
                transportState: OutgoingTransportState.queued.rawValue)
            try envelope.insert(db)
            try item.insert(db)
            let operation = try Self.makeOperation(id: id, roomId: roomId, target: nil, envelopeId: id,
                sessionId: sessionId, kind: .start, definition: definition, answers: nil, in: db)
            try operation.insert(db)
        }
        roomDidUpdate.send(roomId)
        return id
    }

    @MainActor
    func enqueue(roomId: String, eventId: String, kind: PollOperationKind,
                 definition: PollDefinition? = nil, answers: [String]? = nil, sessionId: String) async throws {
        try await perform { db in
            guard let poll = try StoredRoomPoll.fetchOne(db, key: ["roomId": roomId, "eventId": eventId]),
                  !poll.isRedacted, let snapshot = poll.snapshot, !snapshot.hasEnded else { throw PollError.unavailable }
            let pending = try PendingPollOperation
                .filter(Column("roomId") == roomId && Column("pollStartEventId") == eventId && Column("state") != "failed")
                .order(Column("sequence").asc).fetchAll(db)
            guard !pending.contains(where: { $0.operationKind == .end || $0.operationKind == .edit }),
                  kind != .edit || pending.isEmpty else { throw PollError.unavailable }
            switch kind {
            case .response:
                guard snapshot.validatesResponse(answers ?? []) else { throw PollError.invalidContent }
                if let latest = pending.last, latest.operationKind == .response,
                   Set(latest.answers ?? []) == Set(answers ?? []) { return }
            case .edit:
                guard snapshot.isEditable else { throw PollError.unavailable }
                guard definition?.isValidForCreation == true else { throw PollError.invalidContent }
            case .end: break
            case .start: throw PollError.invalidContent
            }
            // Only untouched queued votes can be coalesced. Once transport
            // might have seen an operation, its payload and ID are immutable.
            if kind == .response {
                try db.execute(sql: "DELETE FROM pendingPollOperation WHERE roomId = ? AND pollStartEventId = ? AND kind = 'response' AND state = 'queued' AND attemptCount = 0",
                               arguments: [roomId, eventId])
            }
            try db.execute(sql: "DELETE FROM pendingPollOperation WHERE roomId = ? AND pollStartEventId = ? AND state = 'failed'",
                           arguments: [roomId, eventId])
            let operation = try Self.makeOperation(id: UUID().uuidString, roomId: roomId, target: eventId,
                envelopeId: nil, sessionId: sessionId, kind: kind, definition: definition?.normalized,
                answers: answers, in: db)
            try operation.insert(db)
            try Self.refreshPresentation(roomId: roomId, eventId: eventId, in: db)
        }
        roomDidUpdate.send(roomId)
    }

    private static func makeOperation(id: String, roomId: String, target: String?, envelopeId: String?,
                                     sessionId: String, kind: PollOperationKind, definition: PollDefinition?,
                                     answers: [String]?, in db: Database) throws -> PendingPollOperation {
        PendingPollOperation(id: id,
            sequence: (try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM pendingPollOperation")) ?? 1,
            roomId: roomId, pollStartEventId: target, envelopeId: envelopeId, sessionId: sessionId,
            kind: kind.rawValue, definitionJSON: try definition.map(PollCoding.encode),
            answersJSON: try answers.map(PollCoding.encode),
            text: kind == .end ? String(localized: "Poll ended") : nil, transactionId: id,
            eventId: nil, state: PendingPollOperation.State.queued.rawValue, attemptCount: 0, retryAt: nil)
    }

    func candidates() async throws -> [PendingPollOperation] {
        try await perform { db in
            try PendingPollOperation.filter(["queued", "sending", "retrying"].contains(Column("state")))
                .order(Column("sequence").asc).fetchAll(db)
        }
    }

    func awaitingConfirmation() async throws -> [PendingPollOperation] {
        try await perform { db in
            try PendingPollOperation.filter(Column("state") == "accepted" && ["response", "edit"].contains(Column("kind")))
                .order(Column("confirmationAt").asc, Column("sequence").asc).fetchAll(db)
        }
    }

    /// Advance through relations in forward order. A timestamp is proof of a
    /// superseding vote, never a pagination cutoff: ordering is topological.
    /// Edits require the SDK's effective edit after our event in that order.
    func reconcileConfirmationPage(_ operation: PendingPollOperation, serverTimestamp: Int64?,
                                   events: [RawRoomEvent], next: String?, userId: String,
                                   now: TimeInterval = Date().timeIntervalSince1970) async throws {
        let changed = try await perform { db -> Bool in
            guard var current = try PendingPollOperation.fetchOne(db, key: operation.id),
                  current.state == "accepted", let target = current.pollStartEventId,
                  current.confirmationCursor == operation.confirmationCursor else { return false }
            let poll = try StoredRoomPoll.fetchOne(db, key: ["roomId": current.roomId, "eventId": target])
            var superseded = false
            for event in events {
                guard event.roomId == current.roomId, event.sender == userId,
                      let content = try? JSONSerialization.jsonObject(with: Data(event.contentJson.utf8)) as? [String: Any],
                      let relation = content["m.relates_to"] as? [String: Any],
                      relation["event_id"] as? String == target else { continue }
                switch current.operationKind {
                case .response:
                    guard event.eventType == "org.matrix.msc3381.poll.response",
                          relation["rel_type"] as? String == "m.reference",
                          event.eventId != current.eventId, let serverTimestamp,
                          let timestamp = event.originServerTsMs, timestamp > UInt64(max(0, serverTimestamp)),
                          let response = content["org.matrix.msc3381.poll.response"] as? [String: Any],
                          response["answers"] is [String] else { continue }
                    superseded = true
                case .edit:
                    guard event.eventType == "org.matrix.msc3381.poll.start",
                          relation["rel_type"] as? String == "m.replace",
                          let replacement = content["m.new_content"] as? [String: Any],
                          replacement["org.matrix.msc3381.poll.start"] is [String: Any] else { continue }
                    if event.eventId == current.eventId {
                        current.confirmationSawOwnEvent = true
                    } else if current.confirmationSawOwnEvent {
                        current.confirmationEditEventID = event.eventId
                        if poll?.snapshot?.latestEditEventID == event.eventId { superseded = true }
                    }
                default: break
                }
            }
            if superseded {
                try current.delete(db)
                try Self.refreshPresentation(roomId: current.roomId, eventId: target, in: db)
                return true
            }
            current.serverTimestamp = serverTimestamp
            let advanced = next != nil && next != current.confirmationCursor
            // Retain the last request cursor at the tail. Do not start over
            // from the oldest vote when a server omits next_batch at the end.
            if advanced { current.confirmationCursor = next }
            else { current.confirmationSawOwnEvent = operation.confirmationSawOwnEvent }
            current.confirmationAt = now + (advanced ? Self.confirmationPageDelay : Self.confirmationRetryDelay)
            try current.update(db)
            try Self.refreshPresentation(roomId: current.roomId, eventId: target, in: db)
            return false
        }
        if changed { roomDidUpdate.send(operation.roomId) }
    }

    /// A wake scheduled by another operation must not bypass this deadline.
    func deferConfirmation(_ operation: PendingPollOperation, now: TimeInterval = Date().timeIntervalSince1970) async throws {
        try await perform { db in
            try db.execute(sql: "UPDATE pendingPollOperation SET confirmationAt = ? WHERE id = ? AND state = 'accepted'",
                           arguments: [now + Self.confirmationRetryDelay, operation.id])
        }
    }

    func invalidateStaleOperations(sessionId: String, operationID: String? = nil) async throws {
        let rooms = try await perform { db -> Set<String> in
            var query = PendingPollOperation
                .filter(Column("sessionId") != sessionId
                    && Column("state") != "accepted"
                    && (Column("failureReason") == nil || Column("failureReason") != PollFailureReason.staleSession.rawValue))
            if let operationID { query = query.filter(Column("id") == operationID) }
            let stale = try query.fetchAll(db)
            var rooms = Set<String>()
            for var operation in stale {
                operation.state = "failed"
                operation.failureReason = PollFailureReason.staleSession.rawValue
                operation.retryAt = nil
                operation.confirmationAt = nil
                try operation.update(db)
                try Self.updateEnvelope(operation, state: .failed, in: db)
                try Self.refreshPresentation(roomId: operation.roomId, eventId: operation.pollStartEventId, in: db)
                rooms.insert(operation.roomId)
            }
            return rooms
        }
        for room in rooms { roomDidUpdate.send(room) }
    }

    func begin(_ candidate: PendingPollOperation) async throws -> PendingPollOperation? {
        try await perform { db in
            guard var current = try PendingPollOperation.fetchOne(db, key: candidate.id),
                  ["queued", "sending", "retrying"].contains(current.state) else { return nil }
            current.state = "sending"
            current.attemptCount += 1
            try current.update(db)
            try Self.updateEnvelope(current, state: .sending, in: db)
            return current
        }
    }

    /// Recheck cached lifecycle state immediately before the first attempt.
    /// Retries must preserve an operation that the server may have accepted.
    func validateFirstSend(_ operation: PendingPollOperation, userId: String) async throws {
        guard operation.operationKind != .start else { return }
        try await perform { db in
            guard let eventId = operation.pollStartEventId,
                  let poll = try StoredRoomPoll.fetchOne(db, key: ["roomId": operation.roomId, "eventId": eventId]),
                  !poll.isRedacted, let snapshot = poll.snapshot, !snapshot.hasEnded else { throw PollError.unavailable }
            switch operation.operationKind {
            case .response:
                guard let answers = operation.answers, snapshot.validatesResponse(answers) else { throw PollError.unavailable }
            case .edit:
                guard poll.senderId == userId, snapshot.isEditable else { throw PollError.unavailable }
            case .end:
                guard poll.senderId == userId else { throw PollError.notAllowed }
            default: throw PollError.invalidContent
            }
        }
    }

    struct Cursor: Equatable, Sendable {
        let timestamp: TimeInterval
        let eventId: String
    }

    /// Indexed keyset pagination, independent of the chat window and UI toolkit.
    func polls(roomId: String, before cursor: Cursor? = nil, limit: Int = 50) async throws -> [RoomPollItem] {
        try await perform { db in
            var query = StoredRoomPoll.filter(Column("roomId") == roomId && Column("isRedacted") == false)
            if let cursor {
                query = query.filter(Column("timestamp") < cursor.timestamp
                    || (Column("timestamp") == cursor.timestamp && Column("eventId") < cursor.eventId))
            }
            let records = try query.order(Column("timestamp").desc, Column("eventId").desc)
                .limit(max(1, min(limit, 100))).fetchAll(db)
            let ids = records.map(\.eventId)
            let operations = try PendingPollOperation
                .filter(Column("roomId") == roomId && ids.contains(Column("pollStartEventId")))
                .order(Column("sequence").asc).fetchAll(db)
            var latest: [String: PendingPollOperation] = [:]
            for operation in operations {
                if let id = operation.pollStartEventId { latest[id] = operation }
            }
            return records.compactMap { record in
                guard let snapshot = record.snapshot else { return nil }
                return RoomPollItem(roomId: roomId, eventId: record.eventId, timestamp: record.timestamp,
                    senderId: record.senderId, senderName: record.senderName,
                    snapshot: Self.presentation(snapshot, operation: latest[record.eventId]))
            }
        }
    }

    func accept(_ operation: PendingPollOperation, eventId: String,
                now: TimeInterval = Date().timeIntervalSince1970) async throws {
        try await perform { db in
            guard var record = try PendingPollOperation.fetchOne(db, key: operation.id) else { return }
            if record.operationKind == .start, let envelopeId = record.envelopeId,
               try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM roomPoll WHERE roomId = ? AND eventId = ? AND isRedacted = 1)
                OR EXISTS(SELECT 1 FROM storedMessage WHERE roomId = ? AND eventId = ? AND contentType = 'redacted')
                """, arguments: [record.roomId, eventId, record.roomId, eventId]) == true {
                // The redaction won the race with this HTTP completion. The
                // envelope owns the operation and removes it by cascade.
                _ = try OutgoingEnvelopeRecord.deleteOne(db, key: envelopeId)
                return
            }
            record.eventId = eventId
            record.state = "accepted"
            record.retryAt = nil
            record.confirmationAt = now + Self.confirmationDelay
            try record.update(db)
            try Self.updateEnvelope(record, state: .sent, in: db)
            try Self.refreshPresentation(roomId: record.roomId, eventId: record.pollStartEventId, in: db)
        }
        roomDidUpdate.send(operation.roomId)
    }

    func fail(_ operation: PendingPollOperation, retryAfter: TimeInterval?) async throws {
        try await perform { db in
            guard var record = try PendingPollOperation.fetchOne(db, key: operation.id) else { return }
            record.state = retryAfter == nil ? "failed" : "retrying"
            record.retryAt = retryAfter.map { Date().timeIntervalSince1970 + $0 }
            try record.update(db)
            try Self.updateEnvelope(record, state: retryAfter == nil ? .failed : .retrying, in: db)
            try Self.refreshPresentation(roomId: record.roomId, eventId: record.pollStartEventId, in: db)
        }
        roomDidUpdate.send(operation.roomId)
    }

    @MainActor
    func retry(id: String, sessionId: String) async throws {
        let roomId: String = try await perform { db in
            guard var operation = try PendingPollOperation.fetchOne(db, key: id), operation.state == "failed" else { throw PollError.unavailable }
            guard operation.sessionId == sessionId else { throw PollError.staleSession }
            operation.state = "queued"
            operation.retryAt = nil
            try operation.update(db)
            try Self.updateEnvelope(operation, state: .queued, in: db)
            try Self.refreshPresentation(roomId: operation.roomId, eventId: operation.pollStartEventId, in: db)
            return operation.roomId
        }
        roomDidUpdate.send(roomId)
    }

    func dismissFailure(id: String) async throws {
        let roomId: String? = try await perform { db in
            guard let operation = try PendingPollOperation.fetchOne(db, key: id), operation.state == "failed", operation.envelopeId == nil else { return nil }
            try operation.delete(db)
            try Self.refreshPresentation(roomId: operation.roomId, eventId: operation.pollStartEventId, in: db)
            return operation.roomId
        }
        if let roomId { roomDidUpdate.send(roomId) }
    }

    private static func updateEnvelope(_ operation: PendingPollOperation, state: OutgoingTransportState, in db: Database) throws {
        guard let id = operation.envelopeId else { return }
        try db.execute(sql: "UPDATE pendingMediaGroup SET state = ? WHERE id = ?", arguments: [state.rawValue, id])
        try db.execute(sql: "UPDATE pendingMediaGroupItem SET transportState = ?, eventId = COALESCE(?, eventId) WHERE groupId = ?",
                       arguments: [state.rawValue, operation.eventId, id])
    }

    /// Work captures the current account's queue before dispatching. A logout
    /// cannot redirect an already submitted write into another account's DB.
    @MainActor
    private func perform<T>(_ work: @escaping (Database) throws -> T) async throws -> T {
        let database = database()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try database.write(work)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
