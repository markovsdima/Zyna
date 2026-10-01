// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Media catalog migration")
struct RoomMediaMigrationTests {
    @Test("The merged migration preserves attachments from every development schema", arguments: [31, 32, 33, 34])
    func upgrade(from version: Int) async throws {
        try await Task.detached {
            let queue = try DatabaseQueue()
            defer { try? queue.close() }
            let migrator = DatabaseService.migrator
            try migrator.migrate(queue, upTo: "v31_decryptionPresentation")
            if version > 31 {
                let identifier = ["v32_roomMediaPaging", "v33_roomMediaOrderRevision", "v34_roomMediaCoveringIndex"][version - 32]
                try Self.developmentMigrator.migrate(queue, upTo: identifier)
            }
            try queue.write { db in
                for (index, kind) in ["image", "video", "file"].enumerated() {
                    try db.execute(sql: """
                        INSERT INTO roomAttachment
                            (roomId, eventId, kind, timestampMs, senderId, isOutgoing, filename, caption, sourceJSON)
                        VALUES ('!migration:example.org', ?, ?, ?, '@alice:example.org', 0, 'attachment', 'preserve me', '{}')
                        """, arguments: ["$event\(index)", kind, 1_790_784_000_000 + index])
                }
            }
            let before = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM roomAttachment ORDER BY eventId") }
            try migrator.migrate(queue)
            try queue.write { db in
                #expect(try Row.fetchAll(db, sql: "SELECT * FROM roomAttachment ORDER BY eventId") == before)
                #expect(try migrator.appliedIdentifiers(db) == Set(migrator.migrations))
                #expect(migrator.migrations.last == "v32_roomMediaCatalog")
                #expect(try !migrator.hasBeenSuperseded(db))
                let columns = try Row.fetchAll(db, sql: "PRAGMA index_info(idx_roomAttachment_visual_order)")
                #expect(columns.map { $0["name"] as String } == ["roomId", "timestampMs", "eventId", "kind"])
                // Fresh counters must track writes to the preserved catalog.
                try db.execute(sql: """
                    INSERT INTO roomAttachment
                        (roomId, eventId, kind, timestampMs, senderId, isOutgoing, filename, sourceJSON)
                    VALUES ('!migration:example.org', '$new', 'image', 1790784000010, '@alice:example.org', 0, 'new', '{}')
                    """)
                try db.execute(sql: "UPDATE roomAttachment SET caption = 'edited' WHERE eventId = '$new'")
                #expect(try Int.fetchOne(db, sql: "SELECT revision FROM roomAttachmentRevision") == 2)
                #expect(try Int.fetchOne(db, sql: "SELECT orderRevision FROM roomAttachmentRevision") == 1)
                try db.execute(sql: "UPDATE roomAttachment SET timestampMs = timestampMs + 1 WHERE eventId = '$new'")
                try db.execute(sql: "DELETE FROM roomAttachment WHERE eventId = '$new'")
                #expect(try Int.fetchOne(db, sql: "SELECT revision FROM roomAttachmentRevision") == 4)
                #expect(try Int.fetchOne(db, sql: "SELECT orderRevision FROM roomAttachmentRevision") == 3)
            }
            // Reopening an already merged database must not reset counters.
            try migrator.migrate(queue)
            try queue.read { db throws -> Void in
                #expect(try Row.fetchAll(db, sql: "SELECT * FROM roomAttachment ORDER BY eventId") == before)
                #expect(try Int.fetchOne(db, sql: "SELECT revision FROM roomAttachmentRevision") == 4)
                #expect(try Int.fetchOne(db, sql: "SELECT orderRevision FROM roomAttachmentRevision") == 3)
            }
        }.value
    }

    // Frozen schemas from the unpublished development builds. Do not use the
    // current migration here: these fixtures must catch upgrade regressions.
    private static var developmentMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v32_roomMediaPaging") { db in
            try db.execute(sql: """
                CREATE TABLE roomAttachmentRevision (roomId TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL);
                CREATE INDEX idx_roomAttachment_visual_order ON roomAttachment(roomId, timestampMs DESC, eventId DESC)
                    WHERE kind IN ('image', 'video');
                CREATE TRIGGER roomAttachmentRevisionInsert AFTER INSERT ON roomAttachment WHEN NEW.kind IN ('image', 'video') BEGIN
                    INSERT INTO roomAttachmentRevision VALUES (NEW.roomId, 1)
                    ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER roomAttachmentRevisionUpdate AFTER UPDATE ON roomAttachment
                    WHEN NEW.kind IN ('image', 'video') OR OLD.kind IN ('image', 'video') BEGIN
                    INSERT INTO roomAttachmentRevision VALUES (NEW.roomId, 1)
                    ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER roomAttachmentRevisionDelete AFTER DELETE ON roomAttachment WHEN OLD.kind IN ('image', 'video') BEGIN
                    INSERT INTO roomAttachmentRevision VALUES (OLD.roomId, 1)
                    ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1;
                END;
                """)
        }
        migrator.registerMigration("v33_roomMediaOrderRevision") { db in
            try db.execute(sql: """
                ALTER TABLE roomAttachmentRevision ADD COLUMN orderRevision INTEGER NOT NULL DEFAULT 0;
                DROP TRIGGER roomAttachmentRevisionInsert;
                DROP TRIGGER roomAttachmentRevisionUpdate;
                DROP TRIGGER roomAttachmentRevisionDelete;
                CREATE TRIGGER roomAttachmentRevisionInsert AFTER INSERT ON roomAttachment WHEN NEW.kind IN ('image', 'video') BEGIN
                    INSERT INTO roomAttachmentRevision (roomId, revision, orderRevision) VALUES (NEW.roomId, 1, 1)
                    ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1, orderRevision = orderRevision + 1;
                END;
                CREATE TRIGGER roomAttachmentRevisionUpdate AFTER UPDATE ON roomAttachment
                    WHEN NEW.kind IN ('image', 'video') OR OLD.kind IN ('image', 'video') BEGIN
                    INSERT INTO roomAttachmentRevision (roomId, revision, orderRevision) VALUES (NEW.roomId, 1, 1)
                    ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1,
                        orderRevision = orderRevision + CASE WHEN NEW.kind != OLD.kind OR NEW.timestampMs != OLD.timestampMs
                            OR NEW.eventId != OLD.eventId THEN 1 ELSE 0 END;
                END;
                CREATE TRIGGER roomAttachmentRevisionDelete AFTER DELETE ON roomAttachment WHEN OLD.kind IN ('image', 'video') BEGIN
                    INSERT INTO roomAttachmentRevision (roomId, revision, orderRevision) VALUES (OLD.roomId, 1, 1)
                    ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1, orderRevision = orderRevision + 1;
                END;
                """)
        }
        migrator.registerMigration("v34_roomMediaCoveringIndex") { db in
            try db.execute(sql: """
                DROP INDEX idx_roomAttachment_visual_order;
                CREATE INDEX idx_roomAttachment_visual_order ON roomAttachment(roomId, timestampMs DESC, eventId DESC, kind)
                    WHERE kind IN ('image', 'video');
                """)
        }
        return migrator
    }
}
