//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// Uses the same app-lifetime scan coordinator as the other outgoing kinds.
/// Retry deadlines and operation ordering survive app termination in GRDB.
final class OutgoingPollOutboxService {
    static let shared = OutgoingPollOutboxService()
    private let store = PollStore.shared
    private let log = ScopedLog(.timeline, prefix: "[PollOutbox]")
    private lazy var coordinator = OutgoingOutboxScanCoordinator(
        isEnabled: { true }, log: { [weak self] in self?.log($0) },
        scan: { [weak self] _, _ in await self?.scan() }
    )

    private init() {}

    func start() { Task { @MainActor in coordinator.start() } }
    func kick() { Task { @MainActor in coordinator.kick(reason: "poll") } }

    @MainActor
    private func scan() async {
        guard coordinator.isSyncing else { return }
        let matrix = MatrixClientService.shared
        guard let sessionId = matrix.currentLocalSessionId else { return }
        do {
            try await store.invalidateStaleOperations(sessionId: sessionId)
            let candidates = try await store.candidates()
            var blockedTargets = Set<String>()
            for candidate in candidates {
                guard !Task.isCancelled, coordinator.isSyncing, matrix.currentLocalSessionId == sessionId else { return }
                guard !blockedTargets.contains(candidate.targetKey) else { continue }
                blockedTargets.insert(candidate.targetKey)
                guard candidate.sessionId == sessionId else {
                    try await store.invalidateStaleOperations(sessionId: sessionId, operationID: candidate.id)
                    blockedTargets.remove(candidate.targetKey)
                    continue
                }
                if let retryAt = candidate.retryAt, retryAt > Date().timeIntervalSince1970 {
                    coordinator.scheduleWake(after: retryAt - Date().timeIntervalSince1970, reason: "poll-retry")
                    continue
                }
                guard let client = matrix.client,
                      let room = try? client.getRoom(roomId: candidate.roomId) else {
                    coordinator.scheduleWake(after: 2, reason: "poll-room")
                    continue
                }
                var operation = candidate
                let eventId: String
                do {
                    // These are admission checks, not retry checks. A server
                    // may already have accepted a previous transport attempt.
                    if operation.attemptCount == 0 {
                        try await checkPermission(operation, room: room)
                        guard !Task.isCancelled, coordinator.isSyncing, matrix.currentLocalSessionId == sessionId else { return }
                        try await store.validateFirstSend(operation, userId: client.userId())
                    }
                    guard !Task.isCancelled, coordinator.isSyncing, matrix.currentLocalSessionId == sessionId else { return }
                    guard let started = try await store.begin(candidate) else { continue }
                    guard !Task.isCancelled, coordinator.isSyncing, matrix.currentLocalSessionId == sessionId else { return }
                    operation = started
                    eventId = try await send(operation, room: room, sessionId: sessionId)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, coordinator.isSyncing, matrix.currentLocalSessionId == sessionId else { return }
                    let retryable = DirectRawTextSender.isRetryableTransportError(error)
                    let delay: TimeInterval? = retryable ? min(60.0, pow(2, Double(min(operation.attemptCount, 6)))) : nil
                    try await store.fail(operation, retryAfter: delay)
                    if let delay { coordinator.scheduleWake(after: delay, reason: "poll-transport") }
                    else { blockedTargets.remove(operation.targetKey) }
                    // Never log poll text, options or the SDK error's payload.
                    log("send failed operation=\(operation.id) retryable=\(retryable)")
                    continue
                }
                guard !Task.isCancelled, coordinator.isSyncing, matrix.currentLocalSessionId == sessionId else { return }
                try await store.accept(operation, eventId: eventId)
                blockedTargets.remove(operation.targetKey)
            }
            // Sync gets the first chance to settle an operation. Each operation
            // has its own persisted deadline; unrelated kicks cannot bypass it.
            let awaiting = try await store.awaitingConfirmation()
            var confirmationBudget = 4
            for operation in awaiting {
                guard !Task.isCancelled, coordinator.isSyncing, matrix.currentLocalSessionId == sessionId else { return }
                let now = Date().timeIntervalSince1970
                if let due = operation.confirmationAt, due > now {
                    coordinator.scheduleWake(after: due - now, reason: "poll-confirmation")
                    continue
                }
                guard confirmationBudget > 0 else {
                    coordinator.scheduleWake(after: 2, reason: "poll-confirmation")
                    break
                }
                // Reading confirmation is safe after a relogin to the same
                // account. The surrounding guards still pin the active session.
                guard let eventId = operation.eventId,
                      let target = operation.pollStartEventId,
                      let client = matrix.client, let room = try? client.getRoom(roomId: operation.roomId) else {
                    coordinator.scheduleWake(after: 30, reason: "poll-confirmation-room")
                    continue
                }
                confirmationBudget -= 1
                do {
                    let timestamp: Int64?
                    if let stored = operation.serverTimestamp { timestamp = stored }
                    else if operation.operationKind == .response {
                        timestamp = Int64(try await room.loadOrFetchEvent(eventId: eventId).timestamp())
                    } else { timestamp = nil }
                    let page = try await room.getEventRelations(eventId: target, options: RawRoomRelationsOptions(
                        relationType: operation.operationKind == .edit ? "m.replace" : "m.reference",
                        eventType: nil, from: operation.confirmationCursor,
                        limit: 100, direction: .forward, recurse: false))
                    guard !Task.isCancelled, matrix.currentLocalSessionId == sessionId else { return }
                    try await store.reconcileConfirmationPage(operation, serverTimestamp: timestamp,
                        events: page.chunk, next: page.nextBatchToken, userId: client.userId())
                    coordinator.scheduleWake(after: 2, reason: "poll-confirmation")
                } catch {
                    guard !Task.isCancelled, matrix.currentLocalSessionId == sessionId else { return }
                    try await store.deferConfirmation(operation)
                    coordinator.scheduleWake(after: 30, reason: "poll-confirmation")
                }
            }
        } catch {
            log("poll persistence failed; retaining durable intent for retry")
            coordinator.scheduleWake(after: 2, reason: "poll-persistence")
        }
    }

