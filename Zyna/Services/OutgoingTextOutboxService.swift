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

    private let retryBackoff = OutgoingRetryBackoff<String>()
    private let inFlight = OutgoingInFlightTracker<String>()
    private lazy var scanCoordinator = OutgoingOutboxScanCoordinator(
        isEnabled: { DirectRawTextSender.isEnabled },
        log: { logOutgoingTextOutbox($0) },
        scan: { [weak self] reason, envelopeIds in
            await self?.runScan(reason: reason, envelopeIds: envelopeIds)
        }
    )

    private enum AttemptDecision {
        case send
        case wait(TimeInterval)
        case skip
    }

    private init() {}

    func start() {
        Task { @MainActor in
            self.scanCoordinator.start()
        }
    }

    func kick(reason: String, envelopeId: String? = nil) {
        Task { @MainActor in
            self.scanCoordinator.kick(reason: reason, envelopeId: envelopeId)
        }
    }

    @MainActor
    private func runScan(reason: String, envelopeIds: Set<String>?) async {
        guard scanCoordinator.isSyncing,
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
                  scanCoordinator.isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func sendIfEligible(
        _ candidate: OutgoingEnvelopeSnapshot,
        reason: String
    ) async {
        guard inFlight.begin(candidate.id) else { return }
        defer {
            inFlight.end(candidate.id)
        }

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
            scanCoordinator.scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        case .skip:
            return
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
            scanCoordinator.scheduleWake(after: retryBackoff.initialDelay, reason: "missing-room")
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
            replyInfo: envelope.replyInfo,
            zynaAttributes: envelope.zynaAttributes,
            transactionId: transactionId
        )

        guard !Task.isCancelled,
              scanCoordinator.isSyncing else { return }

        logOutgoingTextOutbox(
            "outbox send receipt envelope=\(envelope.id) tx=\(transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )
        completeDispatch(envelope: envelope, itemIndex: item.itemIndex, receipt: receipt)
    }

    @MainActor
    private func attemptDecision(for envelope: OutgoingEnvelopeSnapshot) -> AttemptDecision {
        guard let item = envelope.primaryItem else { return .skip }

        switch item.transportState {
        case .queued:
            return .send
        case .retrying:
            if let delay = retryBackoff.waitDelay(for: envelope.id) {
                return .wait(delay)
            }
            return .send
        case .sending:
            return .send
        case .uploading, .uploaded, .sent, .failed:
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
        let delay = retryBackoff.scheduleRetry(for: envelopeId)
        scanCoordinator.scheduleWake(after: delay, reason: "retryable-failure")
    }

    @MainActor
    private func clearRetryMetadata(for envelopeId: String) {
        retryBackoff.clear(envelopeId)
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
