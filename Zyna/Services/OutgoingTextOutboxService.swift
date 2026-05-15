//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRustSDK

private let logOutgoingTextOutbox = ScopedLog(.timeline, prefix: "[DirectRawTx]")

struct OutgoingTextOutboxFailure {
    let roomId: String
    let context: OutgoingSendFailureContext
}

final class OutgoingTextOutboxService {

    static let shared = OutgoingTextOutboxService()

    let roomDidUpdateSubject = PassthroughSubject<String, Never>()
    let sendFailureSubject = PassthroughSubject<OutgoingTextOutboxFailure, Never>()

    private let matrixService = MatrixClientService.shared
    private let outgoingEnvelopes = OutgoingEnvelopeService.shared

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var scanTask: Task<Void, Never>?
    private var pendingScanReason: String?
    private var pendingEnvelopeIds: Set<String>?
    private var retryWakeTask: Task<Void, Never>?
    private var retryWakeAt: Date?
    private var inFlightEnvelopeIds = Set<String>()
    private var nextRetryAtByEnvelopeId: [String: Date] = [:]
    private var retryDelaySecondsByEnvelopeId: [String: UInt64] = [:]

    private let initialRetryDelaySeconds: UInt64 = 5
    private let maxRetryDelaySeconds: UInt64 = 60

    private enum AttemptDecision {
        case send
        case wait(TimeInterval)
        case skip
    }

    private init() {}

    func start() {
        Task { @MainActor in
            self.startOnMain()
        }
    }

