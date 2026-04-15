//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine

private let log = ScopedLog(.presence)

final class PresenceTracker {

    static let shared = PresenceTracker()

    @Published private(set) var statuses: [String: UserPresence] = [:]

    private var registrations: [String: Set<String>] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var connected = false

    private init() {
        let service = PresenceService.shared

        service.onStatuses = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (id, presence) in snapshot {
                    self.statuses[id] = presence
                }
            }
        }

        service.onPresenceChange = { [weak self] userId, presence in
            Task { @MainActor [weak self] in
                self?.statuses[userId] = presence
            }
        }

        service.onDisconnect = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleReconnect()
            }
        }
    }

    // MARK: - Connection Lifecycle

    func connect() {
        guard Brand.current.presenceEnabled else { return }

        reconnectTask?.cancel()
        reconnectTask = nil

        guard let client = MatrixClientService.shared.client,
              let session = try? client.session(),
              let userId = try? client.userId()
        else {
            log("Cannot connect: no active Matrix session")
            return
        }

        connected = true

        Task {
            do {
                try await PresenceService.shared.connect(
                    accessToken: session.accessToken,
                    userId: userId
                )
                await MainActor.run { [weak self] in
                    self?.resubscribe()
                }
            } catch {
                log("Connection failed: \(error)")
                await MainActor.run { [weak self] in
                    self?.scheduleReconnect()
                }
            }
        }
    }

    func disconnect() {
        connected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        PresenceService.shared.disconnect()
    }

    // MARK: - Registration

    func register(userIds: [String], for tag: String) {
        let incoming = Set(userIds)
        guard registrations[tag] != incoming else { return }
        registrations[tag] = incoming
        log("[\(tag)] registered \(userIds.count) users")
        resubscribe()
    }

    func unregister(for tag: String) {
        guard registrations[tag] != nil else { return }
        registrations.removeValue(forKey: tag)
        log("[\(tag)] unregistered")
    }

    // MARK: - Subscribe

    private func resubscribe() {
        let ids = Array(registrations.values.reduce(into: Set<String>()) { $0.formUnion($1) })
        guard !ids.isEmpty else { return }
        PresenceService.shared.subscribe(userIds: ids)
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard connected else { return }
        connected = false
        reconnectTask?.cancel()

        reconnectTask = Task { [weak self] in
            for attempt in 1...5 {
                let delay = min(pow(2.0, Double(attempt - 1)), 30) + Double.random(in: 0...0.5)
                log("Reconnect #\(attempt) in \(String(format: "%.1f", delay))s")
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                guard let client = MatrixClientService.shared.client,
                      let session = try? client.session(),
                      let userId = try? client.userId()
                else { continue }

                do {
                    try await PresenceService.shared.connect(
                        accessToken: session.accessToken,
                        userId: userId
                    )
                    await MainActor.run { [weak self] in
                        self?.connected = true
                        self?.resubscribe()
                    }
                    log("Reconnected")
                    return
                } catch {
                    log("Reconnect #\(attempt) failed: \(error)")
                }
            }
            log("Gave up reconnecting")
        }
    }
}
