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

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var scanTask: Task<Void, Never>?
    private var pendingScanReason: String?
    private var retryWakeTask: Task<Void, Never>?
    private var retryWakeAt: Date?
    private var inFlightReactionIds = Set<String>()
    private var nextRetryAtByReactionId: [String: Date] = [:]
    private var retryDelaySecondsByReactionId: [String: UInt64] = [:]

    private let initialRetryDelaySeconds: UInt64 = 5
    private let maxRetryDelaySeconds: UInt64 = 60

    private enum AttemptDecision {
        case send
        case wait(TimeInterval)
    }

    private init() {}

    func start() {
        Task { @MainActor in
            self.startOnMain()
        }
    }

    func kick(reason: String) {
        Task { @MainActor in
            self.kickOnMain(reason: reason)
        }
    }

    @MainActor
    private func startOnMain() {
        guard !started else { return }
        started = true

        matrixService.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in
                    self?.handleClientState(state)
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func kickOnMain(reason: String) {
        guard DirectRawTextSender.isEnabled else { return }
        guard isSyncing else { return }

        if scanTask != nil {
            pendingScanReason = pendingScanReason.map { "\($0),\(reason)" } ?? reason
            return
        }

        startScan(reason: reason)
    }

    @MainActor
    private func handleClientState(_ state: MatrixClientState) {
        switch state {
        case .syncing:
            kickOnMain(reason: "syncing")
        default:
            pendingScanReason = nil
            retryWakeTask?.cancel()
            retryWakeTask = nil
            retryWakeAt = nil
            scanTask?.cancel()
        }
    }

    @MainActor
    private var isSyncing: Bool {
        if case .syncing = matrixService.state {
            return true
        }
        return false
    }

    @MainActor
    private func startScan(reason: String) {
        scanTask = Task { [weak self] in
            await self?.runScan(reason: reason)
            await MainActor.run {
                self?.finishScan()
            }
        }
    }

    @MainActor
    private func finishScan() {
        scanTask = nil

        guard let reason = pendingScanReason else { return }
        pendingScanReason = nil
        kickOnMain(reason: reason)
    }

    @MainActor
    private func runScan(reason: String) async {
        guard isSyncing,
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
                  isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func sendIfEligible(
        _ candidate: PendingReactionRecord,
        reason: String
    ) async {
        guard !inFlightReactionIds.contains(candidate.id) else { return }

        switch attemptDecision(for: candidate.id) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingReactionOutbox(
                "outbox wait reason=\(reason) id=\(candidate.id) "
                    + "delaySec=\(String(format: "%.1f", delay))"
            )
            scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        }

        inFlightReactionIds.insert(candidate.id)
        defer {
            inFlightReactionIds.remove(candidate.id)
        }

        guard let latest = pendingReactions.record(id: candidate.id) else {
            clearRetryMetadata(for: candidate.id)
            return
        }

        guard let room = room(for: latest.roomId) else {
            logOutgoingReactionOutbox(
                "outbox missing room reason=\(reason) id=\(latest.id) room=\(latest.roomId)"
            )
            scheduleWake(after: TimeInterval(initialRetryDelaySeconds), reason: "missing-room")
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
              isSyncing else { return }

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
              isSyncing else { return }

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
        let now = Date()
        if let nextRetryAt = nextRetryAtByReactionId[reactionId],
           nextRetryAt > now {
            return .wait(nextRetryAt.timeIntervalSince(now))
        }
        return .send
    }

    @MainActor
    private func scheduleRetry(for reactionId: String) {
        let delay = retryDelaySecondsByReactionId[reactionId] ?? initialRetryDelaySeconds
        retryDelaySecondsByReactionId[reactionId] = min(delay * 2, maxRetryDelaySeconds)
        nextRetryAtByReactionId[reactionId] = Date().addingTimeInterval(TimeInterval(delay))
        scheduleWake(after: TimeInterval(delay), reason: "retryable-failure")
    }

    @MainActor
    private func scheduleWake(after delay: TimeInterval, reason: String) {
        guard delay > 0 else {
            kickOnMain(reason: reason)
            return
        }

        let wakeAt = Date().addingTimeInterval(delay)
        if let retryWakeAt,
           retryWakeAt <= wakeAt {
            return
        }

        retryWakeTask?.cancel()
        retryWakeAt = wakeAt
        logOutgoingReactionOutbox(
            "outbox retry scheduled reason=\(reason) delaySec=\(String(format: "%.1f", delay))"
        )
        retryWakeTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.wake(reason: reason)
            }
        }
    }

    @MainActor
    private func wake(reason: String) {
        retryWakeTask = nil
        retryWakeAt = nil
        kickOnMain(reason: reason)
    }

    @MainActor
    private func clearRetryMetadata(for reactionId: String) {
        nextRetryAtByReactionId[reactionId] = nil
        retryDelaySecondsByReactionId[reactionId] = nil
    }

    private func room(for roomId: String) -> Room? {
        try? matrixService.client?.getRoom(roomId: roomId)
    }

    @MainActor
    private func publishRoomDidUpdate(_ roomId: String) {
        roomDidUpdateSubject.send(roomId)
    }
}
