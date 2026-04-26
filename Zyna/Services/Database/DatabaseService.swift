//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import Foundation

final class DatabaseService {

    static let shared = DatabaseService()

    let dbQueue: DatabaseQueue

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("zyna", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbURL = dir.appendingPathComponent("zyna.db")
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try! DatabaseQueue(path: dbURL.path, configuration: config)
        try! migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.eraseDatabaseOnSchemaChange = true

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "storedMessage") { t in
                t.primaryKey("id", .text)
                t.column("roomId", .text).notNull()
                t.column("eventId", .text)
                t.column("transactionId", .text)
                t.column("senderId", .text).notNull()
                t.column("senderDisplayName", .text)
                t.column("isOutgoing", .boolean).notNull()
                t.column("timestamp", .double).notNull()
                t.column("contentType", .text).notNull()
                t.column("contentBody", .text)
                t.column("contentMediaJSON", .text)
                t.column("contentImageWidth", .integer)
                t.column("contentImageHeight", .integer)
                t.column("contentCaption", .text)
                t.column("contentVoiceDuration", .double)
                t.column("contentVoiceWaveform", .blob)
                t.column("reactionsJSON", .text).notNull().defaults(to: "[]")
                t.column("sendStatus", .text).notNull().defaults(to: "synced")
                t.column("replyEventId", .text)
                t.column("replySenderId", .text)
                t.column("replySenderName", .text)
                t.column("replyBody", .text)
            }

            try db.create(
                index: "idx_storedMessage_room_timestamp",
                on: "storedMessage",
                columns: ["roomId", "timestamp"]
            )
            try db.create(
                index: "idx_storedMessage_eventId",
                on: "storedMessage",
                columns: ["roomId", "eventId"],
                unique: true,
                condition: Column("eventId") != nil
            )
            try db.create(
                index: "idx_storedMessage_transactionId",
                on: "storedMessage",
                columns: ["transactionId"],
                condition: Column("transactionId") != nil
            )

