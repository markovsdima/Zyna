//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

final class OutgoingOutboxScanCoordinator {

    typealias EnvelopeIds = Set<String>?

    private let matrixService = MatrixClientService.shared
    private let isEnabled: () -> Bool
    private let log: (String) -> Void
    private let scan: (String, EnvelopeIds) async -> Void

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var scanTask: Task<Void, Never>?
    private var pendingScanReason: String?
    private var pendingEnvelopeIds: EnvelopeIds = nil
    private var wakeTask: Task<Void, Never>?
    private var wakeAt: Date?

    init(
        isEnabled: @escaping () -> Bool,
        log: @escaping (String) -> Void,
        scan: @escaping (String, EnvelopeIds) async -> Void
    ) {
        self.isEnabled = isEnabled
        self.log = log
        self.scan = scan
    }

    var isSyncing: Bool {
        if case .syncing = matrixService.state {
            return true
        }
        return false
    }

    func start() {
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

    func kick(reason: String, envelopeId: String? = nil) {
        let envelopeIds = envelopeId.map { Set([$0]) }
        kick(reason: reason, envelopeIds: envelopeIds)
    }

    func kick(reason: String) {
        kick(reason: reason, envelopeIds: nil)
    }

    func scheduleWake(after delay: TimeInterval, reason: String) {
        guard delay > 0 else {
            kick(reason: reason, envelopeIds: nil)
            return
        }

        let nextWakeAt = Date().addingTimeInterval(delay)
        if let wakeAt,
           wakeAt <= nextWakeAt {
            return
        }

        wakeTask?.cancel()
        wakeAt = nextWakeAt
        log("outbox retry scheduled reason=\(reason) delaySec=\(String(format: "%.1f", delay))")
        wakeTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.wake(reason: reason)
        }
    }

    private func kick(reason: String, envelopeIds: EnvelopeIds) {
        guard isEnabled() else { return }
        guard isSyncing else { return }

        if scanTask != nil {
            let hadPendingScan = pendingScanReason != nil
            pendingScanReason = pendingScanReason.map { "\($0),\(reason)" } ?? reason
            mergePendingEnvelopeIds(envelopeIds, hadPendingScan: hadPendingScan)
            return
        }

        startScan(reason: reason, envelopeIds: envelopeIds)
    }

    private func handleClientState(_ state: MatrixClientState) {
        switch state {
        case .syncing:
            kick(reason: "syncing", envelopeIds: nil)
        default:
            pendingScanReason = nil
            pendingEnvelopeIds = nil
            wakeTask?.cancel()
            wakeTask = nil
            wakeAt = nil
            scanTask?.cancel()
        }
    }

    private func mergePendingEnvelopeIds(
        _ envelopeIds: EnvelopeIds,
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

    private func startScan(reason: String, envelopeIds: EnvelopeIds) {
        scanTask = Task { @MainActor [weak self] in
            await self?.scan(reason, envelopeIds)
            self?.finishScan()
        }
    }

    private func finishScan() {
        scanTask = nil

        guard let reason = pendingScanReason else { return }
        let envelopeIds = pendingEnvelopeIds
        pendingScanReason = nil
        pendingEnvelopeIds = nil
        kick(reason: reason, envelopeIds: envelopeIds)
    }

    private func wake(reason: String) {
        wakeTask = nil
        wakeAt = nil
        kick(reason: reason, envelopeIds: nil)
    }
}

final class OutgoingRetryBackoff<Key: Hashable> {

    private var nextRetryAtByKey: [Key: Date] = [:]
    private var retryDelaySecondsByKey: [Key: UInt64] = [:]

    let initialDelaySeconds: UInt64
    private let maxDelaySeconds: UInt64

    init(initialDelaySeconds: UInt64 = 5, maxDelaySeconds: UInt64 = 60) {
        self.initialDelaySeconds = initialDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
    }

    var initialDelay: TimeInterval {
        TimeInterval(initialDelaySeconds)
    }

    func waitDelay(for key: Key) -> TimeInterval? {
        guard let nextRetryAt = nextRetryAtByKey[key] else { return nil }
        let delay = nextRetryAt.timeIntervalSince(Date())
        return delay > 0 ? delay : nil
    }

    func scheduleRetry(for key: Key) -> TimeInterval {
        let delay = retryDelaySecondsByKey[key] ?? initialDelaySeconds
        retryDelaySecondsByKey[key] = min(delay * 2, maxDelaySeconds)
        nextRetryAtByKey[key] = Date().addingTimeInterval(TimeInterval(delay))
        return TimeInterval(delay)
    }

    func clear(_ key: Key) {
        nextRetryAtByKey[key] = nil
        retryDelaySecondsByKey[key] = nil
    }
}

final class OutgoingInFlightTracker<Key: Hashable> {

    private var keys = Set<Key>()

    func begin(_ key: Key) -> Bool {
        guard !keys.contains(key) else { return false }
        keys.insert(key)
        return true
    }

    func end(_ key: Key) {
        keys.remove(key)
    }
}
