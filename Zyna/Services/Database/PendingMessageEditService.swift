//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

private let logPendingMessageEdit = ScopedLog(.timeline, prefix: "[MessageEdit]")

struct PendingMessageEditSnapshot {
    let roomId: String
    let eventId: String
    let transactionId: String
    let body: String
    let formattedBody: String?
    let zynaAttributes: ZynaMessageAttributes
}

final class PendingMessageEditService {

    static let shared = PendingMessageEditService()

    private let database: DatabaseQueue?
    private var dbQueue: DatabaseQueue { database ?? DatabaseService.shared.dbQueue }

    init(database: DatabaseQueue? = nil) { self.database = database }

    func prepareDirectRawEdit(
        roomId: String,
        eventId: String,
        body: String,
        formattedBody: String? = nil,
        zynaAttributes: ZynaMessageAttributes,
        transactionId: String
    ) -> Bool {
        let didChange = (try? dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE storedMessage
                    SET isEditPending = 1,
                        isEditFailed = 0,
                        editTransactionId = ?,
                        pendingEditBody = ?,
                        pendingEditFormattedBody = ?,
                        pendingEditZynaAttributesJSON = ?
                    WHERE roomId = ?
                      AND eventId = ?
                      AND isOutgoing = 1
                      AND contentType = 'text'
                    """,
                arguments: [
                    transactionId,
                    body,
                    formattedBody,
                    StoredMessage.encodeZynaAttributes(zynaAttributes),
                    roomId,
                    eventId
                ]
            )
            return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
        }) ?? false
        if didChange {
            logPendingMessageEdit("direct pending event=\(eventId) tx=\(transactionId)")
        }
        return didChange
    }

    func pendingDirectRawEdits(
        roomId: String? = nil,
        eventId: String? = nil
    ) -> [PendingMessageEditSnapshot] {
        (try? dbQueue.read { db in
            var sql = """
                SELECT roomId, eventId, editTransactionId,
                       pendingEditBody, pendingEditFormattedBody, pendingEditZynaAttributesJSON
                FROM storedMessage
                WHERE isEditPending = 1
                  AND editTransactionId IS NOT NULL
                  AND editTransactionId != ''
                  AND pendingEditBody IS NOT NULL
                  AND eventId IS NOT NULL
                  AND eventId != ''
                """
            var arguments: StatementArguments = []
            if let roomId {
                sql += " AND roomId = ?"
                arguments += [roomId]
            }
            if let eventId {
                sql += " AND eventId = ?"
                arguments += [eventId]
            }
            sql += " ORDER BY timestamp ASC"

            return try PendingMessageEditRow
                .fetchAll(db, sql: sql, arguments: arguments)
                .compactMap(\.snapshot)
        }) ?? []
    }

    func applyAcceptedDirectRawEdit(
        roomId: String,
        eventId: String,
        transactionId: String,
        editEventId: String,
        body: String,
        formattedBody: String? = nil,
        zynaAttributes: ZynaMessageAttributes
    ) -> Bool {
        let didChange = (try? dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE storedMessage
                    SET contentBody = ?,
                        contentFormat = ?,
                        contentFormattedBody = ?,
                        zynaAttributesJSON = ?,
                        isEdited = 1,
                        isEditPending = 0,
                        isEditFailed = 0,
                        latestEditEventId = ?,
                        editTransactionId = NULL,
                        pendingEditBody = NULL,
                        pendingEditFormattedBody = NULL,
                        pendingEditZynaAttributesJSON = NULL
                    WHERE roomId = ?
                      AND eventId = ?
                      AND editTransactionId = ?
                      AND contentType = 'text'
                    """,
                arguments: [
                    body,
                    formattedBody == nil ? nil : ChatTextMetadata.matrixHTMLFormat,
                    formattedBody,
                    StoredMessage.encodeZynaAttributes(zynaAttributes),
                    editEventId,
                    roomId,
                    eventId,
                    transactionId
                ]
            )
            return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
        }) ?? false
        if didChange {
            logPendingMessageEdit(
                "direct accepted event=\(eventId) edit=\(editEventId) tx=\(transactionId)"
            )
        }
        return didChange
    }

    func markDirectRawEditFailed(
        roomId: String,
        eventId: String,
        transactionId: String
    ) -> Bool {
        let didChange = (try? dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE storedMessage
                    SET isEditPending = 0,
                        isEditFailed = 1,
                        editTransactionId = NULL,
                        pendingEditBody = NULL,
                        pendingEditFormattedBody = NULL,
                        pendingEditZynaAttributesJSON = NULL
                    WHERE roomId = ?
                      AND eventId = ?
                      AND editTransactionId = ?
                    """,
                arguments: [roomId, eventId, transactionId]
            )
            return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
        }) ?? false
        if didChange {
            logPendingMessageEdit("direct failed event=\(eventId) tx=\(transactionId)")
        }
        return didChange
    }
}

private struct PendingMessageEditRow: Decodable, FetchableRecord {
    let roomId: String
    let eventId: String?
    let editTransactionId: String?
    let pendingEditBody: String?
    let pendingEditFormattedBody: String?
    let pendingEditZynaAttributesJSON: String?

    var snapshot: PendingMessageEditSnapshot? {
        guard let eventId,
              !eventId.isEmpty,
              let editTransactionId,
              !editTransactionId.isEmpty,
              let pendingEditBody else {
            return nil
        }
        return PendingMessageEditSnapshot(
            roomId: roomId,
            eventId: eventId,
            transactionId: editTransactionId,
            body: pendingEditBody,
            formattedBody: pendingEditFormattedBody,
            zynaAttributes: StoredMessage.decodeZynaAttributes(pendingEditZynaAttributesJSON)
        )
    }
}
