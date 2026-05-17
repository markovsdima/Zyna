//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

private let logPendingRedaction = ScopedLog(.timeline, prefix: "[PendingRedaction]")

enum PendingRedactionFailureDisposition {
    case retryable
    case terminal
}

enum PendingRedactionAttemptError: Error {
    case retryable(Error)
    case terminal(Error)

    var disposition: PendingRedactionFailureDisposition {
        switch self {
        case .retryable:
            return .retryable
        case .terminal:
            return .terminal
        }
    }

    var underlyingError: Error {
        switch self {
        case .retryable(let error), .terminal(let error):
            return error
        }
    }
}

private struct PendingRedactionTransportError: Error, CustomStringConvertible {
    let description: String
}

struct PendingRedactionIntent {
    let messageId: String
    let roomId: String
    let itemIdentifier: ChatItemIdentifier
}

struct PendingRedactionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingRedaction"

    var messageId: String
    var roomId: String
    var identifierKind: String?
    var identifierValue: String?
    var createdAt: TimeInterval
    var lastAttemptAt: TimeInterval?
    var attemptCount: Int
    var redactionTransactionId: String?
    var redactionEventId: String?

    init(
        messageId: String,
        roomId: String,
        itemIdentifier: ChatItemIdentifier?,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        lastAttemptAt: TimeInterval? = nil,
        attemptCount: Int = 0,
        redactionTransactionId: String? = nil,
        redactionEventId: String? = nil
    ) {
        self.messageId = messageId
        self.roomId = roomId
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.attemptCount = attemptCount
        self.redactionTransactionId = redactionTransactionId
        self.redactionEventId = redactionEventId
        apply(itemIdentifier)
    }

    var itemIdentifier: ChatItemIdentifier? {
        guard let identifierValue else { return nil }
        switch identifierKind {
        case "eventId":
            return .eventId(identifierValue)
        case "transactionId":
            return .transactionId(identifierValue)
        default:
            return nil
        }
    }

    mutating func apply(_ itemIdentifier: ChatItemIdentifier?) {
        switch itemIdentifier {
        case .eventId(let id):
            identifierKind = "eventId"
            identifierValue = id
        case .transactionId(let id):
            if self.itemIdentifier == nil {
                identifierKind = "transactionId"
                identifierValue = id
            }
        case nil:
            break
        }
    }
}

final class PendingRedactionService {

    struct TerminalFailure {
        let messageId: String
        let error: Error
    }

    struct ResolvedPendingRedactions {
        let messageIds: Set<String>
        let identityKeys: Set<String>
    }

    static let shared = PendingRedactionService()

    private struct StoredMessageIdentifierState: FetchableRecord, Decodable {
        let eventId: String?
        let transactionId: String?
        let contentType: String
    }

    private struct PendingIdentityState: FetchableRecord, Decodable {
        let messageId: String
        let identifierKind: String?
        let identifierValue: String?
        let eventId: String?
        let transactionId: String?
    }

    private enum RedactionAttemptTarget {
        case directRaw(eventId: String, transactionId: String)
    }

    private var dbQueue: DatabaseQueue { DatabaseService.shared.dbQueue }
    private let activeAttemptsQueue = DispatchQueue(
        label: "com.zyna.pendingRedaction.activeAttempts"
    )
    private var activeAttemptMessageIds = Set<String>()

    private init() {}

    func pendingMessageIds(roomId: String) -> Set<String> {
        (try? dbQueue.read { db in
            try Set(String.fetchAll(
                db,
                sql: """
                    SELECT messageId
                    FROM pendingRedaction
                    WHERE roomId = ?
                    """,
                arguments: [roomId]
            ))
        }) ?? []
    }

