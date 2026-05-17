//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRustSDK

private let logOutgoingVoiceOutbox = ScopedLog(.timeline, prefix: "[DirectRawVoiceTx]")

struct OutgoingVoiceOutboxFailure {
    let roomId: String
    let context: OutgoingSendFailureContext
}

final class OutgoingVoiceOutboxService {

    static let shared = OutgoingVoiceOutboxService()

    let roomDidUpdateSubject = PassthroughSubject<String, Never>()
    let sendFailureSubject = PassthroughSubject<OutgoingVoiceOutboxFailure, Never>()

    private let matrixService = MatrixClientService.shared
    private let outgoingEnvelopes = OutgoingEnvelopeService.shared
    private let pendingVoices = PendingDirectVoiceService.shared

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
        guard DirectRawMediaSender.isVoiceEnabled else { return }
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
              DirectRawMediaSender.isVoiceEnabled else { return }

        handleMissingRecordCandidates(
            pendingVoices.missingRecordCandidates(envelopeIds: envelopeIds),
            reason: reason
        )

        let candidates = pendingVoices.outboxCandidates(envelopeIds: envelopeIds)
        guard !candidates.isEmpty else {
            logOutgoingVoiceOutbox("outbox scan reason=\(reason) count=0")
            return
        }

        logOutgoingVoiceOutbox(
            "outbox scan reason=\(reason) count=\(candidates.count) envelopes=\(candidates.map(\.envelope.id).joined(separator: ","))"
        )

        for candidate in candidates {
            guard !Task.isCancelled,
                  isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func handleMissingRecordCandidates(
        _ candidates: [PendingDirectVoiceMissingRecordCandidate],
        reason: String
    ) {
        guard !candidates.isEmpty else { return }

        let now = Date()
        for candidate in candidates {
            let age = now.timeIntervalSince(candidate.envelope.createdAt)
            let remainingGrace = missingRecordGraceSeconds - age
            if remainingGrace > 0 {
                scheduleWake(after: remainingGrace, reason: "missing-voice-record-grace")
                continue
            }

            logOutgoingVoiceOutbox(
                "outbox missing record reason=\(reason) envelope=\(candidate.envelope.id) "
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
        _ candidate: PendingDirectVoiceCandidate,
        reason: String
    ) async {
        let envelopeId = candidate.envelope.id
        guard !inFlightEnvelopeIds.contains(envelopeId) else { return }

        switch attemptDecision(for: candidate) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingVoiceOutbox(
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

        guard let latest = pendingVoices
            .outboxCandidates(envelopeIds: Set([envelopeId]))
            .first,
            let transactionId = latest.item.transactionId,
            !transactionId.isEmpty,
            case .send = attemptDecision(for: latest) else {
            clearRetryMetadata(for: envelopeId)
            return
        }

        guard let room = room(for: latest.envelope.roomId) else {
            logOutgoingVoiceOutbox(
                "outbox missing room reason=\(reason) envelope=\(envelopeId) room=\(latest.envelope.roomId)"
            )
            scheduleWake(after: TimeInterval(initialRetryDelaySeconds), reason: "missing-room")
            return
        }

        var voice = latest.voice
        if voice.uploadedVoiceJSON == nil {
            guard await uploadVoiceIfNeeded(
                candidate: latest,
                room: room,
                transactionId: transactionId,
                reason: reason
            ) else {
                return
            }
            guard let refreshed = pendingVoices.record(itemId: latest.item.id),
                  refreshed.uploadedVoiceJSON != nil else {
                scheduleRetry(for: envelopeId)
                return
            }
            voice = refreshed
        }

        guard let uploadedVoiceJSON = voice.uploadedVoiceJSON else {
            scheduleRetry(for: envelopeId)
            return
        }

        if outgoingEnvelopes.markDispatchStarted(
            envelopeId: envelopeId,
            itemIndex: latest.item.itemIndex
        ) {
            publishRoomDidUpdate(latest.envelope.roomId)
        }

        let receipt = await DirectRawMediaSender.sendUploadedVoice(
            room: room,
            uploadedVoiceJSON: uploadedVoiceJSON,
            replyEventId: latest.envelope.replyInfo?.eventId,
            transactionId: transactionId
        )

        guard !Task.isCancelled,
              isSyncing else { return }

        logOutgoingVoiceOutbox(
            "outbox send receipt envelope=\(envelopeId) tx=\(transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )
        completeDispatch(candidate: latest, receipt: receipt)
    }

    @MainActor
    private func uploadVoiceIfNeeded(
        candidate: PendingDirectVoiceCandidate,
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

        guard let fileName = candidate.payload.localFileName,
              !fileName.isEmpty else {
            handleRejected(candidate: candidate, receipt: .failed)
            return false
        }

        do {
            logOutgoingVoiceOutbox(
                "outbox upload start reason=\(reason) envelope=\(envelopeId) tx=\(transactionId)"
            )
            let uploadedVoiceJSON = try await DirectRawMediaSender.uploadVoice(
                room: room,
                fileURL: outgoingEnvelopes.outgoingVoiceFileURL(fileName: fileName),
                mimetype: candidate.voice.mimetype,
                duration: candidate.payload.duration,
                waveform: waveformFloats(from: candidate.payload.waveform),
                transactionId: transactionId
            )
            guard !Task.isCancelled,
                  isSyncing else { return false }

            _ = pendingVoices.markUploaded(
                itemId: candidate.item.id,
                uploadedVoiceJSON: uploadedVoiceJSON
            )
            if outgoingEnvelopes.markDispatchUploaded(
                envelopeId: envelopeId,
                itemIndex: itemIndex
            ) {
                publishRoomDidUpdate(candidate.envelope.roomId)
            }
            DirectRawMediaSender.scheduleVoiceIntentionalCrashIfNeeded(
                point: "after-upload",
                transactionId: transactionId
            )
            return true
        } catch {
            let receipt = DirectRawMediaSender.rejectedReceipt(for: error)
            logOutgoingVoiceOutbox(
                "outbox upload failed envelope=\(envelopeId) tx=\(transactionId) "
                    + "retryable=\(receipt.retryableTransportFailure) error=\(error)"
            )
            await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
            handleRejected(candidate: candidate, receipt: receipt)
            return false
        }
    }

    @MainActor
    private func attemptDecision(for candidate: PendingDirectVoiceCandidate) -> AttemptDecision {
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
        candidate: PendingDirectVoiceCandidate,
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
        candidate: PendingDirectVoiceCandidate,
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
                OutgoingVoiceOutboxFailure(
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
        logOutgoingVoiceOutbox(
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

    private func waveformFloats(from waveform: [UInt16]) -> [Float] {
        waveform.map { min(Float($0) / 1024, 1) }
    }
}
