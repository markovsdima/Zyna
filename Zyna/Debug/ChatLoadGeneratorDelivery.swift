// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG || CHAT_LIST_PLAYGROUND
import GRDB

enum ChatLoadGeneratorDelivery {
    /// Generator sends use the envelope ID as their Matrix transaction ID.
    /// The transaction survives both UI retirement and manual outbox retries.
    /// Read all candidates in one DB snapshot, using existing identity indexes.
    static func read(envelopeID: String, roomID: String, in db: Database) throws -> ChatLoadGenerator.Delivery {
        let original = try Row.fetchOne(db, sql: """
            SELECT item.eventId, item.transportState
            FROM pendingMediaGroupItem item
            JOIN pendingMediaGroup envelope ON envelope.id = item.groupId
            WHERE item.id = ? AND envelope.roomId = ?
            """, arguments: [OutgoingEnvelopeItemRecord.makeId(groupId: envelopeID, itemIndex: 0), roomID])
        // A manual text retry replaces the envelope, retaining the transaction.
        let item = try original ?? Row.fetchOne(db, sql: """
            SELECT item.eventId, item.transportState
            FROM pendingMediaGroupItem item
            JOIN pendingMediaGroup envelope ON envelope.id = item.groupId
            WHERE item.transactionId = ? AND envelope.roomId = ?
            """, arguments: [envelopeID, roomID])
        if let item, let _: String = item["eventId"] { return .sent }

        // Normal chat presentation can retire the envelope before the first
        // poll. A server echo is positive confirmation even after that cleanup.
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM storedMessage
                WHERE transactionId = ? AND roomId = ?
                    AND isOutgoing = 1 AND eventId IS NOT NULL
            )
            """, arguments: [envelopeID, roomID]) == true {
            return .sent
        }
        guard let item else {
            // Deletion alone is not success: the user may have discarded it.
            return .missing
        }
        let state: String? = item["transportState"]
        return state == OutgoingTransportState.failed.rawValue ? .failed : .waiting
    }
}
#endif
