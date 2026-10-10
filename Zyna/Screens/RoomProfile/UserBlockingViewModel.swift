// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import MatrixRustSDK

/// The same account-data subscription drives profiles and blocked-user settings.
@MainActor
final class UserBlockingViewModel {
    let userID: String
    let isSelf: Bool
    @Published private(set) var isBlocked: Bool?
    @Published private(set) var isSaving = false
    @Published private(set) var loadError: String?
    @Published var actionError: String?

    private let source: any IgnoredUsersProviding
    private let isCurrentSession: () -> Bool
    private var observation: TaskHandle?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var generation = 0
    private var revision = 0
    private var started = false

    init(userID: String, ownUserID: String, source: any IgnoredUsersProviding,
         isCurrentSession: @escaping () -> Bool) {
        self.userID = userID
        isSelf = userID == ownUserID
        self.source = source
        self.isCurrentSession = isCurrentSession
    }

    deinit { observation?.cancel(); readTask?.cancel(); writeTask?.cancel() }

    static func currentSessionFactory() -> (String) -> UserBlockingViewModel? {
        guard let client = MatrixClientService.shared.client,
              let sessionID = MatrixClientService.shared.currentLocalSessionId,
              let ownID = try? client.userId() else { return { _ in nil } }
        return { userID in
            guard MatrixClientService.shared.currentLocalSessionId == sessionID else { return nil }
            return UserBlockingViewModel(userID: userID, ownUserID: ownID,
                source: IgnoredUsersService(client: client),
                isCurrentSession: { MatrixClientService.shared.currentLocalSessionId == sessionID })
        }
    }

    var canChange: Bool { started && !isSelf && isBlocked != nil && loadError == nil && !isSaving && isCurrentSession() }

    func start() {
        guard !started, !isSelf, isCurrentSession() else { return }
        started = true
        generation += 1
        let generation = generation
        observation = source.observeIgnoredUsers { [weak self] ids in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(generation) else { return }
                self.revision += 1
                self.apply(ids)
            }
        }
        refresh()
    }

    func stop() {
        started = false
        generation += 1
        observation?.cancel(); observation = nil
        readTask?.cancel(); writeTask?.cancel()
        isSaving = false
    }

    func refresh() {
        guard started, isCurrentSession(), !isSaving else { return }
        readTask?.cancel()
        revision += 1
        let revision = revision, generation = generation, source = source
        readTask = Task { [weak self] in
            do {
                let ids = try await source.ignoredUserIds()
                guard let self, !Task.isCancelled, self.accepts(generation), self.revision == revision else { return }
                self.apply(ids)
            } catch {
                guard let self, !Task.isCancelled, self.accepts(generation), self.revision == revision else { return }
                self.loadError = error.localizedDescription
            }
        }
    }

    func setBlocked(_ blocked: Bool) {
        guard canChange, isBlocked != blocked else { return }
        readTask?.cancel()
        revision += 1
        isSaving = true
        let generation = generation, source = source, userID = userID
        writeTask = Task { [weak self] in
            guard self?.accepts(generation) == true, !Task.isCancelled else { return }
            do {
                if blocked { try await source.ignore(userId: userID) }
                else { try await source.unignore(userId: userID) }
                guard let self, !Task.isCancelled, self.accepts(generation) else { return }
                self.isBlocked = blocked
                self.loadError = nil
                self.actionError = nil
                self.isSaving = false
                // The write is acknowledged. The sync subscription will
                // reconcile later changes without a second account-data GET.
                return
            } catch {
                guard let self, !Task.isCancelled, self.accepts(generation) else { return }
                self.actionError = error.localizedDescription
            }
            guard let self, !Task.isCancelled, self.accepts(generation) else { return }
            self.isSaving = false
            self.refresh()
        }
    }

    private func apply(_ ids: [String]) {
        let value = ids.contains(userID)
        if isBlocked != value { isBlocked = value }
        if loadError != nil { loadError = nil }
    }

    private func accepts(_ generation: Int) -> Bool {
        started && self.generation == generation && isCurrentSession()
    }
}
