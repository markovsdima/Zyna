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

    init(
        messageId: String,
        roomId: String,
        itemIdentifier: ChatItemIdentifier?,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        lastAttemptAt: TimeInterval? = nil,
        attemptCount: Int = 0
    ) {
        self.messageId = messageId
        self.roomId = roomId
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.attemptCount = attemptCount
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

    static let shared = PendingRedactionService(dbQueue: DatabaseService.shared.dbQueue)

    private struct StoredMessageIdentifierState: FetchableRecord, Decodable {
        let eventId: String?
        let transactionId: String?
        let contentType: String
    }

    private let dbQueue: DatabaseQueue
    private let activeAttemptsQueue = DispatchQueue(
        label: "com.zyna.pendingRedaction.activeAttempts"
    )
    private var activeAttemptMessageIds = Set<String>()

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

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
        let pendingIds = pendingMessageIds(roomId: roomId)
        guard !pendingIds.isEmpty else { return [] }

        let resolvedIds: [String] = (try? dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM storedMessage
                    WHERE roomId = ?
                      AND id IN (\(pendingIds.map { _ in "?" }.joined(separator: ",")))
                      AND contentType = 'redacted'
                    """,
                arguments: StatementArguments([roomId] + pendingIds)
            )
        }) ?? []

        guard !resolvedIds.isEmpty else { return [] }

        do {
            try dbQueue.write { db in
                for messageId in resolvedIds {
                    _ = try PendingRedactionRecord.deleteOne(db, key: messageId)
                }
            }
        } catch {
            logPendingRedaction("reconcile failed: \(error)")
        }

        return Set(resolvedIds)
    }

    func attempt(_ intent: PendingRedactionIntent, timelineService: TimelineService) async throws {
        try await attempt(
            messageId: intent.messageId,
            roomId: intent.roomId,
            fallbackItemIdentifier: intent.itemIdentifier,
            timelineService: timelineService
        )
    }

    func retryPendingRedactions(roomId: String, timelineService: TimelineService) async -> [TerminalFailure] {
        guard timelineService.hasLiveTimeline else { return [] }
        _ = reconcileResolvedPendingMessageIds(roomId: roomId)

        let records: [PendingRedactionRecord] = (try? await dbQueue.read { db in
            try PendingRedactionRecord
                .filter(Column("roomId") == roomId)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }) ?? []

        guard !records.isEmpty else { return [] }

        let terminalFailures = LockedTerminalFailures()

        await withTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.attempt(
                            messageId: record.messageId,
                            roomId: record.roomId,
                            fallbackItemIdentifier: record.itemIdentifier,
                            timelineService: timelineService
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
        fallbackItemIdentifier: ChatItemIdentifier?,
        timelineService: TimelineService
    ) async throws {
        guard timelineService.hasLiveTimeline else { return }
        guard beginAttempt(for: messageId) else { return }
        defer { endAttempt(for: messageId) }

        let itemIdentifier = try await dbQueue.write { [self] db -> ChatItemIdentifier? in
            var record = try PendingRedactionRecord.fetchOne(db, key: messageId)
                ?? PendingRedactionRecord(
                    messageId: messageId,
                    roomId: roomId,
                    itemIdentifier: fallbackItemIdentifier
                )

            record.roomId = roomId
            record.apply(fallbackItemIdentifier)
            try self.refreshItemIdentifier(for: &record, in: db)

            guard let itemIdentifier = record.itemIdentifier else {
                try record.save(db)
                return nil
            }

            record.lastAttemptAt = Date().timeIntervalSince1970
            record.attemptCount += 1
            try record.save(db)
            return itemIdentifier
        }

        guard let itemIdentifier else {
            logPendingRedaction("attempt skipped messageId=\(messageId) no identifier")
            return
        }

        do {
            try await timelineService.redactEvent(itemIdentifier)
        } catch {
            let disposition = Self.classifyFailureDisposition(for: error)
            if disposition == .terminal {
                clearPersistentIntent(messageId: messageId)
                throw PendingRedactionAttemptError.terminal(error)
            }
            throw PendingRedactionAttemptError.retryable(error)
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

    private static func classifyFailureDisposition(for error: Error) -> PendingRedactionFailureDisposition {
        guard let clientError = error as? ClientError else {
            return .retryable
        }

        switch clientError {
        case .MatrixApi(let kind, _, _, _):
            switch kind {
            case .forbidden,
                    .guestAccessForbidden,
                    .unauthorized,
                    .unknownToken,
                    .missingToken,
                    .notFound,
                    .badJson,
                    .badState,
                    .invalidParam,
                    .missingParam,
                    .unrecognized,
                    .tooLarge,
                    .userDeactivated,
                    .userLocked,
                    .userSuspended:
                return .terminal
            default:
                return .retryable
            }
        case .Generic(let msg, let details):
            let normalized = [msg, details]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            if normalized.contains("forbidden")
                || normalized.contains("power level")
                || normalized.contains("unauthorized")
                || normalized.contains("not authorized") {
                return .terminal
            }
            return .retryable
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
