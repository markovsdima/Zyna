//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

final class SpaceCreationViewModel {

    let mode: SpaceCreationMode
    var name = ""
    var topic = ""
    var access: SpaceCreationAccess = .privateInviteOnly
    private(set) var aliasLocalPart = ""

    var onSpaceCreated: ((RoomModel) -> Void)?
    var onError: ((String) -> Void)?
    var onCreatingChanged: ((Bool) -> Void)?

    private let roomListService: ZynaRoomListService
    private var isCreating = false
    private var aliasWasEdited = false

    init(mode: SpaceCreationMode, roomListService: ZynaRoomListService) {
        self.mode = mode
        self.roomListService = roomListService
        if case .track = mode {
            access = .parentMembers
        }
    }

    var serverName: String? {
        guard let userId = try? MatrixClientService.shared.client?.userId() else { return nil }
        return Self.serverName(from: userId)
    }

    func updateName(_ value: String) {
        name = value
        guard !aliasWasEdited else { return }
        aliasLocalPart = Self.defaultAliasLocalPart(for: value)
    }

    func updateTopic(_ value: String) {
        topic = value
    }

    func updateAccess(_ access: SpaceCreationAccess) {
        self.access = access
        if access.isPublic, aliasLocalPart.isEmpty {
            aliasLocalPart = Self.defaultAliasLocalPart(for: name)
        }
    }

    func updateAliasLocalPart(_ value: String) {
        aliasLocalPart = Self.normalizedAliasLocalPart(value, serverName: serverName)
        aliasWasEdited = true
    }

    func createSpace() {
        guard !isCreating else { return }

        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            onError?(String(localized: "Name is required"))
            return
        }
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = mode
        let selectedAccess = access
        let aliasLocalPartSnapshot = aliasLocalPart
        let aliasWasEditedSnapshot = aliasWasEdited

        isCreating = true
        onCreatingChanged?(true)