    func pendingMessageIdentityKeys(roomId: String) -> Set<String> {
        (try? dbQueue.read { db in
            let rows = try PendingIdentityState.fetchAll(
                db,
                sql: """
                    SELECT p.messageId,
                           p.identifierKind,
                           p.identifierValue,
                           s.eventId,
                           s.transactionId
                    FROM pendingRedaction AS p
                    LEFT JOIN storedMessage AS s
                      ON s.id = p.messageId
                    WHERE p.roomId = ?
                    """,
                arguments: [roomId]
            )
            var keys = Set<String>()
            for row in rows {
                switch row.identifierKind {
                case "eventId":
                    if let value = row.identifierValue, !value.isEmpty {
                        keys.insert(MessageIdentity.event(value).key)
                        continue
                    }
                case "transactionId":
                    if let value = row.identifierValue, !value.isEmpty {
                        keys.insert(MessageIdentity.transaction(value).key)
                        continue
                    }
                default:
                    break
                }
                keys.insert(
                    MessageIdentity.from(
                        eventId: row.eventId,
                        transactionId: row.transactionId,
                        localId: row.messageId
                    ).key
                )
            }
            return keys
        }) ?? []
    }

    func pendingRecords(roomId: String? = nil) -> [PendingRedactionRecord] {
        (try? dbQueue.read { db in
            var request = PendingRedactionRecord.order(Column("createdAt").asc)
            if let roomId {
                request = request.filter(Column("roomId") == roomId)
            }
            return try request.fetchAll(db)
        }) ?? []
    }

    func register(_ intents: [PendingRedactionIntent]) {
        guard !intents.isEmpty else { return }

        do {
            try dbQueue.write { db in
                for intent in intents {
                    var record = try PendingRedactionRecord.fetchOne(
                        db,
                        key: intent.messageId
                    ) ?? PendingRedactionRecord(
                        messageId: intent.messageId,
                        roomId: intent.roomId,
                        itemIdentifier: intent.itemIdentifier
                    )
                    record.roomId = intent.roomId
                    record.apply(intent.itemIdentifier)
                    try record.save(db)
                }
            }
        } catch {
            logPendingRedaction("register failed: \(error)")
        }
    }

    func reconcileResolvedPendingMessageIds(roomId: String) -> Set<String> {
        reconcileResolvedPendingRedactions(roomId: roomId).messageIds
    }

    func reconcileResolvedPendingRedactions(roomId: String) -> ResolvedPendingRedactions {
        let records: [PendingRedactionRecord] = (try? dbQueue.read { db in
            try PendingRedactionRecord
                .filter(Column("roomId") == roomId)
                .fetchAll(db)
        }) ?? []
        guard !records.isEmpty else {
            return ResolvedPendingRedactions(messageIds: [], identityKeys: [])
        }

        let resolved: [(String, Set<String>)] = (try? dbQueue.read { db in
            var ids: [String] = []
            var keys: [Set<String>] = []
            for record in records {
                if try Self.isResolvedRedaction(record, in: db) {
                    ids.append(record.messageId)
                    keys.append(try Self.identityKeys(for: record, in: db))
                }
            }
            return zip(ids, keys).map { ($0.0, $0.1) }
        }) ?? []

        guard !resolved.isEmpty else {
            return ResolvedPendingRedactions(messageIds: [], identityKeys: [])
        }

        let resolvedIds = resolved.map(\.0)
        let resolvedKeys = resolved.flatMap(\.1)

        do {
            try dbQueue.write { db in
                for messageId in resolvedIds {
                    _ = try PendingRedactionRecord.deleteOne(db, key: messageId)
                }
            }
        } catch {
            logPendingRedaction("reconcile failed: \(error)")
        }

        return ResolvedPendingRedactions(
            messageIds: Set(resolvedIds),
            identityKeys: Set(resolvedKeys)
        )
    }

    func attempt(_ intent: PendingRedactionIntent) async throws {
        _ = try await attempt(
            messageId: intent.messageId,
            roomId: intent.roomId,
            fallbackItemIdentifier: intent.itemIdentifier
        )
    }

    func attemptDirectRawIfPossible(_ record: PendingRedactionRecord) async throws -> Bool {
        try await attempt(
            messageId: record.messageId,
            roomId: record.roomId,
            fallbackItemIdentifier: record.itemIdentifier
        )
    }

