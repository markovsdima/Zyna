// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import MatrixRustSDK

@MainActor
final class PersonProfileViewModel {
    @Published private(set) var snapshot: PersonProfileSnapshot
    @Published private(set) var isLoading = false
    @Published private(set) var isPerformingAction = false
    @Published private(set) var loadError: String?
    @Published var actionError: String?
    @Published private(set) var presence: UserPresence?
    let blocking: UserBlockingViewModel
    var onOpenChat: ((Room) -> Void)?
    var onRemovedFromGroup: (() -> Void)?

    private let source: any PersonProfileSource
    private let openConversation: @Sendable () async throws -> Room
    private let isCurrentSession: () -> Bool
    private let tracksPresence: Bool
    private let presenceTag = "person-profile-" + UUID().uuidString
    private var presenceObservation: AnyCancellable?
    private var observation: RoomProfileObservation?
    private var loadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var generation = 0
    private var revision = 0
    private var started = false
    private var needsReload = false

    init(snapshot: PersonProfileSnapshot, source: any PersonProfileSource, blocking: UserBlockingViewModel,
         tracksPresence: Bool = true, isCurrentSession: @escaping () -> Bool,
         openConversation: @escaping @Sendable () async throws -> Room) {
        self.snapshot = snapshot
        self.source = source
        self.blocking = blocking
        self.tracksPresence = tracksPresence
        self.isCurrentSession = isCurrentSession
        self.openConversation = openConversation
    }

    deinit { loadTask?.cancel(); actionTask?.cancel() }

    static func make(userID: String, room: Room? = nil, title: String? = nil,
                     avatarURL: String? = nil, preferredRoomID: String? = nil) -> PersonProfileViewModel? {
        guard let client = MatrixClientService.shared.client,
              let sessionID = MatrixClientService.shared.currentLocalSessionId,
              let ownID = try? client.userId() else { return nil }
        let current = { MatrixClientService.shared.currentLocalSessionId == sessionID }
        let blocking = UserBlockingViewModel(userID: userID, ownUserID: ownID,
            source: IgnoredUsersService(client: client), isCurrentSession: current)
        return PersonProfileViewModel(snapshot: .init(userID: userID, title: title ?? userID,
            avatarURL: avatarURL, isSelf: userID == ownID),
            source: SDKPersonProfileSource(client: client, userID: userID, ownUserID: ownID, room: room),
            blocking: blocking, isCurrentSession: current,
            openConversation: {
                try await DirectConversationService.shared.open(userID: userID, client: client,
                    sessionID: sessionID, preferredRoomID: preferredRoomID)
            })
    }

    var canOpenChat: Bool { started && !snapshot.isSelf && !isPerformingAction && isCurrentSession() }

    func start() {
        guard !started, isCurrentSession() else { return }
        started = true
        generation += 1
        let generation = generation
        observation = source.observe { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(generation) else { return }
                self.refresh()
            }
        }
        if tracksPresence {
            PresenceTracker.shared.register(userIds: [snapshot.userID], for: presenceTag)
            presenceObservation = PresenceTracker.shared.$statuses.receive(on: DispatchQueue.main)
                .sink { [weak self] statuses in
                    guard let self, self.accepts(generation) else { return }
                    let next = statuses[self.snapshot.userID]
                    if self.presence?.online != next?.online || self.presence?.lastSeen != next?.lastSeen {
                        self.presence = next
                    }
                }
        }
        blocking.start()
        refresh()
    }

    func stop() {
        started = false
        generation += 1
        observation = nil
        presenceObservation = nil
        if tracksPresence { PresenceTracker.shared.unregister(for: presenceTag) }
        loadTask?.cancel(); actionTask?.cancel()
        blocking.stop()
        isLoading = false
        isPerformingAction = false
        needsReload = false
    }

    func refresh() {
        guard started, isCurrentSession() else { return }
        guard !isPerformingAction else { needsReload = true; return }
        loadTask?.cancel()
        revision += 1
        let revision = revision, generation = generation, source = source
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                let value = try await source.load()
                guard let self, !Task.isCancelled, self.accepts(generation), self.revision == revision else { return }
                self.apply(value)
                self.loadError = nil
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled, self.accepts(generation), self.revision == revision else { return }
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func openChat() {
        guard canOpenChat else { return }
        beginAction()
        let generation = generation, openConversation = openConversation
        actionTask = Task { [weak self] in
            guard self?.accepts(generation) == true, !Task.isCancelled else { return }
            do {
                let room = try await openConversation()
                guard let self, !Task.isCancelled, self.accepts(generation) else { return }
                self.finishAction()
                self.onOpenChat?(room)
            } catch {
                guard let self, !Task.isCancelled, self.accepts(generation) else { return }
                self.actionError = error.localizedDescription
                self.finishAction()
            }
        }
    }

    func perform(_ action: PersonProfileModeration, reason: String? = nil) {
        guard started, isCurrentSession(), !isPerformingAction, snapshot.allows(action) else { return }
        beginAction()
        let generation = generation, source = source
        actionTask = Task { [weak self] in
            guard self?.accepts(generation) == true, !Task.isCancelled else { return }
            do {
                let fresh = try await source.load()
                guard let self, !Task.isCancelled, self.accepts(generation) else { return }
                self.apply(fresh)
                guard fresh.allows(action) else { throw PersonProfileError.actionUnavailable }
                try await source.perform(action, reason: reason)
                guard !Task.isCancelled, self.accepts(generation) else { return }
                if case .role(let role) = action {
                    var confirmed = fresh
                    confirmed.group?.role = role
                    if let mine = confirmed.group?.ownPowerLevel, SDKPersonProfileSource.level(role) >= mine {
                        confirmed.group?.availableRoles = []
                        confirmed.group?.canKick = false
                        confirmed.group?.canBan = false
                        confirmed.group?.canUnban = false
                    }
                    self.apply(confirmed)
                }
                self.finishAction()
                if action == .kick || action == .ban { self.onRemovedFromGroup?() }
                else if action == .unban { self.refresh() }
            } catch {
                guard let self, !Task.isCancelled, self.accepts(generation) else { return }
                self.actionError = error.localizedDescription
                self.finishAction()
                self.refresh()
            }
        }
    }

    private func beginAction() {
        loadTask?.cancel()
        revision += 1
        isLoading = false
        isPerformingAction = true
    }

    private func finishAction() {
        isPerformingAction = false
        if needsReload { needsReload = false; refresh() }
    }

    private func apply(_ value: PersonProfileSnapshot) {
        guard value.userID == snapshot.userID else { return }
        if snapshot != value { snapshot = value }
    }

    private func accepts(_ generation: Int) -> Bool {
        started && self.generation == generation && isCurrentSession()
    }
}
