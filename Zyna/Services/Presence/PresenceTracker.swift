//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine

private let logPresence = ScopedLog(.presence)

/// Centralized presence tracker. ViewModels register which userIds they care about
/// (identified by a tag). The tracker maintains a single polling loop and publishes
/// a merged `statuses` dictionary that all subscribers read from.
final class PresenceTracker {

    static let shared = PresenceTracker()

    @Published private(set) var statuses: [String: UserPresence] = [:]

    private var registrations: [String: Set<String>] = [:]
    private var pollingTask: Task<Void, Never>?

    private init() {}

    // MARK: - Registration

    func register(userIds: [String], for tag: String) {
        let incoming = Set(userIds)
        guard registrations[tag] != incoming else { return }
        registrations[tag] = incoming
        logPresence("[\(tag)] registered \(userIds.count) users")
        startPollingIfNeeded()
        Task { await poll() }
    }

    func unregister(for tag: String) {
        guard registrations[tag] != nil else { return }
        registrations.removeValue(forKey: tag)
        logPresence("[\(tag)] unregistered, active tags: \(registrations.keys.joined(separator: ", "))")
        if registrations.isEmpty {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.poll()
            }
        }
    }

    @MainActor
    func poll() async {
        let ids = Array(registrations.values.reduce(into: Set<String>()) { $0.formUnion($1) })
        guard !ids.isEmpty else { return }
        let result = await PresenceService.shared.batchStatus(userIds: ids)
        for (id, presence) in result {
            statuses[id] = presence
        }
    }
}