    func retryPendingRedactions(roomId: String) async -> [TerminalFailure] {
        _ = reconcileResolvedPendingMessageIds(roomId: roomId)

        let records = pendingRecords(roomId: roomId)

        guard !records.isEmpty else { return [] }

        let terminalFailures = LockedTerminalFailures()

        await withTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.attempt(
                            messageId: record.messageId,
                            roomId: record.roomId,
                            fallbackItemIdentifier: record.itemIdentifier
                        )
                    } catch {
                        if let attemptError = error as? PendingRedactionAttemptError,
                           attemptError.disposition == .terminal {
                            terminalFailures.append(
                                TerminalFailure(
                                    messageId: record.messageId,
                                    error: attemptError.underlyingError
                                )
                            )
                        }
                        logPendingRedaction(
                            "retry failed messageId=\(record.messageId) error=\(error)"
                        )
                    }
                }
            }
        }

        return terminalFailures.snapshot()
    }

    private func attempt(
        messageId: String,
        roomId: String,
        fallbackItemIdentifier: ChatItemIdentifier?
    ) async throws -> Bool {
        guard beginAttempt(for: messageId) else { return false }
        defer { endAttempt(for: messageId) }

        let target = try await dbQueue.write { [self] db -> RedactionAttemptTarget? in
            var record = try PendingRedactionRecord.fetchOne(db, key: messageId)
                ?? PendingRedactionRecord(
                    messageId: messageId,
                    roomId: roomId,
                    itemIdentifier: fallbackItemIdentifier
                )

            record.roomId = roomId
            record.apply(fallbackItemIdentifier)
            try self.refreshItemIdentifier(for: &record, in: db)

            if record.redactionEventId?.isEmpty == false {
                try record.save(db)
                return nil
            }

            guard let itemIdentifier = record.itemIdentifier else {
                try record.save(db)
                return nil
            }

            record.lastAttemptAt = Date().timeIntervalSince1970
            record.attemptCount += 1

            if case .eventId(let eventId) = itemIdentifier,
               let transactionId = DirectRawTextSender.prepareRedactionTransactionId(
                   existingTransactionId: record.redactionTransactionId
               ) {
                record.redactionTransactionId = transactionId
                try record.save(db)
                return .directRaw(eventId: eventId, transactionId: transactionId)
            }

            try record.save(db)
            return nil
        }

        guard let target else {
            logPendingRedaction("attempt skipped messageId=\(messageId) no identifier")
            return false
        }

        switch target {
        case .directRaw(let eventId, let transactionId):
            try await sendDirectRawRedaction(
                roomId: roomId,
                messageId: messageId,
                eventId: eventId,
                transactionId: transactionId
            )
            return true
        }
    }

    private func sendDirectRawRedaction(
        roomId: String,
        messageId: String,
        eventId: String,
        transactionId: String
    ) async throws {
        guard let room = try? MatrixClientService.shared.client?.getRoom(roomId: roomId) else {
            throw PendingRedactionAttemptError.retryable(
                PendingRedactionTransportError(
                    description: "Room unavailable for redaction room=\(roomId)"
                )
            )
        }

        let receipt = await DirectRawTextSender.sendRedaction(
            room: room,
            eventId: eventId,
            transactionId: transactionId
        )

        guard receipt.acceptedByTransport else {
            let error = PendingRedactionTransportError(
                description: "Direct raw redaction rejected event=\(eventId) tx=\(transactionId)"
            )
            if receipt.retryableTransportFailure {
                throw PendingRedactionAttemptError.retryable(error)
            }
            clearPersistentIntent(messageId: messageId)
            throw PendingRedactionAttemptError.terminal(error)
        }

        if let redactionEventId = receipt.eventId {
            bindAcceptedDirectRawRedaction(
                messageId: messageId,
                transactionId: transactionId,
                redactionEventId: redactionEventId
            )
        }
    }

    private func bindAcceptedDirectRawRedaction(
        messageId: String,
        transactionId: String,
        redactionEventId: String
    ) {
        do {
            try dbQueue.write { db in
                guard var record = try PendingRedactionRecord.fetchOne(
                    db,
                    key: messageId
                ), record.redactionTransactionId == transactionId else {
                    return
                }
                record.redactionEventId = redactionEventId
                try record.save(db)
            }
            logPendingRedaction(
                "direct accepted messageId=\(messageId) redaction=\(redactionEventId) tx=\(transactionId)"
            )
        } catch {
            logPendingRedaction(
                "direct bind failed messageId=\(messageId) redaction=\(redactionEventId) error=\(error)"
            )
        }
    }

    private func refreshItemIdentifier(
        for record: inout PendingRedactionRecord,
        in db: Database
    ) throws {
        let storedState = try StoredMessageIdentifierState.fetchOne(
            db,
            sql: """
                SELECT eventId, transactionId, contentType
                FROM storedMessage
                WHERE id = ?
                LIMIT 1
                """,
            arguments: [record.messageId]
        )

        guard let storedState, storedState.contentType != "redacted" else {
            return
        }

        if let eventId = storedState.eventId {
            record.apply(.eventId(eventId))
            return
        }

        if let transactionId = storedState.transactionId {
            record.apply(.transactionId(transactionId))
        }
    }

    private static func isResolvedRedaction(
        _ record: PendingRedactionRecord,
        in db: Database
    ) throws -> Bool {
        if let itemIdentifier = record.itemIdentifier {
            switch itemIdentifier {
            case .eventId(let eventId):
                if try redactedStoredMessageExists(
                    roomId: record.roomId,
                    column: "eventId",
                    value: eventId,
                    in: db
                ) {
                    return true
                }
            case .transactionId(let transactionId):
                if try redactedStoredMessageExists(
                    roomId: record.roomId,
                    column: "transactionId",
                    value: transactionId,
                    in: db
                ) {
                    return true
                }
            }
        }

        return try StoredMessage
            .filter(
                Column("roomId") == record.roomId
                    && Column("id") == record.messageId
                    && Column("contentType") == "redacted"
            )
            .fetchCount(db) > 0
    }

    private static func identityKeys(
        for record: PendingRedactionRecord,
        in db: Database
    ) throws -> Set<String> {
        var keys = Set<String>()
        if let itemIdentifier = record.itemIdentifier {
            keys.insert(MessageIdentity.from(
                messageId: record.messageId,
                itemIdentifier: itemIdentifier
            ).key)
        }

        let storedState = try StoredMessageIdentifierState.fetchOne(
            db,
            sql: """
                SELECT eventId, transactionId, contentType
                FROM storedMessage
                WHERE id = ?
                LIMIT 1
            """,
            arguments: [record.messageId]
        )
        keys.formUnion(
            MessageIdentity.keys(
                eventId: storedState?.eventId,
                transactionId: storedState?.transactionId,
                localId: record.messageId
            )
        )
        return keys
    }

    private static func redactedStoredMessageExists(
        roomId: String,
        column: String,
        value: String,
        in db: Database
    ) throws -> Bool {
        try StoredMessage
            .filter(
                Column("roomId") == roomId
                    && Column(column) == value
                    && Column("contentType") == "redacted"
            )
            .fetchCount(db) > 0
    }

    private func beginAttempt(for messageId: String) -> Bool {
        activeAttemptsQueue.sync {
            if activeAttemptMessageIds.contains(messageId) {
                return false
            }
            activeAttemptMessageIds.insert(messageId)
            return true
        }
    }

    private func endAttempt(for messageId: String) {
        _ = activeAttemptsQueue.sync {
            activeAttemptMessageIds.remove(messageId)
        }
    }

    private func clearPersistentIntent(messageId: String) {
        do {
            try dbQueue.write { db in
                _ = try PendingRedactionRecord.deleteOne(db, key: messageId)
            }
        } catch {
            logPendingRedaction("clear failed messageId=\(messageId) error=\(error)")
        }
    }

}

private final class LockedTerminalFailures {
    private let queue = DispatchQueue(label: "com.zyna.pendingRedaction.terminalFailures")
    private var failures: [PendingRedactionService.TerminalFailure] = []

    func append(_ failure: PendingRedactionService.TerminalFailure) {
        queue.sync {
            failures.append(failure)
        }
    }

    func snapshot() -> [PendingRedactionService.TerminalFailure] {
        queue.sync { failures }
    }
}
