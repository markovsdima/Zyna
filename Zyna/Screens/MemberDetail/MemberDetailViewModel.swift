//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

final class MemberDetailViewModel {

    struct State {
        var member: MemberCellNode.Model?
        var membership: MembershipState = .leave
        var canChangeRole: Bool = false
        var canKick: Bool = false
        var canBan: Bool = false
        var canSendMessage: Bool = false
        var availableRoles: [MemberCellNode.Role] = []
    }

    @Published private(set) var state = State()

    var onError: ((Error) -> Void)?
    var onDismiss: (() -> Void)?

    private let room: Room
    private let targetUserId: String
    private var myPowerLevel: Int = 0
    private var targetPowerLevel: Int = 0
    private var isSelf: Bool = false

    init(room: Room, userId: String) {
        self.room = room
        self.targetUserId = userId
        load()
    }

    // MARK: - Load

    private func load() {
        Task { [weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client,
                  let myId = try? client.userId() else { return }
            isSelf = myId == targetUserId

            async let targetMember = room.member(userId: targetUserId)
            async let myMember = room.member(userId: myId)

            do {
                let target = try await targetMember
                let me = try await myMember
                await MainActor.run { [weak self] in
                    self?.apply(target: target, me: me)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.onError?(error)
                }
            }
        }
    }

    private func apply(target: RoomMember, me: RoomMember) {
        targetPowerLevel = Self.powerLevel(from: target.powerLevel)
        myPowerLevel = Self.powerLevel(from: me.powerLevel)

        let role = MemberCellNode.Role.from(powerLevel: targetPowerLevel)
        let targetModel = MemberCellNode.Model(
            userId: target.userId,
            displayName: target.displayName,
            avatarUrl: target.avatarUrl,
            role: role,
            presence: PresenceTracker.shared.statuses[target.userId]
        )

        let canManage = !isSelf
            && myPowerLevel >= 50
            && myPowerLevel > targetPowerLevel
        let available = Self.availableRoles(myPowerLevel: myPowerLevel)

        state = State(
            member: targetModel,
            membership: target.membership,
            canChangeRole: canManage && available.count > 1,
            canKick: canManage,
            canBan: canManage,
            canSendMessage: !isSelf,
            availableRoles: available
        )
    }

    // MARK: - Actions

    func changeRole(to role: MemberCellNode.Role) {
        // Optimistic: update UI immediately. The SDK's local cache
        // lags one sync behind the server round-trip, so a reload
        // right after the call would momentarily snap back to the
        // old role. On failure we reload to restore from cache.
        var newState = state
        newState.member?.role = role
        state = newState
        targetPowerLevel = Self.powerLevel(for: role)

        let newPL = Int64(Self.powerLevel(for: role))
        let update = UserPowerLevelUpdate(userId: targetUserId, powerLevel: newPL)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await room.updatePowerLevelsForUsers(updates: [update])
            } catch {
                await MainActor.run { [weak self] in
                    self?.load()
                    self?.onError?(error)
                }
            }
        }
    }

    func kick(reason: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await room.kickUser(userId: targetUserId, reason: reason?.nilIfEmpty)
                await MainActor.run { [weak self] in self?.onDismiss?() }
            } catch {
                await MainActor.run { [weak self] in self?.onError?(error) }
            }
        }
    }

    func ban(reason: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await room.banUser(userId: targetUserId, reason: reason?.nilIfEmpty)
                await MainActor.run { [weak self] in self?.onDismiss?() }
            } catch {
                await MainActor.run { [weak self] in self?.onError?(error) }
            }
        }
    }

    // MARK: - Helpers

    private static func powerLevel(from pl: PowerLevel) -> Int {
        switch pl {
        case .infinite:         return 100
        case .value(let value): return Int(value)
        }
    }

    private static func powerLevel(for role: MemberCellNode.Role) -> Int {
        switch role {
        case .owner:     return 100
        case .admin:     return 50
        case .moderator: return 25
        case .member:    return 0
        }
    }

    /// Roles whose target power level is strictly below mine — the
    /// only roles a user can grant under Matrix rules.
    private static func availableRoles(myPowerLevel: Int) -> [MemberCellNode.Role] {
        MemberCellNode.Role.allCases.filter { role in
            powerLevel(for: role) < myPowerLevel
        }
    }
}

private extension String {
    /// Matrix APIs expect nil (not empty string) to signal "no reason".
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
