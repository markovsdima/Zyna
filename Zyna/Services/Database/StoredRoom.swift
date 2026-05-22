//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

struct StoredRoom: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "storedRoom"

    var id: String
    var displayName: String
    var avatarURL: String?
    var lastMessage: String?
    var lastMessageSenderName: String?
    var lastMessageTimestamp: TimeInterval?
    var unreadCount: Int
    var unreadMentionCount: Int
    var isMarkedUnread: Bool
    var isEncrypted: Bool
    var isSpace: Bool
    var isMuted: Bool
    var directUserId: String?
    var spaceChildRoomCount: Int
    var spaceChildSpaceCount: Int
    var spaceRecentRoomsJSON: String?
    var sortOrder: Int
}

// MARK: - RoomSummary → StoredRoom

extension StoredRoom {

    init(from summary: RoomSummary, sortOrder: Int) {
        self.id = summary.id
        self.displayName = summary.displayName
        self.avatarURL = summary.avatarURL
        self.lastMessage = summary.lastMessage
        self.lastMessageSenderName = summary.lastMessageSenderName
        self.lastMessageTimestamp = summary.lastMessageTimestamp?.timeIntervalSince1970
        self.unreadCount = Int(summary.unreadCount)
        self.unreadMentionCount = Int(summary.unreadMentionCount)
        self.isMarkedUnread = summary.isMarkedUnread
        self.isEncrypted = summary.isEncrypted
        self.isSpace = summary.isSpace
        self.isMuted = summary.isMuted
        self.directUserId = summary.directUserId
        self.spaceChildRoomCount = summary.spaceChildRoomCount
        self.spaceChildSpaceCount = summary.spaceChildSpaceCount
        self.spaceRecentRoomsJSON = Self.encodeSpaceRecentRooms(summary.spaceRecentRooms)
        self.sortOrder = sortOrder
    }
}

// MARK: - StoredRoom → RoomSummary

extension StoredRoom {

    func toRoomSummary() -> RoomSummary {
        RoomSummary(
            id: id,
            displayName: displayName,
            avatarURL: avatarURL,
            lastMessage: lastMessage,
            lastMessageSenderName: lastMessageSenderName,
            lastMessageTimestamp: lastMessageTimestamp.map { Date(timeIntervalSince1970: $0) },
            unreadCount: UInt64(unreadCount),
            unreadMentionCount: UInt64(unreadMentionCount),
            isMarkedUnread: isMarkedUnread,
            isEncrypted: isEncrypted,
            isSpace: isSpace,
            isMuted: isMuted,
            directUserId: directUserId,
            spaceChildRoomCount: spaceChildRoomCount,
            spaceChildSpaceCount: spaceChildSpaceCount,
            spaceRecentRooms: Self.decodeSpaceRecentRooms(spaceRecentRoomsJSON)
        )
    }

    private static func encodeSpaceRecentRooms(_ rooms: [SpaceChildSummary]) -> String? {
        guard !rooms.isEmpty,
              let data = try? JSONEncoder().encode(rooms) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeSpaceRecentRooms(_ raw: String?) -> [SpaceChildSummary] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let rooms = try? JSONDecoder().decode([SpaceChildSummary].self, from: data)
        else { return [] }
        return rooms
    }
}