    func kick(reason: String, envelopeId: String? = nil) {
        let envelopeIds = envelopeId.map { Set([$0]) }
        Task { @MainActor in
            self.kickOnMain(reason: reason, envelopeIds: envelopeIds)
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
    private func kickOnMain(reason: String, envelopeIds: Set<String>?) {
        guard DirectRawTextSender.isEnabled else { return }
        guard isSyncing else { return }

        if scanTask != nil {
            let hadPendingScan = pendingScanReason != nil
            pendingScanReason = pendingScanReason.map { "\($0),\(reason)" } ?? reason
            mergePendingEnvelopeIds(envelopeIds, hadPendingScan: hadPendingScan)
            return
        }

        startScan(reason: reason, envelopeIds: envelopeIds)
    }

    @MainActor
    private func handleClientState(_ state: MatrixClientState) {
        switch state {
        case .syncing:
            kickOnMain(reason: "syncing", envelopeIds: nil)
        default:
            pendingScanReason = nil
            pendingEnvelopeIds = nil
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
    private func mergePendingEnvelopeIds(
        _ envelopeIds: Set<String>?,
        hadPendingScan: Bool
    ) {
        guard hadPendingScan else {
            pendingEnvelopeIds = envelopeIds
            return
        }
        if pendingEnvelopeIds == nil || envelopeIds == nil {
            pendingEnvelopeIds = nil
            return
        }
        pendingEnvelopeIds?.formUnion(envelopeIds ?? [])
    }

    @MainActor
    private func startScan(reason: String, envelopeIds: Set<String>?) {
        scanTask = Task { [weak self] in
            await self?.runScan(reason: reason, envelopeIds: envelopeIds)
            await MainActor.run {
                self?.finishScan()
            }
        }
    }

    @MainActor
    private func finishScan() {
        scanTask = nil

        guard let reason = pendingScanReason else { return }
        let envelopeIds = pendingEnvelopeIds
        pendingScanReason = nil
        pendingEnvelopeIds = nil
        kickOnMain(reason: reason, envelopeIds: envelopeIds)
    }

    @MainActor
    private func runScan(reason: String, envelopeIds: Set<String>?) async {
        guard isSyncing,
              DirectRawTextSender.isEnabled else { return }

        let candidates = outgoingEnvelopes.directTextOutboxCandidates(envelopeIds: envelopeIds)
        guard !candidates.isEmpty else {
            logOutgoingTextOutbox("outbox scan reason=\(reason) count=0")
            return
        }

        logOutgoingTextOutbox(
            "outbox scan reason=\(reason) count=\(candidates.count) envelopes=\(candidates.map(\.id).joined(separator: ","))"
        )

        for candidate in candidates {
            guard !Task.isCancelled,
                  isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func sendIfEligible(
        _ candidate: OutgoingEnvelopeSnapshot,
        reason: String
    ) async {
        guard !inFlightEnvelopeIds.contains(candidate.id) else { return }

        switch attemptDecision(for: candidate) {
        case .send:
            break
        case .wait(let delay):
            if let item = candidate.primaryItem {
                logOutgoingTextOutbox(
                    "outbox wait reason=\(reason) envelope=\(candidate.id) "
                        + "state=\(item.transportState.rawValue) "
                        + "delaySec=\(String(format: "%.1f", delay))"
                )
            }
            scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        case .skip:
            return
        }

        inFlightEnvelopeIds.insert(candidate.id)
        defer {
            inFlightEnvelopeIds.remove(candidate.id)
        }

        guard let envelope = outgoingEnvelopes.envelope(id: candidate.id),
              OutgoingEnvelopeService.isDirectTextOutboxCandidate(envelope),
              case .send = attemptDecision(for: envelope),
              let item = envelope.primaryItem,
              let transactionId = item.transactionId,
              let textPayload = envelope.textPayload else {
            clearRetryMetadata(for: candidate.id)
            return
        }

        guard let room = room(for: envelope.roomId) else {
            logOutgoingTextOutbox(
                "outbox missing room reason=\(reason) envelope=\(envelope.id) room=\(envelope.roomId)"
            )
            scheduleWake(after: TimeInterval(initialRetryDelaySeconds), reason: "missing-room")
            return
        }

        logOutgoingTextOutbox(
            "outbox send start reason=\(reason) envelope=\(envelope.id) tx=\(transactionId) state=\(item.transportState.rawValue)"
        )

        if outgoingEnvelopes.markDispatchStarted(
            envelopeId: envelope.id,
            itemIndex: item.itemIndex
        ) {
            publishRoomDidUpdate(envelope.roomId)
        }

        let receipt = await DirectRawTextSender.send(
            room: room,
            body: textPayload.body,
            zynaAttributes: envelope.zynaAttributes,
            transactionId: transactionId
        )

        guard !Task.isCancelled,
              isSyncing else { return }

        logOutgoingTextOutbox(
            "outbox send receipt envelope=\(envelope.id) tx=\(transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )
        completeDispatch(envelope: envelope, itemIndex: item.itemIndex, receipt: receipt)
    }

    @MainActor
    private func attemptDecision(for envelope: OutgoingEnvelopeSnapshot) -> AttemptDecision {
        guard let item = envelope.primaryItem else { return .skip }
        let now = Date()

        switch item.transportState {
        case .queued:
            return .send
        case .retrying:
            if let nextRetryAt = nextRetryAtByEnvelopeId[envelope.id],
               nextRetryAt > now {
                return .wait(nextRetryAt.timeIntervalSince(now))
            }
            return .send
        case .sending:
            return .send
        case .uploading, .sent, .failed:
            return .skip
        }
    }

    @MainActor
    private func completeDispatch(
        envelope: OutgoingEnvelopeSnapshot,
        itemIndex: Int,
        receipt: OutgoingDispatchReceipt
    ) {
        if !receipt.acceptedByTransport {
            if receipt.retryableTransportFailure {
                if outgoingEnvelopes.markDispatchRetrying(
                    envelopeId: envelope.id,
                    itemIndex: itemIndex
                ) {
                    publishRoomDidUpdate(envelope.roomId)
                }
                scheduleRetry(for: envelope.id)
                return
            }

            clearRetryMetadata(for: envelope.id)
            if outgoingEnvelopes.markDispatchFailed(
                envelopeId: envelope.id,
                itemIndex: itemIndex
            ) {
                publishRoomDidUpdate(envelope.roomId)
            }
            if let context = receipt.failureContext {
                sendFailureSubject.send(
                    OutgoingTextOutboxFailure(roomId: envelope.roomId, context: context)
                )
            }
            return
        }

        clearRetryMetadata(for: envelope.id)
        let didMarkStarted = outgoingEnvelopes.markDispatchStarted(
            envelopeId: envelope.id,
            itemIndex: itemIndex
        )

        guard let transactionId = receipt.transactionId else {
            if didMarkStarted {
                publishRoomDidUpdate(envelope.roomId)
            }
            return
        }

        let didBindTransaction = outgoingEnvelopes.bindTransaction(
            envelopeId: envelope.id,
            itemIndex: itemIndex,
            transactionId: transactionId
        )
        let didBindEvent: Bool
        if let eventId = receipt.eventId {
            didBindEvent = outgoingEnvelopes.bindEvent(
                transactionId: transactionId,
                eventId: eventId
            )
        } else {
            didBindEvent = false
        }

        if didMarkStarted || didBindTransaction || didBindEvent {
            publishRoomDidUpdate(envelope.roomId)
        }
    }

    @MainActor
    private func scheduleRetry(for envelopeId: String) {
        let delay = retryDelaySecondsByEnvelopeId[envelopeId] ?? initialRetryDelaySeconds
        retryDelaySecondsByEnvelopeId[envelopeId] = min(delay * 2, maxRetryDelaySeconds)
        nextRetryAtByEnvelopeId[envelopeId] = Date().addingTimeInterval(TimeInterval(delay))
        scheduleWake(after: TimeInterval(delay), reason: "retryable-failure")
    }

    @MainActor
    private func scheduleWake(after delay: TimeInterval, reason: String) {
        guard delay > 0 else {
            kickOnMain(reason: reason, envelopeIds: nil)
            return
        }

        let wakeAt = Date().addingTimeInterval(delay)
        if let retryWakeAt,
           retryWakeAt <= wakeAt {
            return
        }

        retryWakeTask?.cancel()
        retryWakeAt = wakeAt
        logOutgoingTextOutbox(
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
        kickOnMain(reason: reason, envelopeIds: nil)
    }

    @MainActor
    private func clearRetryMetadata(for envelopeId: String) {
        nextRetryAtByEnvelopeId[envelopeId] = nil
        retryDelaySecondsByEnvelopeId[envelopeId] = nil
    }

    @MainActor
    private func publishRoomDidUpdate(_ roomId: String) {
        roomDidUpdateSubject.send(roomId)
    }

    @MainActor
    private func room(for roomId: String) -> Room? {
        try? matrixService.client?.getRoom(roomId: roomId)
    }
}
