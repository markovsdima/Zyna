// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK

/// One explicit Chat/Call request per person and account at a time. Opening a
/// profile never invokes this service. SDK reads and room creation run off-main.
actor DirectConversationService {
    static let shared = DirectConversationService()
    private struct Key: Hashable { let sessionID: String; let userID: String }
    private var requests: [Key: Task<Room, Error>] = [:]

    func open(userID: String, client: Client, sessionID: String, preferredRoomID: String? = nil) async throws -> Room {
        let key = Key(sessionID: sessionID, userID: userID)
        if let request = requests[key] { return try await request.value }
        let request = Task<Room, Error> {
            let rooms = try client.getDmRooms(userId: userID)
            let joined = rooms.filter { $0.membership() == .joined }
            if let preferred = joined.first(where: { $0.id() == preferredRoomID }) { return preferred }
            if let existing = joined.first { return existing }
            if rooms.contains(where: { $0.membership() == .invited }) { throw DirectConversationError.invitationPending }
            let params = CreateRoomParameters(name: nil, topic: nil, isEncrypted: true, isDirect: true,
                visibility: .private, preset: .trustedPrivateChat, invite: [userID], avatar: nil,
                powerLevelContentOverride: nil, joinRuleOverride: nil, historyVisibilityOverride: nil, canonicalAlias: nil)
            let roomID = try await client.createRoom(request: params)
            // createRoom registers the room in the SDK before returning; the
            // UI room-list publication is asynchronous and is not a barrier.
            guard let room = try client.getRoom(roomId: roomID) else { throw DirectConversationError.roomUnavailable }
            return room
        }
        requests[key] = request
        defer { requests.removeValue(forKey: key) }
        return try await request.value
    }
}

enum DirectConversationError: LocalizedError {
    case invitationPending, roomUnavailable
    var errorDescription: String? {
        switch self {
        case .invitationPending: String(localized: "Accept the existing invitation in Chats first.", table: "RoomProfile")
        case .roomUnavailable: String(localized: "The conversation is not available yet. Please try again.", table: "RoomProfile")
        }
    }
}
