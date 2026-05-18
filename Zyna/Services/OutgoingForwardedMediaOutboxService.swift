//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRustSDK

private let logOutgoingForwardedMediaOutbox = ScopedLog(.timeline, prefix: "[DirectForwardMediaTx]")

struct OutgoingForwardedMediaOutboxFailure {
    let roomId: String
    let context: OutgoingSendFailureContext
}

final class OutgoingForwardedMediaOutboxService {

    static let shared = OutgoingForwardedMediaOutboxService()

    let roomDidUpdateSubject = PassthroughSubject<String, Never>()
    let sendFailureSubject = PassthroughSubject<OutgoingForwardedMediaOutboxFailure, Never>()

    private let matrixService = MatrixClientService.shared
    private let outgoingEnvelopes = OutgoingEnvelopeService.shared
    private let pendingForwardedMedia = PendingForwardedMediaService.shared

    private let retryBackoff = OutgoingRetryBackoff<String>()
    private let inFlight = OutgoingInFlightTracker<String>()
    private let missingRecordGraceSeconds: TimeInterval = 10
    private lazy var scanCoordinator = OutgoingOutboxScanCoordinator(
        isEnabled: { DirectRawMediaSender.isForwardedMediaEnabled },
        log: { logOutgoingForwardedMediaOutbox($0) },
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
              DirectRawMediaSender.isForwardedMediaEnabled else { return }

        handleMissingRecordCandidates(
            pendingForwardedMedia.missingRecordCandidates(envelopeIds: envelopeIds),
            reason: reason
        )

        let candidates = pendingForwardedMedia.outboxCandidates(envelopeIds: envelopeIds)
        guard !candidates.isEmpty else {
            logOutgoingForwardedMediaOutbox("outbox scan reason=\(reason) count=0")
            return
        }

        logOutgoingForwardedMediaOutbox(
            "outbox scan reason=\(reason) count=\(candidates.count) "
                + "envelopes=\(candidates.map(\.envelope.id).joined(separator: ","))"
        )

        for candidate in candidates {
            guard !Task.isCancelled,
                  scanCoordinator.isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func handleMissingRecordCandidates(
        _ candidates: [PendingForwardedMediaMissingRecordCandidate],
        reason: String
    ) {
        guard !candidates.isEmpty else { return }

        let now = Date()
        for candidate in candidates {
            let age = now.timeIntervalSince(candidate.envelope.createdAt)
            let remainingGrace = missingRecordGraceSeconds - age
            if remainingGrace > 0 {
                scanCoordinator.scheduleWake(after: remainingGrace, reason: "missing-forwarded-record-grace")
                continue
            }

            logOutgoingForwardedMediaOutbox(
                "outbox missing record reason=\(reason) envelope=\(candidate.envelope.id) "
                    + "ageSec=\(String(format: "%.1f", age))"
            )
            if outgoingEnvelopes.markDispatchFailed(
                envelopeId: candidate.envelope.id,
                itemIndex: candidate.item.itemIndex
            ) {
                publishRoomDidUpdate(candidate.envelope.roomId)
            }
        }
    }

    @MainActor
    private func sendIfEligible(
        _ candidate: PendingForwardedMediaCandidate,
        reason: String
    ) async {
        let envelopeId = candidate.envelope.id
        guard inFlight.begin(envelopeId) else { return }
        defer {
            inFlight.end(envelopeId)
        }

        switch attemptDecision(for: candidate) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingForwardedMediaOutbox(
                "outbox wait reason=\(reason) envelope=\(envelopeId) "
                    + "state=\(candidate.item.transportState.rawValue) "
                    + "delaySec=\(String(format: "%.1f", delay))"
            )
            scanCoordinator.scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        case .skip:
            return
        }

        guard let latest = pendingForwardedMedia
            .outboxCandidates(envelopeIds: Set([envelopeId]))
            .first,
            case .send = attemptDecision(for: latest) else {
            clearRetryMetadata(for: envelopeId)
            return
        }

        guard let room = room(for: latest.envelope.roomId) else {
            logOutgoingForwardedMediaOutbox(
                "outbox missing room reason=\(reason) envelope=\(envelopeId) room=\(latest.envelope.roomId)"
            )
            scanCoordinator.scheduleWake(after: retryBackoff.initialDelay, reason: "missing-room")
            return
        }

        let transactionId = latest.forwardedMedia.transactionId
        let msgType: MessageType
        do {
            msgType = try latest.forwardedMedia.messageType(
                zynaAttributes: latest.envelope.zynaAttributes
            )
        } catch {
            logOutgoingForwardedMediaOutbox(
                "outbox build failed envelope=\(envelopeId) tx=\(transactionId) error=\(error)"
            )
            handleRejected(candidate: latest, receipt: .failed)
            return
        }

        logOutgoingForwardedMediaOutbox(
            "outbox send start reason=\(reason) envelope=\(envelopeId) tx=\(transactionId) "
                + "kind=\(latest.forwardedMedia.mediaKind) state=\(latest.item.transportState.rawValue)"
        )

        if outgoingEnvelopes.markDispatchStarted(
            envelopeId: envelopeId,
            itemIndex: latest.item.itemIndex
        ) {
            publishRoomDidUpdate(latest.envelope.roomId)
        }

        let receipt = await DirectRawMediaSender.sendForwardedMedia(
            room: room,
            msgType: msgType,
            replyEventId: latest.envelope.replyInfo?.eventId,
            transactionId: transactionId
        )

        guard !Task.isCancelled,
              scanCoordinator.isSyncing else { return }

        logOutgoingForwardedMediaOutbox(
            "outbox send receipt envelope=\(envelopeId) tx=\(transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )
        completeDispatch(candidate: latest, receipt: receipt)
    }

    @MainActor
    private func attemptDecision(
        for candidate: PendingForwardedMediaCandidate
    ) -> AttemptDecision {
        switch candidate.item.transportState {
        case .queued, .sending:
            return .send
        case .retrying:
            if let delay = retryBackoff.waitDelay(for: candidate.envelope.id) {
                return .wait(delay)
            }
            return .send
        case .uploading, .uploaded, .sent, .failed:
            return .skip
        }
    }

    @MainActor
    private func completeDispatch(
        candidate: PendingForwardedMediaCandidate,
        receipt: OutgoingDispatchReceipt
    ) {
        if !receipt.acceptedByTransport {
            handleRejected(candidate: candidate, receipt: receipt)
            return
        }

        clearRetryMetadata(for: candidate.envelope.id)
        guard let transactionId = receipt.transactionId,
              let eventId = receipt.eventId else {
            if outgoingEnvelopes.markDispatchStarted(
                envelopeId: candidate.envelope.id,
                itemIndex: candidate.item.itemIndex
            ) {
                publishRoomDidUpdate(candidate.envelope.roomId)
            }
            return
        }

        if outgoingEnvelopes.completeDirectDispatch(
            envelopeId: candidate.envelope.id,
            itemIndex: candidate.item.itemIndex,
            transactionId: transactionId,
            eventId: eventId
        ) {
            publishRoomDidUpdate(candidate.envelope.roomId)
        }
    }

    @MainActor
    private func handleRejected(
        candidate: PendingForwardedMediaCandidate,
        receipt: OutgoingDispatchReceipt
    ) {
        if receipt.retryableTransportFailure {
            if outgoingEnvelopes.markDispatchRetrying(
                envelopeId: candidate.envelope.id,
                itemIndex: candidate.item.itemIndex
            ) {
                publishRoomDidUpdate(candidate.envelope.roomId)
            }
            scheduleRetry(for: candidate.envelope.id)
            return
        }

        clearRetryMetadata(for: candidate.envelope.id)
        if outgoingEnvelopes.markDispatchFailed(
            envelopeId: candidate.envelope.id,
            itemIndex: candidate.item.itemIndex
        ) {
            publishRoomDidUpdate(candidate.envelope.roomId)
        }
        if let context = receipt.failureContext {
            sendFailureSubject.send(
                OutgoingForwardedMediaOutboxFailure(
                    roomId: candidate.envelope.roomId,
                    context: context
                )
            )
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
