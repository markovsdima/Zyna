// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import GRDB

enum RoomAttachmentListStore {
    static func refreshVisibility(_ db: Database) throws {
        for scope in [RoomAttachmentCatalogScope.files, .voice] {
            try db.execute(sql: """
                UPDATE roomAttachmentListRevision SET revision = revision + 1, orderRevision = orderRevision + 1,
                    count = (SELECT COUNT(*) FROM roomAttachment INDEXED BY \(scope.index)
                        WHERE roomAttachment.roomId = roomAttachmentListRevision.roomId
                        AND \(scope.predicate) AND \(IgnoredContentStore.visibleSQL))
                    WHERE section = ?
                """, arguments: [scope.rawValue])
        }
    }

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE roomAttachmentListRevision (
                roomId TEXT NOT NULL, section TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0,
                orderRevision INTEGER NOT NULL DEFAULT 0,
                count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (roomId, section)
            );
            """)
        for scope in [RoomAttachmentCatalogScope.files, .voice] {
            let name = scope.rawValue
            let predicate = scope.predicate
            let newPredicate = predicate.replacingOccurrences(of: "kind", with: "NEW.kind")
            let oldPredicate = predicate.replacingOccurrences(of: "kind", with: "OLD.kind")
            let newVisible = "(\(newPredicate)) AND NEW.senderId NOT IN (SELECT userId FROM ignoredUser)"
            let oldVisible = "(\(oldPredicate)) AND OLD.senderId NOT IN (SELECT userId FROM ignoredUser)"
            try db.execute(sql: """
                CREATE INDEX \(scope.index)
                    ON roomAttachment(roomId, timestampMs DESC, eventId DESC, kind, senderId)
                    WHERE \(predicate);
                INSERT INTO roomAttachmentListRevision (roomId, section, count)
                    SELECT roomId, '\(name)', SUM(senderId NOT IN (SELECT userId FROM ignoredUser))
                    FROM roomAttachment WHERE \(predicate) GROUP BY roomId;
                CREATE TRIGGER roomAttachment_\(name)_insert AFTER INSERT ON roomAttachment WHEN \(newPredicate) BEGIN
                    INSERT INTO roomAttachmentListRevision VALUES (NEW.roomId, '\(name)', 1, 1, \(newVisible))
                    ON CONFLICT(roomId, section) DO UPDATE SET revision = revision + 1, orderRevision = orderRevision + 1,
                        count = count + (\(newVisible));
                END;
                CREATE TRIGGER roomAttachment_\(name)_update AFTER UPDATE ON roomAttachment
                    WHEN \(newPredicate) OR \(oldPredicate) BEGIN
                    INSERT INTO roomAttachmentListRevision VALUES (NEW.roomId, '\(name)', 1, 1, \(newVisible))
                    ON CONFLICT(roomId, section) DO UPDATE SET revision = revision + 1,
                        count = count + (\(newVisible)) - (\(oldVisible)),
                        orderRevision = orderRevision + CASE
                            WHEN (\(newVisible)) != (\(oldVisible))
                                OR NEW.timestampMs != OLD.timestampMs OR NEW.eventId != OLD.eventId THEN 1 ELSE 0 END;
                END;
                CREATE TRIGGER roomAttachment_\(name)_delete AFTER DELETE ON roomAttachment WHEN \(oldPredicate) BEGIN
                    INSERT INTO roomAttachmentListRevision VALUES (OLD.roomId, '\(name)', 1, 1, 0)
                    ON CONFLICT(roomId, section) DO UPDATE SET revision = revision + 1, orderRevision = orderRevision + 1,
                        count = count - (\(oldVisible));
                END;
                """)
        }
    }
}
