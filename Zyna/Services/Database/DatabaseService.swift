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

        migrator.registerMigration("v1_storedMessage_v4") { db in
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
            }

            try db.create(
                index: "idx_storedMessage_room_timestamp",
                on: "storedMessage",
                columns: ["roomId", "timestamp"]
            )
            try db.create(
                index: "idx_storedMessage_eventId",
                on: "storedMessage",
                columns: ["eventId"],
                condition: Column("eventId") != nil
            )
            try db.create(
                index: "idx_storedMessage_transactionId",
                on: "storedMessage",
                columns: ["transactionId"],
                condition: Column("transactionId") != nil
            )
        }

        return migrator
    }
}
