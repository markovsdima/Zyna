//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Read in the same transaction as the messages. Preparing a presentation
/// never consumes an outbox confirmation or retires an envelope.
struct ChatTimelineLocalState {
    var ignoredUserIDs: Set<String> = []
    var redactions: [PendingRedactionRecord] = []
    var resolvedRedactions = PendingRedactionService.ResolvedPendingRedactions(messageIds: [], identityKeys: [])
    var reactionRemovals: [String: Set<String>] = [:]
    var envelopeRecords: [OutgoingEnvelopeRecord] = []
    var envelopeItems: [OutgoingEnvelopeItemRecord] = []

    var envelopes: [OutgoingEnvelopeSnapshot] {
        let items = Dictionary(grouping: envelopeItems, by: \.groupId)
        return envelopeRecords.map { .init(record: $0, items: items[$0.id] ?? []) }
    }

    static func fetch(roomId: String, window: [StoredMessage], in db: Database) throws -> Self {
        let redactions = try PendingRedactionRecord.filter(Column("roomId") == roomId)
            .order(Column("createdAt").asc).fetchAll(db)
        let resolved = redactions.isEmpty
            ? PendingRedactionService.ResolvedPendingRedactions(messageIds: [], identityKeys: [])
            : try PendingRedactionService.resolvedPendingRedactions(roomId: roomId, in: db)
        // Sent envelopes may survive until their remote echoes enter an
        // accepted presentation. Keep their previews on disk while all of
        // those echoes are outside this window. This is presentation scoping,
        // not acknowledgement: incomplete hydration and album metadata are
        // still checked by the renderer before anything can be retired.
        // Unfinished sends and sends not yet observed in the DB remain visible.
        let eventIDs = window.compactMap(\.eventId)
        let transactionIDs = window.compactMap(\.transactionId)
        let envelopes = try SQLRequest<OutgoingEnvelopeRecord>(literal: """
            SELECT envelope.* FROM pendingMediaGroup AS envelope
            WHERE envelope.roomId = \(roomId) AND (
                envelope.state IS NOT 'sent'
                OR envelope.expectedItemCount < 1
                OR (SELECT COUNT(*) FROM pendingMediaGroupItem AS item
                    WHERE item.groupId = envelope.id) != envelope.expectedItemCount
                OR EXISTS (
                    SELECT 1 FROM pendingMediaGroupItem AS item
                    WHERE item.groupId = envelope.id AND (
                        COALESCE(item.transportState,
                            CASE WHEN item.eventId IS NOT NULL THEN 'sent' ELSE 'queued' END) != 'sent'
                        OR item.eventId IN \(eventIDs)
                        OR item.transactionId IN \(transactionIDs)
                        OR (NOT EXISTS (
                            SELECT 1 FROM storedMessage AS message
                            WHERE message.roomId = envelope.roomId AND message.isOutgoing = 1
                                AND message.eventId = item.eventId
                        ) AND NOT EXISTS (
                            SELECT 1 FROM storedMessage AS message
                            WHERE message.roomId = envelope.roomId AND message.isOutgoing = 1
                                AND message.eventId IS NOT NULL
                                AND message.transactionId = item.transactionId
                        ))
                    )
                )
            ) ORDER BY envelope.createdAt DESC
            """).fetchAll(db)
        let ids = envelopes.map(\.id)
        let items = ids.isEmpty ? [] : try OutgoingEnvelopeItemRecord
            .filter(ids.contains(Column("groupId"))).order(Column("itemIndex").asc).fetchAll(db)
        return Self(ignoredUserIDs: try IgnoredContentStore.userIDs(in: db),
                    redactions: redactions, resolvedRedactions: resolved,
                    reactionRemovals: try PendingReactionService.pendingRemovalKeysByEventId(roomId: roomId, in: db),
                    envelopeRecords: envelopes, envelopeItems: items)
    }

    /// Run only after the UI accepted this snapshot. Compare records again
    /// so delayed cleanup cannot consume a newer attempt. File paths belong
    /// to the captured account, even if another account has since logged in.
    func acknowledge(roomId: String, retiring ids: Set<String>, database: AccountDatabase, userId: String?) throws {
        guard !resolvedRedactions.messageIds.isEmpty || !ids.isEmpty else { return }
        let files: [URL] = try database.write { db in
            if !resolvedRedactions.messageIds.isEmpty {
                let stillResolved = try PendingRedactionService.resolvedPendingRedactions(roomId: roomId, in: db)
                for record in redactions where resolvedRedactions.messageIds.contains(record.messageId)
                    && stillResolved.messageIds.contains(record.messageId) {
                    if try PendingRedactionRecord.fetchOne(db, key: record.messageId) == record {
                        _ = try record.delete(db)
                    }
                }
            }
            var files: [URL] = []
            for record in envelopeRecords where ids.contains(record.id) {
                guard try OutgoingEnvelopeRecord.fetchOne(db, key: record.id) == record else { continue }
                let items = try OutgoingEnvelopeItemRecord.filter(Column("groupId") == record.id)
                    .order(Column("itemIndex").asc).fetchAll(db)
                guard items == envelopeItems.filter({ $0.groupId == record.id }) else { continue }
                let images = try PendingDirectImageRecord.filter(Column("envelopeId") == record.id).fetchAll(db)
                let videos = try PendingDirectVideoRecord.filter(Column("envelopeId") == record.id).fetchAll(db)
                let documents = try PendingDirectFileRecord.filter(Column("envelopeId") == record.id).fetchAll(db)
                files += images.flatMap { [$0.originalFileName, $0.thumbnailFileName] }
                    .map { LocalDataProtection.outgoingImageDirectory(for: userId).appendingPathComponent($0) }
                files += videos.flatMap { [$0.originalFileName, $0.thumbnailFileName] }
                    .map { LocalDataProtection.outgoingVideoDirectory(for: userId).appendingPathComponent($0) }
                files += documents.map {
                    LocalDataProtection.outgoingFileDirectory(for: userId).appendingPathComponent($0.storageDirectoryName)
                }
                if case .voice(let payload) = record.payload, let name = payload.localFileName {
                    files.append(LocalDataProtection.outgoingVoiceDirectory(for: userId).appendingPathComponent(name))
                }
                _ = try record.delete(db)
            }
            return files
        }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
