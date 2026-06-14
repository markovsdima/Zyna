//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

enum CreateGroupPostingPermission: Equatable {
    case allMembers
    case moderatorsOnly

    var restrictsRegularMembers: Bool {
        self == .moderatorsOnly
    }
}

enum CreateGroupAccess: Equatable {
    case privateInviteOnly
    case publicAnyone
    case spaceMembers

    var isPublic: Bool {
        self == .publicAnyone
    }

    var isSpaceRestricted: Bool {
        self == .spaceMembers
    }
}

final class CreateGroupViewModel {

    let members: [UserProfile]
    var roomName = ""
    var roomTopic = ""
    var postingPermission: CreateGroupPostingPermission = .allMembers
    var roomAccess: CreateGroupAccess = .privateInviteOnly
    private(set) var roomAliasLocalPart = ""

    var onRoomCreated: ((Room) -> Void)?
    var onError: ((String) -> Void)?
    var onCreatingChanged: ((Bool) -> Void)?

    private let roomListService: ZynaRoomListService
    private let parentSpaceId: String?
    private var isCreating = false
    private var aliasWasEdited = false

    init(
        members: [UserProfile] = [],
        roomListService: ZynaRoomListService,
        parentSpaceId: String? = nil
    ) {
        self.members = members
        self.roomListService = roomListService
        self.parentSpaceId = parentSpaceId
        if parentSpaceId != nil {
            roomAccess = .spaceMembers
        }
    }

    var serverName: String? {
        guard let userId = try? MatrixClientService.shared.client?.userId() else { return nil }
        return Self.serverName(from: userId)
    }

    func updateRoomName(_ value: String) {
        roomName = value
        guard !aliasWasEdited else { return }
        roomAliasLocalPart = Self.defaultAliasLocalPart(for: value)
    }

    func updateRoomTopic(_ value: String) {
        roomTopic = value
    }

    func updatePostingPermission(_ permission: CreateGroupPostingPermission) {
        postingPermission = permission
    }

    func updateRoomAccess(_ access: CreateGroupAccess) {
        roomAccess = access
        if access.isPublic, roomAliasLocalPart.isEmpty {
            roomAliasLocalPart = Self.defaultAliasLocalPart(for: roomName)
        }
    }

    func updateRoomAliasLocalPart(_ value: String) {
        roomAliasLocalPart = Self.normalizedAliasLocalPart(value, serverName: serverName)
        aliasWasEdited = true
    }

    func createRoom() {
        guard !isCreating else { return }

        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            onError?(String(localized: "Room name is required"))
            return
        }
        let topic = roomTopic
        let postingPermission = postingPermission
        let access = roomAccess
        let aliasLocalPartSnapshot = roomAliasLocalPart
        let aliasWasEditedSnapshot = aliasWasEdited

        isCreating = true
        onCreatingChanged?(true)

