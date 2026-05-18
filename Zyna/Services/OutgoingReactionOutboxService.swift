//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRustSDK

private let logOutgoingReactionOutbox = ScopedLog(.timeline, prefix: "[DirectRawReactionTx]")

final class OutgoingReactionOutboxService {

    static let shared = OutgoingReactionOutboxService()

    let roomDidUpdateSubject = PassthroughSubject<String, Never>()

    private let matrixService = MatrixClientService.shared
    private let pendingReactions = PendingReactionService.shared

    private let retryBackoff = OutgoingRetryBackoff<String>()
    private let inFlight = OutgoingInFlightTracker<String>()
    private lazy var scanCoordinator = OutgoingOutboxScanCoordinator(
        isEnabled: { DirectRawTextSender.isEnabled },
        log: { logOutgoingReactionOutbox($0) },
        scan: { [weak self] reason, _ in
            await self?.runScan(reason: reason)
        }
    )

    private enum AttemptDecision {
        case send
        case wait(TimeInterval)
    }

    private init() {}

    func start() {
        Task { @MainActor in
            self.scanCoordinator.start()
        }
    }

    func kick(reason: String) {
        Task { @MainActor in
            self.scanCoordinator.kick(reason: reason)
        }
    }

    @MainActor
    private func runScan(reason: String) async {
        guard scanCoordinator.isSyncing,
              DirectRawTextSender.isEnabled else { return }

        let candidates = pendingReactions.outboxCandidates()
        guard !candidates.isEmpty else {
            logOutgoingReactionOutbox("outbox scan reason=\(reason) count=0")
            return
        }

        logOutgoingReactionOutbox(
            "outbox scan reason=\(reason) count=\(candidates.count) reactions=\(candidates.map(\.id).joined(separator: ","))"
        )

        for candidate in candidates {
            guard !Task.isCancelled,
                  scanCoordinator.isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func sendIfEligible(
        _ candidate: PendingReactionRecord,
        reason: String
    ) async {
        guard inFlight.begin(candidate.id) else { return }
        defer {
            inFlight.end(candidate.id)
        }

        switch attemptDecision(for: candidate.id) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingReactionOutbox(
                "outbox wait reason=\(reason) id=\(candidate.id) "
                    + "delaySec=\(String(format: "%.1f", delay))"
            )
            scanCoordinator.scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        }

        guard let latest = pendingReactions.record(id: candidate.id) else {
            clearRetryMetadata(for: candidate.id)
            return
        }

        guard let room = room(for: latest.roomId) else {
            logOutgoingReactionOutbox(
                "outbox missing room reason=\(reason) id=\(latest.id) room=\(latest.roomId)"
            )
            scanCoordinator.scheduleWake(after: retryBackoff.initialDelay, reason: "missing-room")
            return
        }

        pendingReactions.markAttemptStarted(id: latest.id)

        switch latest.decodedState {
        case .addQueued:
            await sendAdd(latest, room: room, reason: reason)
        case .removeQueued:
            await sendRemove(latest, room: room, reason: reason)
        case .addAccepted, .removed, .failed:
            clearRetryMetadata(for: latest.id)
        }
    }

    @MainActor
    private func sendAdd(
        _ record: PendingReactionRecord,
        room: Room,
        reason: String
    ) async {
        guard let transactionId = record.transactionId else {
            pendingReactions.markAddFailed(id: record.id)
            clearRetryMetadata(for: record.id)
            return
        }

        logOutgoingReactionOutbox(
            "outbox add start reason=\(reason) id=\(record.id) target=\(record.targetEventId) tx=\(transactionId) key=\(record.reactionKey)"
        )

        let receipt = await DirectRawTextSender.sendReaction(
            room: room,
            targetEventId: record.targetEventId,
            key: record.reactionKey,
            transactionId: transactionId
        )

        guard !Task.isCancelled,
              scanCoordinator.isSyncing else { return }

        logOutgoingReactionOutbox(
            "outbox add receipt id=\(record.id) tx=\(transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )

        if !receipt.acceptedByTransport {
            handleRejectedAdd(record, receipt: receipt)
            return
        }

        guard let reactionEventId = receipt.eventId else {
            scheduleRetry(for: record.id)
            return
        }

        clearRetryMetadata(for: record.id)
        _ = pendingReactions.applyAcceptedAdd(
            id: record.id,
            transactionId: transactionId,
            reactionEventId: reactionEventId
        )
    }

    @MainActor
    private func sendRemove(
        _ record: PendingReactionRecord,
        room: Room,
        reason: String
    ) async {
        guard let reactionEventId = record.reactionEventId,
              let transactionId = record.redactionTransactionId else {
            pendingReactions.markRemovalFailed(id: record.id)
            clearRetryMetadata(for: record.id)
            return
        }

        logOutgoingReactionOutbox(
            "outbox remove start reason=\(reason) id=\(record.id) reaction=\(reactionEventId) tx=\(transactionId) key=\(record.reactionKey)"
        )

        let receipt = await DirectRawTextSender.sendRedaction(
            room: room,
            eventId: reactionEventId,
            transactionId: transactionId
        )

        guard !Task.isCancelled,
              scanCoordinator.isSyncing else { return }

        logOutgoingReactionOutbox(
            "outbox remove receipt id=\(record.id) tx=\(transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )

        if !receipt.acceptedByTransport {
            handleRejectedRemoval(record, receipt: receipt)
            return
        }

        clearRetryMetadata(for: record.id)
        _ = pendingReactions.applyAcceptedRemoval(
            id: record.id,
            redactionTransactionId: transactionId,
            redactionEventId: receipt.eventId
        )
        publishRoomDidUpdate(record.roomId)
    }

    @MainActor
    private func handleRejectedAdd(
        _ record: PendingReactionRecord,
        receipt: OutgoingDispatchReceipt
    ) {
        if receipt.retryableTransportFailure {
            scheduleRetry(for: record.id)
            return
        }

        clearRetryMetadata(for: record.id)
        pendingReactions.markAddFailed(id: record.id)
    }

    @MainActor
    private func handleRejectedRemoval(
        _ record: PendingReactionRecord,
        receipt: OutgoingDispatchReceipt
    ) {
        if receipt.retryableTransportFailure {
            scheduleRetry(for: record.id)
            return
        }

        clearRetryMetadata(for: record.id)
        pendingReactions.markRemovalFailed(id: record.id)
        publishRoomDidUpdate(record.roomId)
    }

    @MainActor
    private func attemptDecision(for reactionId: String) -> AttemptDecision {
        if let delay = retryBackoff.waitDelay(for: reactionId) {
            return .wait(delay)
        }
        return .send
    }

    @MainActor
    private func scheduleRetry(for reactionId: String) {
        let delay = retryBackoff.scheduleRetry(for: reactionId)
        scanCoordinator.scheduleWake(after: delay, reason: "retryable-failure")
    }

    @MainActor
    private func clearRetryMetadata(for reactionId: String) {
        retryBackoff.clear(reactionId)
    }

    private func room(for roomId: String) -> Room? {
        try? matrixService.client?.getRoom(roomId: roomId)
    }

    @MainActor
    private func publishRoomDidUpdate(_ roomId: String) {
        roomDidUpdateSubject.send(roomId)
    }
}
