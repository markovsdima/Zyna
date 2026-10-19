// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK

struct PersonProfileSnapshot: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        var roomID: String
        var title: String
        var membership: MembershipState
        var role: MemberCellNode.Role
        var availableRoles: [MemberCellNode.Role] = []
        var canKick = false
        var canBan = false
        var canUnban = false
        var ownPowerLevel: Int64 = 0
    }

    let userID: String
    var title: String
    var avatarURL: String?
    let isSelf: Bool
    var group: Group?

    func allows(_ action: PersonProfileModeration) -> Bool {
        guard !isSelf, let group else { return false }
        switch action {
        case .role(let role): return group.availableRoles.contains(role) && role != group.role
        case .kick: return group.canKick
        case .ban: return group.canBan
        case .unban: return group.canUnban
        }
    }
}

enum PersonProfileModeration: Equatable, Sendable {
    case role(MemberCellNode.Role), kick, ban, unban
}

protocol PersonProfileSource: Sendable {
    func load() async throws -> PersonProfileSnapshot
    func observe(_ invalidate: @escaping @Sendable () -> Void) -> RoomProfileObservation?
    func perform(_ action: PersonProfileModeration, reason: String?) async throws
}

struct SDKPersonProfileSource: PersonProfileSource {
    let client: Client
    let userID: String
    let ownUserID: String
    let room: Room?

    func load() async throws -> PersonProfileSnapshot {
        // Keep FFI projection and permission evaluation away from the UI actor.
        let task = Task.detached(priority: .userInitiated) {
            guard let room else { return try await loadGlobalProfile() }
            let target: RoomMember
            do {
                target = try await room.member(userId: userID)
            } catch ClientError.Generic(let message, _) where message == "User not found" {
                // The current FFI represents a missing membership with this
                // exact error. Do not hide network or own-permission failures.
                try Task.checkCancellation()
                return try await loadGlobalProfile()
            }
            async let ownMember = room.member(userId: ownUserID)
            async let info = room.roomInfo()
            let (me, roomInfo) = try await (ownMember, info)
            let mine = Self.level(me.powerLevel), theirs = Self.level(target.powerLevel)
            let canAct = userID != ownUserID && roomInfo.membership == .joined && mine > theirs
            let power = roomInfo.powerLevels
            var group = PersonProfileSnapshot.Group(roomID: roomInfo.id,
                title: roomInfo.displayName ?? roomInfo.id, membership: target.membership,
                role: MemberCellNode.Role.from(powerLevel: target.powerLevel))
            group.ownPowerLevel = mine
            if canAct, power?.canOwnUserSendState(stateEvent: .roomPowerLevels) == true {
                group.availableRoles = [.admin, .moderator, .member].filter { Self.level($0) <= mine }
            }
            group.canKick = canAct && power?.canOwnUserKick() == true
                && (target.membership == .join || target.membership == .invite)
            group.canBan = canAct && power?.canOwnUserBan() == true && target.membership != .ban
            group.canUnban = canAct && power?.canOwnUserBan() == true && target.membership == .ban
            return PersonProfileSnapshot(userID: userID, title: target.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? userID,
                avatarURL: target.avatarUrl, isSelf: userID == ownUserID, group: group)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func loadGlobalProfile() async throws -> PersonProfileSnapshot {
        try Task.checkCancellation()
        let profile = try await client.getProfile(userId: userID)
        return PersonProfileSnapshot(userID: userID, title: profile.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? userID,
            avatarURL: profile.avatarUrl, isSelf: userID == ownUserID)
    }

    func observe(_ invalidate: @escaping @Sendable () -> Void) -> RoomProfileObservation? {
        guard let room else { return nil }
        let raw = room.subscribeToRawTimelineEvents(eventTypes: ["m.room.member", "m.room.power_levels"],
            listener: PersonProfileEventListener { event in
                if event.eventType == "m.room.member" {
                    guard let data = event.rawJson.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let member = json["state_key"] as? String,
                          member == userID || member == ownUserID else { return }
                }
                invalidate()
            })
        // Ordinary message/unread updates must not trigger member reads.
        let last = Atomic<PersonRoomInfoSignature?>(nil)
        let info = room.subscribeToRoomInfoUpdates(listener: PersonProfileInfoListener { info in
            let value = PersonRoomInfoSignature(title: info.displayName, membership: info.membership)
            let changed = last.withValue { previous in
                guard previous != value else { return false }
                previous = value
                return true
            }
            if changed { invalidate() }
        })
        return RoomProfileObservation { raw.cancel(); info.cancel() }
    }

    func perform(_ action: PersonProfileModeration, reason: String?) async throws {
        guard let room else { throw PersonProfileError.actionUnavailable }
        switch action {
        case .role(let role):
            try await room.updatePowerLevelsForUsers(updates: [.init(userId: userID, powerLevel: Self.level(role))])
        case .kick: try await room.kickUser(userId: userID, reason: reason.flatMap { $0.isEmpty ? nil : $0 })
        case .ban: try await room.banUser(userId: userID, reason: reason.flatMap { $0.isEmpty ? nil : $0 })
        case .unban: try await room.unbanUser(userId: userID, reason: reason.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private static func level(_ value: PowerLevel) -> Int64 {
        switch value { case .infinite: Int64.max; case .value(let level): level }
    }

    static func level(_ role: MemberCellNode.Role) -> Int64 {
        switch role { case .owner: Int64.max; case .admin: 100; case .moderator: 50; case .member: 0 }
    }
}

enum PersonProfileError: LocalizedError {
    case actionUnavailable
    var errorDescription: String? { String(localized: "This action is no longer available. The profile has been refreshed.", table: "RoomProfile") }
}

private struct PersonRoomInfoSignature: Equatable {
    let title: String?
    let membership: Membership
}

private final class PersonProfileInfoListener: RoomInfoListener {
    let callback: @Sendable (RoomInfo) -> Void
    init(_ callback: @escaping @Sendable (RoomInfo) -> Void) { self.callback = callback }
    func call(roomInfo: RoomInfo) { callback(roomInfo) }
}

private final class PersonProfileEventListener: RawRoomEventListener {
    let callback: @Sendable (RawRoomEvent) -> Void
    init(_ callback: @escaping @Sendable (RawRoomEvent) -> Void) { self.callback = callback }
    func onEvent(event: RawRoomEvent) { callback(event) }
}