            try db.create(table: "storedRoom") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text).notNull()
                t.column("avatarURL", .text)
                t.column("lastMessage", .text)
                t.column("lastMessageTimestamp", .double)
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("unreadMentionCount", .integer).notNull().defaults(to: 0)
                t.column("isMarkedUnread", .boolean).notNull().defaults(to: false)
                t.column("isEncrypted", .boolean).notNull().defaults(to: false)
                t.column("directUserId", .text)
                t.column("sortOrder", .integer).notNull()
            }

            try db.create(
                index: "idx_storedRoom_sortOrder",
                on: "storedRoom",
                columns: ["sortOrder"]
            )
        }

        migrator.registerMigration("v2_zynaAttributes") { db in
            try db.alter(table: "storedMessage") { t in
                t.add(column: "zynaAttributesJSON", .text)
            }
        }

        migrator.registerMigration("v3_fileSupport") { db in
            try db.alter(table: "storedMessage") { t in
                t.add(column: "contentFilename", .text)
                t.add(column: "contentMimetype", .text)
                t.add(column: "contentFileSize", .integer)
            }
        }

        migrator.registerMigration("v4_senderAvatar") { db in
            try db.alter(table: "storedMessage") { t in
                t.add(column: "senderAvatarUrl", .text)
            }
        }

        migrator.registerMigration("v5_outgoingEnvelopes") { db in
            try db.create(table: "pendingMediaGroup") { t in
                t.primaryKey("id", .text)
                t.column("roomId", .text).notNull()
                t.column("caption", .text)
                t.column("captionPlacement", .text).notNull()
                t.column("expectedItemCount", .integer).notNull()
                t.column("createdAt", .double).notNull()
                t.column("replyEventId", .text)
                t.column("replySenderId", .text)
                t.column("replySenderName", .text)
                t.column("replyBody", .text)
                t.column("kind", .text)
                t.column("state", .text)
                t.column("payloadJSON", .text)
                t.column("zynaAttributesJSON", .text)
            }

            try db.create(
                index: "idx_pendingMediaGroup_room_createdAt",
                on: "pendingMediaGroup",
                columns: ["roomId", "createdAt"]
            )

            try db.create(table: "pendingMediaGroupItem") { t in
                t.primaryKey("id", .text)
                t.column("groupId", .text)
                    .notNull()
                    .indexed()
                    .references("pendingMediaGroup", onDelete: .cascade)
                t.column("itemIndex", .integer).notNull()
                t.column("bindingToken", .text)
                t.column("transactionId", .text)
                t.column("eventId", .text)
                t.column("mediaSourceJSON", .text)
                t.column("previewImageData", .blob)
                t.column("previewWidth", .integer)
                t.column("previewHeight", .integer)
                t.column("transportState", .text)
            }

            try db.create(
                index: "idx_pendingMediaGroupItem_group_index",
                on: "pendingMediaGroupItem",
                columns: ["groupId", "itemIndex"],
                unique: true
            )
            try db.create(
                index: "idx_pendingMediaGroupItem_bindingToken",
                on: "pendingMediaGroupItem",
                columns: ["bindingToken"],
                unique: true,
                condition: Column("bindingToken") != nil
            )
            try db.create(
                index: "idx_pendingMediaGroupItem_transactionId",
                on: "pendingMediaGroupItem",
                columns: ["transactionId"],
                unique: true,
                condition: Column("transactionId") != nil
            )
            try db.create(
                index: "idx_pendingMediaGroupItem_eventId",
                on: "pendingMediaGroupItem",
                columns: ["eventId"],
                unique: true,
                condition: Column("eventId") != nil
            )

            // Legacy physical table names are preserved to avoid
            // unnecessary churn while the logical model has evolved
            // from pending media groups into generic outgoing envelopes.
            // TODO: After the planned homeserver / account reset, when
            // backward compatibility with existing local databases no
            // longer matters, rename these tables to match the logical
            // outgoing envelope model.
        }

        migrator.registerMigration("v6_roomUnreadPresentation") { db in
            let existingColumns = try db.columns(in: "storedRoom").map(\.name)

            if !existingColumns.contains("unreadMentionCount") {
                try db.alter(table: "storedRoom") { t in
                    t.add(column: "unreadMentionCount", .integer).notNull().defaults(to: 0)
                }
            }

            if !existingColumns.contains("isMarkedUnread") {
                try db.alter(table: "storedRoom") { t in
                    t.add(column: "isMarkedUnread", .boolean).notNull().defaults(to: false)
                }
            }
        }

        migrator.registerMigration("v7_pendingRedactions") { db in
            try db.create(table: "pendingRedaction") { t in
                t.primaryKey("messageId", .text)
                t.column("roomId", .text).notNull()
                t.column("createdAt", .double).notNull()
            }

            try db.create(
                index: "idx_pendingRedaction_room_createdAt",
                on: "pendingRedaction",
                columns: ["roomId", "createdAt"]
            )
        }

        migrator.registerMigration("v8_pendingRedactionRetryMetadata") { db in
            let existingColumns = try db.columns(in: "pendingRedaction").map(\.name)

            if !existingColumns.contains("identifierKind") {
                try db.alter(table: "pendingRedaction") { t in
                    t.add(column: "identifierKind", .text)
                }
            }

            if !existingColumns.contains("identifierValue") {
                try db.alter(table: "pendingRedaction") { t in
                    t.add(column: "identifierValue", .text)
                }
            }

            if !existingColumns.contains("lastAttemptAt") {
                try db.alter(table: "pendingRedaction") { t in
                    t.add(column: "lastAttemptAt", .double)
                }
            }

            if !existingColumns.contains("attemptCount") {
                try db.alter(table: "pendingRedaction") { t in
                    t.add(column: "attemptCount", .integer).notNull().defaults(to: 0)
                }
            }

            try db.execute(
                sql: """
                    UPDATE pendingRedaction
                    SET identifierKind = CASE
                            WHEN (
                                SELECT eventId
                                FROM storedMessage
                                WHERE storedMessage.id = pendingRedaction.messageId
                            ) IS NOT NULL THEN 'eventId'
                            WHEN (
                                SELECT transactionId
                                FROM storedMessage
                                WHERE storedMessage.id = pendingRedaction.messageId
                            ) IS NOT NULL THEN 'transactionId'
                            ELSE identifierKind
                        END,
                        identifierValue = COALESCE(
                            (
                                SELECT eventId
                                FROM storedMessage
                                WHERE storedMessage.id = pendingRedaction.messageId
                            ),
                            (
                                SELECT transactionId
                                FROM storedMessage
                                WHERE storedMessage.id = pendingRedaction.messageId
                            ),
                            identifierValue
                        )
                    WHERE identifierValue IS NULL
                    """
            )
        }

        return migrator
    }
}