        Task { [weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                await MainActor.run {
                    self.isCreating = false
                    self.onCreatingChanged?(false)
                    self.onError?(String(localized: "Matrix client is not ready."))
                }
                return
            }
            do {
                let aliasLocalPart = try await aliasLocalPartIfNeeded(
                    client: client,
                    roomName: name,
                    access: access,
                    aliasLocalPart: aliasLocalPartSnapshot,
                    aliasWasEdited: aliasWasEditedSnapshot
                )
                let isPublic = access.isPublic
                let isSpaceRestricted = access.isSpaceRestricted
                let isEncrypted = !isPublic && !isSpaceRestricted
                let preset: RoomPreset = isEncrypted ? .privateChat : .publicChat
                let historyVisibilityOverride: RoomHistoryVisibility?
                if isPublic {
                    historyVisibilityOverride = nil
                } else if isSpaceRestricted {
                    historyVisibilityOverride = .shared
                } else {
                    historyVisibilityOverride = .invited
                }
                let joinRuleOverride = try restrictedJoinRuleIfNeeded(access: access)
                let params = CreateRoomParameters(
                    name: name,
                    topic: topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : topic,
                    isEncrypted: isEncrypted,
                    isDirect: false,
                    visibility: isPublic ? .public : .private,
                    preset: preset,
                    invite: members.map(\.userId),
                    avatar: nil,
                    powerLevelContentOverride: Self.powerLevelContentOverride(
                        postingPermission: postingPermission
                    ),
                    joinRuleOverride: joinRuleOverride,
                    historyVisibilityOverride: historyVisibilityOverride,
                    canonicalAlias: aliasLocalPart
                )
                let roomId = try await client.createRoom(request: params)
                if let parentSpaceId {
                    try await roomListService.addChild(roomId, toSpace: parentSpaceId, context: "chat")
                }

                if let room = await waitForCreatedRoom(roomId: roomId) {
                    await MainActor.run { self.onRoomCreated?(room) }
                } else {
                    await MainActor.run {
                        self.onError?(String(localized: "Room was created, but it is not available locally yet. Please wait for sync and open it from the room list."))
                    }
                }
            } catch {
                await MainActor.run {
                    self.onError?(String(localized: "Failed to create room: \(error.localizedDescription)"))
                }
            }

            await MainActor.run {
                self.isCreating = false
                self.onCreatingChanged?(false)
            }
        }
    }

    private func aliasLocalPartIfNeeded(
        client: Client,
        roomName: String,
        access: CreateGroupAccess,
        aliasLocalPart: String,
        aliasWasEdited: Bool
    ) async throws -> String? {
        guard access.isPublic else { return nil }

        guard let serverName = Self.serverName(from: try client.userId()) else {
            throw RoomCreationValidationError.missingServerName
        }

        let localPart = aliasLocalPart.isEmpty && !aliasWasEdited
            ? Self.defaultAliasLocalPart(for: roomName)
            : aliasLocalPart

        guard !localPart.isEmpty else {
            throw RoomCreationValidationError.missingAlias
        }

        let canonicalAlias = "#\(localPart):\(serverName)"
        guard isRoomAliasFormatValid(alias: canonicalAlias) else {
            throw RoomCreationValidationError.invalidAlias
        }

        guard try await client.isRoomAliasAvailable(alias: canonicalAlias) else {
            throw RoomCreationValidationError.aliasTaken
        }

        return localPart
    }

    private func restrictedJoinRuleIfNeeded(access: CreateGroupAccess) throws -> JoinRule? {
        guard access.isSpaceRestricted else { return nil }
        guard let parentSpaceId else {
            throw RoomCreationValidationError.missingParentSpace
        }
        return .restricted(rules: [.roomMembership(roomId: parentSpaceId)])
    }

    private func waitForCreatedRoom(roomId: String) async -> Room? {
        for _ in 0..<20 {
            if let room = roomListService.room(for: roomId) {
                return room
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return roomListService.room(for: roomId)
    }

    private static func powerLevelContentOverride(
        postingPermission: CreateGroupPostingPermission
    ) -> PowerLevels {
        PowerLevels(
            usersDefault: postingPermission.restrictsRegularMembers ? 0 : nil,
            eventsDefault: postingPermission.restrictsRegularMembers ? 50 : nil,
            stateDefault: nil,
            ban: nil,
            kick: nil,
            redact: nil,
            invite: nil,
            notifications: nil,
            users: [:],
            events: MatrixRTCRoomPowerLevelPermissions.participantCallEventOverrides
        )
    }

    private static func defaultAliasLocalPart(for roomName: String) -> String {
        MatrixAliasLocalPart.generated(from: roomName)
    }

    private static func normalizedAliasLocalPart(_ value: String, serverName: String?) -> String {
        MatrixAliasLocalPart.normalizedUserInput(value, serverName: serverName)
    }

    private static func serverName(from userId: String) -> String? {
        guard let colonIndex = userId.firstIndex(of: ":") else { return nil }
        let serverStart = userId.index(after: colonIndex)
        guard serverStart < userId.endIndex else { return nil }
        return String(userId[serverStart...])
    }
}

private enum RoomCreationValidationError: LocalizedError {
    case missingServerName
    case missingAlias
    case invalidAlias
    case aliasTaken
    case missingParentSpace

    var errorDescription: String? {
        switch self {
        case .missingServerName:
            return String(localized: "Cannot determine the server name for the room address.")
        case .missingAlias:
            return String(localized: "Room address is required for public rooms.")
        case .invalidAlias:
            return String(localized: "Room address contains unsupported characters.")
        case .aliasTaken:
            return String(localized: "This room address is already taken.")
        case .missingParentSpace:
            return String(localized: "Parent space is not available for restricted access.")
        }
    }
}
