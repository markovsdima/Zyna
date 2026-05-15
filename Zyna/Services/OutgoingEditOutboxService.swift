//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRustSDK

private let logOutgoingEditOutbox = ScopedLog(.timeline, prefix: "[DirectRawEditTx]")

struct OutgoingEditOutboxFailure {
    let roomId: String
    let context: OutgoingSendFailureContext
}

final class OutgoingEditOutboxService {

    static let shared = OutgoingEditOutboxService()

    let roomDidUpdateSubject = PassthroughSubject<String, Never>()
    let sendFailureSubject = PassthroughSubject<OutgoingEditOutboxFailure, Never>()

    private let matrixService = MatrixClientService.shared
    private let pendingEdits = PendingMessageEditService.shared

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var scanTask: Task<Void, Never>?
    private var pendingScanReason: String?
    private var retryWakeTask: Task<Void, Never>?
    private var retryWakeAt: Date?
    private var inFlightEditIds = Set<String>()
    private var nextRetryAtByEditId: [String: Date] = [:]
    private var retryDelaySecondsByEditId: [String: UInt64] = [:]

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

        let candidates = pendingEdits.pendingDirectRawEdits()
        guard !candidates.isEmpty else {
            logOutgoingEditOutbox("outbox scan reason=\(reason) count=0")
            return
        }

        logOutgoingEditOutbox(
            "outbox scan reason=\(reason) count=\(candidates.count) edits=\(candidates.map(editId).joined(separator: ","))"
        )

        for candidate in candidates {
            guard !Task.isCancelled,
                  isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func sendIfEligible(
        _ candidate: PendingMessageEditSnapshot,
        reason: String
    ) async {
        let id = editId(candidate)
        guard !inFlightEditIds.contains(id) else { return }

        switch attemptDecision(for: id) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingEditOutbox(
                "outbox wait reason=\(reason) edit=\(id) delaySec=\(String(format: "%.1f", delay))"
            )
            scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
        }

        inFlightEditIds.insert(id)
        defer {
            inFlightEditIds.remove(id)
        }

        guard let latest = pendingEdits
            .pendingDirectRawEdits(roomId: candidate.roomId, eventId: candidate.eventId)
            .first,
            latest.transactionId == candidate.transactionId else {
            clearRetryMetadata(for: id)
            return
        }

        guard let room = room(for: latest.roomId) else {
            logOutgoingEditOutbox(
                "outbox missing room reason=\(reason) edit=\(id) room=\(latest.roomId)"
            )
            scheduleWake(after: TimeInterval(initialRetryDelaySeconds), reason: "missing-room")
            return
        }

        logOutgoingEditOutbox(
            "outbox send start reason=\(reason) edit=\(id) tx=\(latest.transactionId)"
        )

        let receipt = await DirectRawTextSender.sendEdit(
            room: room,
            eventId: latest.eventId,
            body: latest.body,
            zynaAttributes: latest.zynaAttributes,
            transactionId: latest.transactionId
        )

        guard !Task.isCancelled,
              isSyncing else { return }

        logOutgoingEditOutbox(
            "outbox send receipt edit=\(id) tx=\(latest.transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )
        completeDispatch(edit: latest, receipt: receipt)
    }

    @MainActor
    private func attemptDecision(for editId: String) -> AttemptDecision {
        let now = Date()
        if let nextRetryAt = nextRetryAtByEditId[editId],
           nextRetryAt > now {
            return .wait(nextRetryAt.timeIntervalSince(now))
        }
        return .send
    }

    @MainActor
    private func completeDispatch(
        edit: PendingMessageEditSnapshot,
        receipt: OutgoingDispatchReceipt
    ) {
        let id = editId(edit)
        if !receipt.acceptedByTransport {
            if receipt.retryableTransportFailure {
                scheduleRetry(for: id)
                return
            }

            clearRetryMetadata(for: id)
            if pendingEdits.markDirectRawEditFailed(
                roomId: edit.roomId,
                eventId: edit.eventId,
                transactionId: edit.transactionId
            ) {
                publishRoomDidUpdate(edit.roomId)
            }
            if let context = receipt.failureContext {
                sendFailureSubject.send(
                    OutgoingEditOutboxFailure(roomId: edit.roomId, context: context)
                )
            }
            return
        }

        clearRetryMetadata(for: id)
        guard let editEventId = receipt.eventId else {
            publishRoomDidUpdate(edit.roomId)
            return
        }

        if pendingEdits.applyAcceptedDirectRawEdit(
            roomId: edit.roomId,
            eventId: edit.eventId,
            transactionId: edit.transactionId,
            editEventId: editEventId,
            body: edit.body,
            zynaAttributes: edit.zynaAttributes
        ) {
            publishRoomDidUpdate(edit.roomId)
        }
    }

    @MainActor
    private func scheduleRetry(for editId: String) {
        let delay = retryDelaySecondsByEditId[editId] ?? initialRetryDelaySeconds
        retryDelaySecondsByEditId[editId] = min(delay * 2, maxRetryDelaySeconds)
        nextRetryAtByEditId[editId] = Date().addingTimeInterval(TimeInterval(delay))
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
        logOutgoingEditOutbox(
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
    private func clearRetryMetadata(for editId: String) {
        nextRetryAtByEditId[editId] = nil
        retryDelaySecondsByEditId[editId] = nil
    }

    @MainActor
    private func publishRoomDidUpdate(_ roomId: String) {
        roomDidUpdateSubject.send(roomId)
    }

    @MainActor
    private func room(for roomId: String) -> Room? {
        try? matrixService.client?.getRoom(roomId: roomId)
    }

    private func editId(_ edit: PendingMessageEditSnapshot) -> String {
        "\(edit.roomId)|\(edit.eventId)"
    }
}
