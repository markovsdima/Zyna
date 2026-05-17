//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRustSDK

private let logOutgoingImageOutbox = ScopedLog(.timeline, prefix: "[DirectRawImageTx]")

struct OutgoingImageOutboxFailure {
    let roomId: String
    let context: OutgoingSendFailureContext
}

final class OutgoingImageOutboxService {

    static let shared = OutgoingImageOutboxService()

    let roomDidUpdateSubject = PassthroughSubject<String, Never>()
    let sendFailureSubject = PassthroughSubject<OutgoingImageOutboxFailure, Never>()

    private let matrixService = MatrixClientService.shared
    private let outgoingEnvelopes = OutgoingEnvelopeService.shared
    private let pendingImages = PendingDirectImageService.shared

    private let retryBackoff = OutgoingRetryBackoff<String>()
    private let inFlight = OutgoingInFlightTracker<String>()
    private let missingAssetGraceSeconds: TimeInterval = 10
    private lazy var scanCoordinator = OutgoingOutboxScanCoordinator(
        isEnabled: { DirectRawMediaSender.isImageEnabled },
        log: { logOutgoingImageOutbox($0) },
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
              DirectRawMediaSender.isImageEnabled else { return }

        handleMissingAssetCandidates(
            pendingImages.missingAssetCandidates(envelopeIds: envelopeIds),
            reason: reason
        )

        let candidates = pendingImages.outboxCandidates(envelopeIds: envelopeIds)
        guard !candidates.isEmpty else {
            logOutgoingImageOutbox("outbox scan reason=\(reason) count=0")
            return
        }

        logOutgoingImageOutbox(
            "outbox scan reason=\(reason) count=\(candidates.count) envelopes=\(candidates.map(\.envelope.id).joined(separator: ","))"
        )

        for candidate in candidates {
            guard !Task.isCancelled,
                  scanCoordinator.isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func handleMissingAssetCandidates(
        _ candidates: [PendingDirectImageMissingAssetCandidate],
        reason: String
    ) {
        guard !candidates.isEmpty else { return }

        let now = Date()
        for candidate in candidates {
            let age = now.timeIntervalSince(candidate.envelope.createdAt)
            let remainingGrace = missingAssetGraceSeconds - age
            if remainingGrace > 0 {
                scanCoordinator.scheduleWake(after: remainingGrace, reason: "missing-asset-grace")
                continue
            }

            logOutgoingImageOutbox(
                "outbox missing asset reason=\(reason) envelope=\(candidate.envelope.id) "
                    + "tx=\(candidate.item.transactionId ?? "-") ageSec=\(String(format: "%.1f", age))"
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
        _ candidate: PendingDirectImageCandidate,
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
            logOutgoingImageOutbox(
                "outbox wait reason=\(reason) envelope=\(envelopeId) "
                    + "state=\(candidate.item.transportState.rawValue) "
                    + "delaySec=\(String(format: "%.1f", delay))"
            )
            scanCoordinator.scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        case .skip:
            return
        }

        guard let latest = pendingImages
            .outboxCandidates(envelopeIds: Set([envelopeId]))
            .first,
            let transactionId = latest.item.transactionId,
            !transactionId.isEmpty,
            case .send = attemptDecision(for: latest) else {
            clearRetryMetadata(for: envelopeId)
            return
        }

        guard let room = room(for: latest.envelope.roomId) else {
            logOutgoingImageOutbox(
                "outbox missing room reason=\(reason) envelope=\(envelopeId) room=\(latest.envelope.roomId)"
            )
            scanCoordinator.scheduleWake(after: retryBackoff.initialDelay, reason: "missing-room")
            return
        }

        var image = latest.image
        if image.uploadedImageJSON == nil {
            guard await uploadImageIfNeeded(
                candidate: latest,
                room: room,
                transactionId: transactionId,
                reason: reason
            ) else {
                return
            }
            guard let refreshed = pendingImages.record(itemId: latest.item.id),
                  refreshed.uploadedImageJSON != nil else {
                scheduleRetry(for: envelopeId)
                return
            }
            image = refreshed
        }

        guard let uploadedImageJSON = image.uploadedImageJSON else {
            scheduleRetry(for: envelopeId)
            return
        }

        if outgoingEnvelopes.markDispatchStarted(
            envelopeId: envelopeId,
            itemIndex: latest.item.itemIndex
        ) {
            publishRoomDidUpdate(latest.envelope.roomId)
        }

        let receipt = await DirectRawMediaSender.sendUploadedImage(
            room: room,
            uploadedImageJSON: uploadedImageJSON,
            caption: caption(for: latest),
            zynaAttributes: zynaAttributes(for: latest),
            replyEventId: latest.envelope.replyInfo?.eventId,
            transactionId: transactionId
        )

        guard !Task.isCancelled,
              scanCoordinator.isSyncing else { return }

        logOutgoingImageOutbox(
            "outbox send receipt envelope=\(envelopeId) tx=\(transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )
        completeDispatch(candidate: latest, receipt: receipt)
    }

    @MainActor
    private func uploadImageIfNeeded(
        candidate: PendingDirectImageCandidate,
        room: Room,
        transactionId: String,
        reason: String
    ) async -> Bool {
        let envelopeId = candidate.envelope.id
        let itemIndex = candidate.item.itemIndex
        if outgoingEnvelopes.markDispatchUploading(
            envelopeId: envelopeId,
            itemIndex: itemIndex
        ) {
            publishRoomDidUpdate(candidate.envelope.roomId)
        }

        do {
            logOutgoingImageOutbox(
                "outbox upload start reason=\(reason) envelope=\(envelopeId) tx=\(transactionId)"
            )
            let uploadedImageJSON = try await DirectRawMediaSender.uploadImage(
                room: room,
                image: candidate.image,
                originalFileURL: pendingImages.originalFileURL(for: candidate.image),
                thumbnailFileURL: pendingImages.thumbnailFileURL(for: candidate.image),
                transactionId: transactionId
            )
            guard !Task.isCancelled,
                  scanCoordinator.isSyncing else { return false }

            _ = pendingImages.markUploaded(
                itemId: candidate.item.id,
                uploadedImageJSON: uploadedImageJSON
            )
            if outgoingEnvelopes.markDispatchUploaded(
                envelopeId: envelopeId,
                itemIndex: itemIndex
            ) {
                publishRoomDidUpdate(candidate.envelope.roomId)
            }
            DirectRawMediaSender.scheduleIntentionalCrashIfNeeded(
                point: "after-upload",
                transactionId: transactionId
            )
            return true
        } catch {
            let receipt = DirectRawMediaSender.rejectedReceipt(for: error)
            logOutgoingImageOutbox(
                "outbox upload failed envelope=\(envelopeId) tx=\(transactionId) "
                    + "retryable=\(receipt.retryableTransportFailure) error=\(error)"
            )
            await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
            handleRejected(candidate: candidate, receipt: receipt)
            return false
        }
    }

    @MainActor
    private func attemptDecision(for candidate: PendingDirectImageCandidate) -> AttemptDecision {
        switch candidate.item.transportState {
        case .queued, .uploading, .uploaded, .sending:
            return .send
        case .retrying:
            if let delay = retryBackoff.waitDelay(for: candidate.envelope.id) {
                return .wait(delay)
            }
            return .send
        case .sent, .failed:
            return .skip
        }
    }

    @MainActor
    private func completeDispatch(
        candidate: PendingDirectImageCandidate,
        receipt: OutgoingDispatchReceipt
    ) {
        if !receipt.acceptedByTransport {
            handleRejected(candidate: candidate, receipt: receipt)
            return
        }

        clearRetryMetadata(for: candidate.envelope.id)
        let didMarkStarted = outgoingEnvelopes.markDispatchStarted(
            envelopeId: candidate.envelope.id,
            itemIndex: candidate.item.itemIndex
        )

        guard let transactionId = receipt.transactionId else {
            if didMarkStarted {
                publishRoomDidUpdate(candidate.envelope.roomId)
            }
            return
        }

        let didBindTransaction = outgoingEnvelopes.bindTransaction(
            envelopeId: candidate.envelope.id,
            itemIndex: candidate.item.itemIndex,
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
            publishRoomDidUpdate(candidate.envelope.roomId)
        }
    }

    @MainActor
    private func handleRejected(
        candidate: PendingDirectImageCandidate,
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
                OutgoingImageOutboxFailure(
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

    private func caption(for candidate: PendingDirectImageCandidate) -> String? {
        switch candidate.envelope.kind {
        case .image:
            return candidate.envelope.imagePayload?.caption
        case .mediaBatch:
            return candidate.envelope.mediaBatchPayload?.caption
        default:
            return nil
        }
    }

    private func zynaAttributes(
        for candidate: PendingDirectImageCandidate
    ) -> ZynaMessageAttributes {
        guard let batch = candidate.envelope.mediaBatchPayload else {
            return candidate.envelope.zynaAttributes
        }

        return ZynaMessageAttributes(
            mediaGroup: MediaGroupInfo(
                id: candidate.envelope.id,
                index: candidate.item.itemIndex,
                total: candidate.envelope.expectedItemCount,
                captionMode: .replicated,
                captionPlacement: batch.captionPlacement,
                layoutOverride: batch.layoutOverride
            )
        )
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
