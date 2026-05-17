//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRustSDK

private let logOutgoingVideoOutbox = ScopedLog(.timeline, prefix: "[DirectRawVideoTx]")

struct OutgoingVideoOutboxFailure {
    let roomId: String
    let context: OutgoingSendFailureContext
}

final class OutgoingVideoOutboxService {

    static let shared = OutgoingVideoOutboxService()

    let roomDidUpdateSubject = PassthroughSubject<String, Never>()
    let sendFailureSubject = PassthroughSubject<OutgoingVideoOutboxFailure, Never>()

    private let matrixService = MatrixClientService.shared
    private let outgoingEnvelopes = OutgoingEnvelopeService.shared
    private let pendingVideos = PendingDirectVideoService.shared

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
    private let missingAssetGraceSeconds: TimeInterval = 10

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
        guard DirectRawMediaSender.isVideoEnabled else { return }
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
              DirectRawMediaSender.isVideoEnabled else { return }

        handleMissingAssetCandidates(
            pendingVideos.missingAssetCandidates(envelopeIds: envelopeIds),
            reason: reason
        )

        let candidates = pendingVideos.outboxCandidates(envelopeIds: envelopeIds)
        guard !candidates.isEmpty else {
            logOutgoingVideoOutbox("outbox scan reason=\(reason) count=0")
            return
        }

        logOutgoingVideoOutbox(
            "outbox scan reason=\(reason) count=\(candidates.count) "
                + "envelopes=\(candidates.map(\.envelope.id).joined(separator: ","))"
        )

        for candidate in candidates {
            guard !Task.isCancelled,
                  isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func handleMissingAssetCandidates(
        _ candidates: [PendingDirectVideoMissingAssetCandidate],
        reason: String
    ) {
        guard !candidates.isEmpty else { return }

        let now = Date()
        for candidate in candidates {
            let age = now.timeIntervalSince(candidate.envelope.createdAt)
            let remainingGrace = missingAssetGraceSeconds - age
            if remainingGrace > 0 {
                scheduleWake(after: remainingGrace, reason: "missing-video-asset-grace")
                continue
            }

            logOutgoingVideoOutbox(
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
        _ candidate: PendingDirectVideoCandidate,
        reason: String
    ) async {
        let envelopeId = candidate.envelope.id
        guard !inFlightEnvelopeIds.contains(envelopeId) else { return }

        switch attemptDecision(for: candidate) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingVideoOutbox(
                "outbox wait reason=\(reason) envelope=\(envelopeId) "
                    + "state=\(candidate.item.transportState.rawValue) "
                    + "delaySec=\(String(format: "%.1f", delay))"
            )
            scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        case .skip:
            return
        }

        inFlightEnvelopeIds.insert(envelopeId)
        defer {
            inFlightEnvelopeIds.remove(envelopeId)
        }

        guard let latest = pendingVideos
            .outboxCandidates(envelopeIds: Set([envelopeId]))
            .first,
            let transactionId = latest.item.transactionId,
            !transactionId.isEmpty,
            case .send = attemptDecision(for: latest) else {
            clearRetryMetadata(for: envelopeId)
            return
        }

        guard let room = room(for: latest.envelope.roomId) else {
            logOutgoingVideoOutbox(
                "outbox missing room reason=\(reason) envelope=\(envelopeId) room=\(latest.envelope.roomId)"
            )
            scheduleWake(after: TimeInterval(initialRetryDelaySeconds), reason: "missing-room")
            return
        }

        var video = latest.video
        if video.uploadedVideoJSON == nil {
            guard await uploadVideoIfNeeded(
                candidate: latest,
                room: room,
                transactionId: transactionId,
                reason: reason
            ) else {
                return
            }
            guard let refreshed = pendingVideos.record(itemId: latest.item.id),
                  refreshed.uploadedVideoJSON != nil else {
                scheduleRetry(for: envelopeId)
                return
            }
            video = refreshed
        }

        guard let uploadedVideoJSON = video.uploadedVideoJSON else {
            scheduleRetry(for: envelopeId)
            return
        }

        if outgoingEnvelopes.markDispatchStarted(
            envelopeId: envelopeId,
            itemIndex: latest.item.itemIndex
        ) {
            publishRoomDidUpdate(latest.envelope.roomId)
        }

        let receipt = await DirectRawMediaSender.sendUploadedVideo(
            room: room,
            uploadedVideoJSON: uploadedVideoJSON,
            caption: latest.payload.caption,
            zynaAttributes: latest.envelope.zynaAttributes,
            replyEventId: latest.envelope.replyInfo?.eventId,
            transactionId: transactionId
        )

        guard !Task.isCancelled,
              isSyncing else { return }

        logOutgoingVideoOutbox(
            "outbox send receipt envelope=\(envelopeId) tx=\(transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )
        completeDispatch(candidate: latest, receipt: receipt)
    }

    @MainActor
    private func uploadVideoIfNeeded(
        candidate: PendingDirectVideoCandidate,
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
            logOutgoingVideoOutbox(
                "outbox upload start reason=\(reason) envelope=\(envelopeId) tx=\(transactionId)"
            )
            let uploadedVideoJSON = try await DirectRawMediaSender.uploadVideo(
                room: room,
                video: candidate.video,
                originalFileURL: pendingVideos.originalFileURL(for: candidate.video),
                thumbnailFileURL: pendingVideos.thumbnailFileURL(for: candidate.video),
                transactionId: transactionId
            )
            guard !Task.isCancelled,
                  isSyncing else { return false }

            _ = pendingVideos.markUploaded(
                itemId: candidate.item.id,
                uploadedVideoJSON: uploadedVideoJSON
            )
            if outgoingEnvelopes.markDispatchUploaded(
                envelopeId: envelopeId,
                itemIndex: itemIndex
            ) {
                publishRoomDidUpdate(candidate.envelope.roomId)
            }
            DirectRawMediaSender.scheduleVideoIntentionalCrashIfNeeded(
                point: "after-upload",
                transactionId: transactionId
            )
            return true
        } catch {
            let receipt = DirectRawMediaSender.rejectedReceipt(for: error)
            logOutgoingVideoOutbox(
                "outbox upload failed envelope=\(envelopeId) tx=\(transactionId) "
                    + "retryable=\(receipt.retryableTransportFailure) error=\(error)"
            )
            await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
            handleRejected(candidate: candidate, receipt: receipt)
            return false
        }
    }

    @MainActor
    private func attemptDecision(for candidate: PendingDirectVideoCandidate) -> AttemptDecision {
        let now = Date()

        switch candidate.item.transportState {
        case .queued, .uploading, .uploaded, .sending:
            return .send
        case .retrying:
            if let nextRetryAt = nextRetryAtByEnvelopeId[candidate.envelope.id],
               nextRetryAt > now {
                return .wait(nextRetryAt.timeIntervalSince(now))
            }
            return .send
        case .sent, .failed:
            return .skip
        }
    }

    @MainActor
    private func completeDispatch(
        candidate: PendingDirectVideoCandidate,
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
        candidate: PendingDirectVideoCandidate,
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
                OutgoingVideoOutboxFailure(
                    roomId: candidate.envelope.roomId,
                    context: context
                )
            )
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
        logOutgoingVideoOutbox(
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
