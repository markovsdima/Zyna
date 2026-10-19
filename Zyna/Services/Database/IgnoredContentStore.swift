// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

/// Account-local visibility, independent of the SDK's evictable timeline.
/// Records stay intact so unblocking can reveal cached history again.
enum IgnoredContentStore {
    static let didChange = Notification.Name("ZynaIgnoredContentDidChange")
    static let visibleSQL = "senderId NOT IN (SELECT userId FROM ignoredUser)"

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE ignoredUser (userId TEXT PRIMARY KEY NOT NULL);
            ALTER TABLE storedRoom ADD COLUMN lastMessageSenderID TEXT;
            ALTER TABLE storedSpaceChild ADD COLUMN lastMessageSenderID TEXT;
            -- Legacy summaries have no author identity. Drop only their
            -- preview; the next SDK snapshot restores an attributable one.
            UPDATE storedRoom SET lastMessage = NULL, lastMessageSenderName = NULL;
            UPDATE storedSpaceChild SET lastMessage = NULL, lastMessageSenderName = NULL;
            DROP INDEX idx_roomAttachment_visual_order;
            CREATE INDEX idx_roomAttachment_visual_order
                ON roomAttachment(roomId, timestampMs DESC, eventId DESC, kind, senderId)
                WHERE kind IN ('image', 'video');
            """)
    }

    static func userIDs(in db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT userId FROM ignoredUser"))
    }

    static func contains(_ userID: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ignoredUser WHERE userId = ?)",
                          arguments: [userID]) ?? false
    }

    @discardableResult
    static func replace(_ ids: Set<String>, in db: Database) throws -> Bool {
        let old = try userIDs(in: db)
        guard old != ids else { return false }
        for id in old.subtracting(ids) {
            try db.execute(sql: "DELETE FROM ignoredUser WHERE userId = ?", arguments: [id])
        }
        for id in ids.subtracting(old) {
            try db.execute(sql: "INSERT INTO ignoredUser (userId) VALUES (?)", arguments: [id])
        }
        // Invalidate both payload pages and compact order/count snapshots.
        // Only per-room metadata is touched; no media payload scan or rewrite.
        try db.execute(sql: "UPDATE roomAttachmentRevision SET revision = revision + 1, orderRevision = orderRevision + 1")
        try RoomAttachmentListStore.refreshVisibility(db)
        return true
    }
}

extension StoredMessage {
    func hidingIgnoredReply(_ ids: Set<String>) -> Self {
        guard let replySenderId, ids.contains(replySenderId) else { return self }
        var value = self
        value.replyEventId = nil
        value.replySenderId = nil
        value.replySenderName = nil
        value.replyBody = nil
        return value
    }

    static var visible: QueryInterfaceRequest<StoredMessage> {
        all().filter(sql: IgnoredContentStore.visibleSQL)
    }
}
