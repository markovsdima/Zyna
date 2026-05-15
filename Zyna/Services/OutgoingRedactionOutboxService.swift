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

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var scanTask: Task<Void, Never>?
    private var pendingScanReason: String?
    private var retryWakeTask: Task<Void, Never>?
    private var retryWakeAt: Date?
    private var inFlightMessageIds = Set<String>()
    private var nextRetryAtByMessageId: [String: Date] = [:]
    private var retryDelaySecondsByMessageId: [String: UInt64] = [:]

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
                  isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func sendIfEligible(
        _ record: PendingRedactionRecord,
        reason: String
    ) async {
        guard !inFlightMessageIds.contains(record.messageId) else { return }

        switch attemptDecision(for: record.messageId) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingRedactionOutbox(
                "outbox wait reason=\(reason) messageId=\(record.messageId) "
                    + "delaySec=\(String(format: "%.1f", delay))"
            )
            scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        }

        inFlightMessageIds.insert(record.messageId)
        defer {
            inFlightMessageIds.remove(record.messageId)
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
        let now = Date()
        if let nextRetryAt = nextRetryAtByMessageId[messageId],
           nextRetryAt > now {
            return .wait(nextRetryAt.timeIntervalSince(now))
        }
        return .send
    }

    @MainActor
    private func scheduleRetry(for messageId: String) {
        let delay = retryDelaySecondsByMessageId[messageId] ?? initialRetryDelaySeconds
        retryDelaySecondsByMessageId[messageId] = min(delay * 2, maxRetryDelaySeconds)
        nextRetryAtByMessageId[messageId] = Date().addingTimeInterval(TimeInterval(delay))
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
        logOutgoingRedactionOutbox(
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
    private func clearRetryMetadata(for messageId: String) {
        nextRetryAtByMessageId[messageId] = nil
        retryDelaySecondsByMessageId[messageId] = nil
    }

    @MainActor
    private func publishRoomDidUpdate(_ roomId: String) {
        roomDidUpdateSubject.send(roomId)
    }
}
