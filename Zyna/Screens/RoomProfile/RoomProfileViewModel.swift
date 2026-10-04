// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import MatrixRustSDK

struct RoomProfileSnapshot: Equatable, Sendable {
    struct Permissions: Equatable, Sendable {
        var invite: Bool
        var editName: Bool
        var editAvatar: Bool
        var editTopic = false
        var canEdit: Bool { editName || editAvatar || editTopic }
    }

    var roomID: String
    var title: String
    var avatarURL: String?
    var isDirect: Bool
    var directUserID: String?
    var memberCount: Int?
    var topic: String?
    var address: String?
    var isJoined = false
    var permissions: Permissions?
    var notificationContext: RoomNotificationContext?

    init(roomID: String, title: String, directUserID: String? = nil, memberCount: Int? = nil) {
        self.roomID = roomID
        self.title = title
        self.isDirect = directUserID != nil
        self.directUserID = directUserID
        self.memberCount = memberCount
    }

    init(info: RoomInfo, fallbackUserID: String?) {
        let hero = info.isDirect ? info.heroes.first : nil
        roomID = info.id
        isDirect = info.isDirect
        directUserID = info.isDirect ? (hero?.userId ?? fallbackUserID) : nil
        title = info.displayName ?? hero?.displayName ?? directUserID ?? info.id
        avatarURL = info.avatarUrl ?? hero?.avatarUrl
        memberCount = Int(clamping: info.joinedMembersCount)
        topic = info.isDirect ? nil : info.topic
        address = info.isDirect ? directUserID : (info.canonicalAlias ?? info.id)
        isJoined = info.membership == .joined
        if let power = info.powerLevels {
            permissions = Permissions(invite: power.canOwnUserInvite(),
                editName: power.canOwnUserSendState(stateEvent: .roomName),
                editAvatar: power.canOwnUserSendState(stateEvent: .roomAvatar),
                editTopic: power.canOwnUserSendState(stateEvent: .roomTopic))
        }
        notificationContext = RoomNotificationContext(info)
    }
}

enum RoomProfileAction: String, CaseIterable {
    case call, invite, search, notifications, more, members, edit, information, attachments, message

    static func primary(for snapshot: RoomProfileSnapshot) -> [Self] {
        // Keep the first slot stable as permissions arrive or change.
        [snapshot.isDirect ? .call : .invite, .search, .notifications, .more]
    }

    func isEnabled(in snapshot: RoomProfileSnapshot) -> Bool {
        switch self {
        case .call: snapshot.isJoined && snapshot.isDirect
        case .invite: snapshot.isJoined && !snapshot.isDirect && snapshot.permissions?.invite == true
        case .edit: snapshot.isJoined && !snapshot.isDirect && snapshot.permissions?.canEdit == true
        case .members: !snapshot.isDirect
        case .search, .notifications: snapshot.isJoined
        case .more, .information, .attachments: true
        case .message: false
        }
    }
}

final class RoomProfileObservation {
    private let cancellation: () -> Void
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    deinit { cancellation() }
}

protocol RoomProfileSource: Sendable {
    func load() async throws -> RoomProfileSnapshot
    func observe(_ update: @escaping @Sendable (RoomProfileSnapshot) -> Void) -> RoomProfileObservation
}

struct SDKRoomProfileSource: RoomProfileSource {
    let room: any RoomProtocol
    let fallbackUserID: String?

    func load() async throws -> RoomProfileSnapshot {
        let info = try await room.roomInfo()
        return RoomProfileSnapshot(info: info, fallbackUserID: fallbackUserID)
    }

    func observe(_ update: @escaping @Sendable (RoomProfileSnapshot) -> Void) -> RoomProfileObservation {
        let handle = room.subscribeToRoomInfoUpdates(listener: ProfileRoomInfoListener { info in
            // SDK callbacks arrive off-main. Reduce the FFI object to a small
            // value here; scrolling never queries the SDK or constructs models.
            update(RoomProfileSnapshot(info: info, fallbackUserID: fallbackUserID))
        })
        return RoomProfileObservation { handle.cancel() }
    }
}

private final class ProfileRoomInfoListener: RoomInfoListener {
    private let update: @Sendable (RoomInfo) -> Void
    init(_ update: @escaping @Sendable (RoomInfo) -> Void) { self.update = update }
    func call(roomInfo: RoomInfo) { update(roomInfo) }
}

