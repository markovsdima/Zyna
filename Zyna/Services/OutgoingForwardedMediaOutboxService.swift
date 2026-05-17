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
    private let missingRecordGraceSeconds: TimeInterval = 10

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
        guard DirectRawMediaSender.isForwardedMediaEnabled else { return }
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
                  isSyncing else { return }
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
                scheduleWake(after: remainingGrace, reason: "missing-forwarded-record-grace")
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
        guard !inFlightEnvelopeIds.contains(envelopeId) else { return }

        switch attemptDecision(for: candidate) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingForwardedMediaOutbox(
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
            scheduleWake(after: TimeInterval(initialRetryDelaySeconds), reason: "missing-room")
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
              isSyncing else { return }

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
        let now = Date()

        switch candidate.item.transportState {
        case .queued, .sending:
            return .send
        case .retrying:
            if let nextRetryAt = nextRetryAtByEnvelopeId[candidate.envelope.id],
               nextRetryAt > now {
                return .wait(nextRetryAt.timeIntervalSince(now))
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
        logOutgoingForwardedMediaOutbox(
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
