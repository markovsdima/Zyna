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
    var lastMessageTimestamp: TimeInterval?
    var unreadCount: Int
    var unreadMentionCount: Int
    var isMarkedUnread: Bool
    var isEncrypted: Bool
    var directUserId: String?
    var sortOrder: Int
}

// MARK: - RoomSummary → StoredRoom

extension StoredRoom {

    init(from summary: RoomSummary, sortOrder: Int) {
        self.id = summary.id
        self.displayName = summary.displayName
        self.avatarURL = summary.avatarURL
        self.lastMessage = summary.lastMessage
        self.lastMessageTimestamp = summary.lastMessageTimestamp?.timeIntervalSince1970
        self.unreadCount = Int(summary.unreadCount)
        self.unreadMentionCount = Int(summary.unreadMentionCount)
        self.isMarkedUnread = summary.isMarkedUnread
        self.isEncrypted = summary.isEncrypted
        self.directUserId = summary.directUserId
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
            lastMessageTimestamp: lastMessageTimestamp.map { Date(timeIntervalSince1970: $0) },
            unreadCount: UInt64(unreadCount),
            unreadMentionCount: UInt64(unreadMentionCount),
            isMarkedUnread: isMarkedUnread,
            isEncrypted: isEncrypted,
            directUserId: directUserId
        )
    }
}