        Task { [weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                await self.finishWithError(String(localized: "Matrix client is not ready."))
                return
            }

            do {
                let aliasLocalPart = try await aliasLocalPartIfNeeded(
                    client: client,
                    spaceName: name,
                    access: selectedAccess,
                    aliasLocalPart: aliasLocalPartSnapshot,
                    aliasWasEdited: aliasWasEditedSnapshot,
                    mode: mode
                )
                let isPublic = selectedAccess.isPublic
                let isParentRestricted = selectedAccess.isParentRestricted
                let historyVisibilityOverride: RoomHistoryVisibility?
                if isPublic {
                    historyVisibilityOverride = nil
                } else if isParentRestricted {
                    historyVisibilityOverride = .shared
                } else {
                    historyVisibilityOverride = .invited
                }
                let joinRuleOverride = try parentRestrictedJoinRuleIfNeeded(
                    access: selectedAccess,
                    mode: mode
                )
                let params = CreateRoomParameters(
                    name: name,
                    topic: topic.isEmpty ? nil : topic,
                    isEncrypted: false,
                    isDirect: false,
                    visibility: isPublic ? .public : .private,
                    preset: isPublic ? .publicChat : .privateChat,
                    invite: nil,
                    avatar: nil,
                    powerLevelContentOverride: nil,
                    joinRuleOverride: joinRuleOverride,
                    historyVisibilityOverride: historyVisibilityOverride,
                    canonicalAlias: aliasLocalPart,
                    isSpace: true
                )
                let roomId: String
                do {
                    roomId = try await client.createRoom(request: params)
                } catch {
                    self.logCreationFailure(error, stage: "createRoom", mode: mode)
                    throw error
                }

                if case .track(let parent) = mode {
                    do {
                        try await self.roomListService.addChild(roomId, toSpace: parent.id, context: "track")
                    } catch {
                        self.logCreationFailure(
                            error,
                            stage: "addChildToSpace",
                            mode: mode,
                            parentId: parent.id,
                            childId: roomId
                        )
                        throw error
                    }
                }

                let model = await self.createdSpaceModel(roomId: roomId, fallbackName: name)
                await MainActor.run {
                    self.onSpaceCreated?(model)
                    self.isCreating = false
                    self.onCreatingChanged?(false)
                }
            } catch {
                await self.finishWithError(String(localized: "Failed to create \(mode.entityName): \(error.localizedDescription)"))
            }
        }
    }

    private func logCreationFailure(
        _ error: Error,
        stage: String,
        mode: SpaceCreationMode,
        parentId: String? = nil,
        childId: String? = nil
    ) {
        var parts = [
            "Space creation failed",
            "stage=\(stage)"
        ]

        switch mode {
        case .storyline:
            parts.append("mode=storyline")
        case .track(let parent):
            parts.append("mode=track")
            parts.append("modeParentId=\(parent.id)")
        }

        if let parentId {
            parts.append("parentId=\(parentId)")
        }
        if let childId {
            parts.append("childId=\(childId)")
        }

        parts.append("localized=\(error.localizedDescription)")
        parts.append("reflected=\(String(reflecting: error))")

        let message = "[SpaceCreation] " + parts.joined(separator: " ")
        print(message)
        ScopedLog(.rooms)(message)
    }

    private func finishWithError(_ message: String) async {
        await MainActor.run {
            self.isCreating = false
            self.onCreatingChanged?(false)
            self.onError?(message)
        }
    }

    private func createdSpaceModel(roomId: String, fallbackName: String) async -> RoomModel {
        let room = await waitForCreatedRoom(roomId: roomId)
        let displayName = room?.displayName() ?? fallbackName
        let avatarURL = room?.avatarUrl()

        return RoomModel(
            id: roomId,
            name: displayName,
            lastMessage: "",
            lastMessageSenderName: nil,
            timestamp: "",
            avatar: AvatarViewModel(
                userId: roomId,
                displayName: displayName,
                mxcAvatarURL: avatarURL
            ),
            isOnline: false,
            lastSeen: nil,
            unreadCount: 0,
            unreadMentionCount: 0,
            isMarkedUnread: false,
            isEncrypted: false,
            isSpace: true,
            directUserId: nil,
            spaceChildRoomCount: 0,
            spaceChildSpaceCount: 0,
            spaceRecentRooms: [],
            spaceMetadata: nil
        )
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

    private func aliasLocalPartIfNeeded(
        client: Client,
        spaceName: String,
        access: SpaceCreationAccess,
        aliasLocalPart: String,
        aliasWasEdited: Bool,
        mode: SpaceCreationMode
    ) async throws -> String? {
        guard access.isPublic else { return nil }

        guard let serverName = Self.serverName(from: try client.userId()) else {
            throw SpaceCreationValidationError.missingServerName
        }

        let localPart = aliasLocalPart.isEmpty && !aliasWasEdited
            ? Self.defaultAliasLocalPart(for: spaceName)
            : aliasLocalPart

        guard !localPart.isEmpty else {
            throw SpaceCreationValidationError.missingAlias(mode.presentationKind)
        }

        let canonicalAlias = "#\(localPart):\(serverName)"
        guard isRoomAliasFormatValid(alias: canonicalAlias) else {
            throw SpaceCreationValidationError.invalidAlias
        }

        guard try await client.isRoomAliasAvailable(alias: canonicalAlias) else {
            throw SpaceCreationValidationError.aliasTaken
        }

        return localPart
    }

    private func parentRestrictedJoinRuleIfNeeded(
        access: SpaceCreationAccess,
        mode: SpaceCreationMode
    ) throws -> JoinRule? {
        guard access.isParentRestricted else { return nil }
        guard case .track(let parent) = mode else {
            throw SpaceCreationValidationError.missingParentSpace
        }
        return .restricted(rules: [.roomMembership(roomId: parent.id)])
    }

    private static func defaultAliasLocalPart(for spaceName: String) -> String {
        MatrixAliasLocalPart.generated(from: spaceName)
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

private enum SpaceCreationValidationError: LocalizedError {
    case missingServerName
    case missingAlias(SpacePresentationKind)
    case invalidAlias
    case aliasTaken
    case missingParentSpace

    var errorDescription: String? {
        switch self {
        case .missingServerName:
            return String(localized: "Cannot determine the server name for the address.")
        case .missingAlias(.storyline):
            return String(localized: "Address is required for public Storyline.")
        case .missingAlias(.track):
            return String(localized: "Address is required for public Track.")
        case .invalidAlias:
            return String(localized: "Address contains unsupported characters.")
        case .aliasTaken:
            return String(localized: "This address is already taken.")
        case .missingParentSpace:
            return String(localized: "Parent space is not available for restricted access.")
        }
    }
}