@MainActor
final class RoomProfileViewModel {
    @Published private(set) var snapshot: RoomProfileSnapshot
    @Published private(set) var notifications: RoomNotificationSettings?
    @Published private(set) var isLoadingNotifications = false
    @Published private(set) var isSavingNotifications = false
    @Published private(set) var notificationsError: String?
    @Published private(set) var informationError: String?
    @Published var actionError: String?

    private let source: any RoomProfileSource
    private let notificationService: (any RoomNotificationSettingsProviding)?
    private let isCurrentSession: () -> Bool
    private var observation: RoomProfileObservation?
    private var settingsObservation: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var generation = 0
    private var infoRevision = 0
    private var notificationRevision = 0
    private var started = false

    init(snapshot: RoomProfileSnapshot, source: any RoomProfileSource,
         notifications: (any RoomNotificationSettingsProviding)?,
         isCurrentSession: @escaping () -> Bool) {
        self.snapshot = snapshot
        self.source = source
        notificationService = notifications
        self.isCurrentSession = isCurrentSession
    }

    deinit { loadTask?.cancel(); readTask?.cancel(); writeTask?.cancel() }

    var canChangeNotifications: Bool { canChangeNotifications(for: snapshot) }

    func canChangeNotifications(for snapshot: RoomProfileSnapshot) -> Bool {
        snapshot.isJoined && notifications != nil && notificationsError == nil
            && !isLoadingNotifications && !isSavingNotifications
    }

    func start() {
        guard !started, isCurrentSession() else { return }
        started = true
        generation += 1
        let generation = generation
        observation = source.observe { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(generation) else { return }
                self.infoRevision += 1
                self.apply(snapshot)
            }
        }
        settingsObservation = notificationService?.changes.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshNotifications() }
        reloadInformation()
    }

    func stop() {
        started = false
        generation += 1
        observation = nil
        settingsObservation = nil
        loadTask?.cancel(); readTask?.cancel(); writeTask?.cancel()
        isLoadingNotifications = false
        isSavingNotifications = false
    }

    func reloadInformation() {
        guard started, isCurrentSession() else { return }
        loadTask?.cancel()
        let generation = generation
        let revision = infoRevision
        let source = source
        loadTask = Task { [weak self] in
            do {
                let snapshot = try await source.load()
                guard let self, !Task.isCancelled, self.accepts(generation), self.infoRevision == revision else { return }
                self.apply(snapshot)
            } catch {
                guard let self, !Task.isCancelled, self.accepts(generation), self.infoRevision == revision else { return }
                self.informationError = error.localizedDescription
            }
        }
    }

    private func apply(_ value: RoomProfileSnapshot) {
        let contextChanged = snapshot.notificationContext != value.notificationContext
        if snapshot != value { snapshot = value }
        if informationError != nil { informationError = nil }
        if contextChanged || (notifications == nil && !isLoadingNotifications && notificationsError == nil) {
            refreshNotifications()
        }
    }

    func refreshNotifications() {
        guard started, isCurrentSession(), !isSavingNotifications,
              let context = snapshot.notificationContext, let notificationService else { return }
        readTask?.cancel()
        notificationRevision += 1
        let revision = notificationRevision
        let generation = generation
        isLoadingNotifications = true
        readTask = Task { [weak self] in
            do {
                let settings = try await notificationService.settings(for: context)
                guard let self, !Task.isCancelled, self.accepts(generation), self.notificationRevision == revision else { return }
                if self.notifications != settings { self.notifications = settings }
                if self.notificationsError != nil { self.notificationsError = nil }
                self.isLoadingNotifications = false
            } catch {
                guard let self, !Task.isCancelled, self.accepts(generation), self.notificationRevision == revision else { return }
                self.notificationsError = error.localizedDescription
                self.isLoadingNotifications = false
            }
        }
    }

    func setNotifications(_ selection: RoomNotificationSelection) {
        guard started, isCurrentSession(), canChangeNotifications, let notificationService,
              notifications.map(RoomNotificationSelection.init) != selection else { return }
        readTask?.cancel()
        notificationRevision += 1
        isLoadingNotifications = false
        isSavingNotifications = true
        let generation = generation
        let roomID = snapshot.roomID
        writeTask = Task { [weak self] in
            do {
                try await notificationService.set(selection, roomID: roomID)
            } catch {
                guard let self, !Task.isCancelled, self.accepts(generation) else { return }
                self.actionError = error.localizedDescription
            }
            guard let self, !Task.isCancelled, self.accepts(generation) else { return }
            self.isSavingNotifications = false
            // Read the actual rules after success or a partial server failure.
            self.refreshNotifications()
        }
    }

    private func accepts(_ generation: Int) -> Bool {
        started && self.generation == generation && isCurrentSession()
    }
}
