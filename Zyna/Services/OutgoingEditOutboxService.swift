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

    private let retryBackoff = OutgoingRetryBackoff<String>()
    private let inFlight = OutgoingInFlightTracker<String>()
    private lazy var scanCoordinator = OutgoingOutboxScanCoordinator(
        isEnabled: { DirectRawTextSender.isEnabled },
        log: { logOutgoingEditOutbox($0) },
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
                  scanCoordinator.isSyncing else { return }
            await sendIfEligible(candidate, reason: reason)
        }
    }

    @MainActor
    private func sendIfEligible(
        _ candidate: PendingMessageEditSnapshot,
        reason: String
    ) async {
        let id = editId(candidate)
        guard inFlight.begin(id) else { return }
        defer {
            inFlight.end(id)
        }

        switch attemptDecision(for: id) {
        case .send:
            break
        case .wait(let delay):
            logOutgoingEditOutbox(
                "outbox wait reason=\(reason) edit=\(id) delaySec=\(String(format: "%.1f", delay))"
            )
            scanCoordinator.scheduleWake(after: delay, reason: "delayed-\(reason)")
            return
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
            scanCoordinator.scheduleWake(after: retryBackoff.initialDelay, reason: "missing-room")
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
              scanCoordinator.isSyncing else { return }

        logOutgoingEditOutbox(
            "outbox send receipt edit=\(id) tx=\(latest.transactionId) "
                + "event=\(receipt.eventId ?? "-") accepted=\(receipt.acceptedByTransport)"
        )
        completeDispatch(edit: latest, receipt: receipt)
    }

    @MainActor
    private func attemptDecision(for editId: String) -> AttemptDecision {
        if let delay = retryBackoff.waitDelay(for: editId) {
            return .wait(delay)
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
        let delay = retryBackoff.scheduleRetry(for: editId)
        scanCoordinator.scheduleWake(after: delay, reason: "retryable-failure")
    }

    @MainActor
    private func clearRetryMetadata(for editId: String) {
        retryBackoff.clear(editId)
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
