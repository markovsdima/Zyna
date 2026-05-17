//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

private let logOutgoingRedactionOutbox = ScopedLog(.timeline, prefix: "[DirectRawRedactionTx]")

struct OutgoingRedactionOutboxFailure {
    let roomId: String
    let messageId: String
    let error: Error
    let disposition: PendingRedactionFailureDisposition
}

final class OutgoingRedactionOutboxService {

    static let shared = OutgoingRedactionOutboxService()

    let roomDidUpdateSubject = PassthroughSubject<String, Never>()
    let redactionFailureSubject = PassthroughSubject<OutgoingRedactionOutboxFailure, Never>()

    private let matrixService = MatrixClientService.shared
    private let pendingRedactions = PendingRedactionService.shared

    private let retryBackoff = OutgoingRetryBackoff<String>()
    private let inFlight = OutgoingInFlightTracker<String>()
    private lazy var scanCoordinator = OutgoingOutboxScanCoordinator(
        isEnabled: { DirectRawTextSender.isEnabled },
        log: { logOutgoingRedactionOutbox($0) },
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

        let candidates = pendingRedactions.pendingRecords()
            .filter { ($0.redactionEventId ?? "").isEmpty }
        guard !candidates.isEmpty else {
            logOutgoingRedactionOutbox("outbox scan reason=\(reason) count=0")
            return
        }

        logOutgoingRedactionOutbox(
            "outbox scan reason=\(reason) count=\(candidates.count) messages=\(candidates.map(\.messageId).joined(separator: ","))"
        )

        for candidate in candidates {
            guard !Task.isCancelled,
                  scanCoordinator.isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func sendIfEligible(
        _ record: PendingRedactionRecord,
        reason: String
    ) async {
        guard inFlight.begin(record.messageId) else { return }
        defer {
            inFlight.end(record.messageId)
        }

        switch attemptDecision(for: record.messageId) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingRedactionOutbox(
                "outbox wait reason=\(reason) messageId=\(record.messageId) "
                    + "delaySec=\(String(format: "%.1f", delay))"
            )
            scanCoordinator.scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        }

        do {
            let didAttempt = try await pendingRedactions.attemptDirectRawIfPossible(record)
            if didAttempt {
                clearRetryMetadata(for: record.messageId)
                publishRoomDidUpdate(record.roomId)
            }
        } catch {
            let attemptError = error as? PendingRedactionAttemptError
            let disposition = attemptError?.disposition ?? .retryable
            let underlyingError = attemptError?.underlyingError ?? error

            logOutgoingRedactionOutbox(
                "outbox failed reason=\(reason) messageId=\(record.messageId) "
                    + "disposition=\(disposition) error=\(underlyingError)"
            )

            switch disposition {
            case .retryable:
                scheduleRetry(for: record.messageId)
            case .terminal:
                clearRetryMetadata(for: record.messageId)
                publishRoomDidUpdate(record.roomId)
                redactionFailureSubject.send(
                    OutgoingRedactionOutboxFailure(
                        roomId: record.roomId,
                        messageId: record.messageId,
                        error: underlyingError,
                        disposition: disposition
                    )
                )
            }
        }
    }

    @MainActor
    private func attemptDecision(for messageId: String) -> AttemptDecision {
        if let delay = retryBackoff.waitDelay(for: messageId) {
            return .wait(delay)
        }
        return .send
    }

    @MainActor
    private func scheduleRetry(for messageId: String) {
        let delay = retryBackoff.scheduleRetry(for: messageId)
        scanCoordinator.scheduleWake(after: delay, reason: "retryable-failure")
    }

    @MainActor
    private func clearRetryMetadata(for messageId: String) {
        retryBackoff.clear(messageId)
    }

    @MainActor
    private func publishRoomDidUpdate(_ roomId: String) {
        roomDidUpdateSubject.send(roomId)
    }
}