    private func checkPermission(_ operation: PendingPollOperation, room: Room) async throws {
        guard room.encryptionState() == .notEncrypted || SessionVerificationService.shared.canSendEncryptedMessages else {
            throw PollError.notAllowed
        }
        let powers = try await room.getPowerLevels()
        let type: MessageLikeEventType
        switch operation.operationKind {
        case .start, .edit: type = .unstablePollStart
        case .response: type = .unstablePollResponse
        case .end: type = .unstablePollEnd
        case nil: throw PollError.invalidContent
        }
        guard powers.canOwnUserSendMessage(message: type) else { throw PollError.notAllowed }
    }

    private func send(_ operation: PendingPollOperation, room: Room, sessionId: String) async throws -> String {
        // Blocking applies to queued retries too, even after admission.
        try await DirectChatBlockingPolicy.requireUnblocked(room: room)
        // Decode persisted payloads off-main, then recheck the session on the
        // main actor immediately before invoking the SDK. UniFFI does not
        // propagate Swift task cancellation to these requests.
        let request: @MainActor () async throws -> String
        switch operation.operationKind {
        case .start:
            guard let definition = operation.definition else { throw PollError.invalidContent }
            let data = try definition.sdkData()
            request = {
                try await room.sendPollStartWithTransactionIdReturningEventId(
                    pollData: data, transactionId: operation.transactionId)
            }
        case .response:
            guard let target = operation.pollStartEventId, let answers = operation.answers else { throw PollError.invalidContent }
            request = {
                try await room.sendPollResponseWithTransactionIdReturningEventId(
                    pollStartEventId: target, answers: answers, transactionId: operation.transactionId)
            }
        case .edit:
            guard let target = operation.pollStartEventId, let definition = operation.definition else { throw PollError.invalidContent }
            let data = try definition.sdkData()
            request = {
                try await room.editPollWithTransactionIdReturningEventId(
                    pollStartEventId: target, pollData: data, transactionId: operation.transactionId)
            }
        case .end:
            guard let target = operation.pollStartEventId else { throw PollError.invalidContent }
            request = {
                try await room.endPollWithTransactionIdReturningEventId(
                    pollStartEventId: target, text: operation.text ?? "", transactionId: operation.transactionId)
            }
        case nil: throw PollError.invalidContent
        }
        return try await Self.sendIfCurrent(sessionId: sessionId,
            currentSessionId: { MatrixClientService.shared.currentLocalSessionId },
            isSyncing: { self.coordinator.isSyncing }, request: request)
    }

    @MainActor
    static func sendIfCurrent(sessionId: String, currentSessionId: () -> String?,
                              isSyncing: () -> Bool,
                              request: @MainActor () async throws -> String) async throws -> String {
        guard !Task.isCancelled, isSyncing(), currentSessionId() == sessionId else { throw CancellationError() }
        return try await request()
    }
}
