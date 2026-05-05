//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Counts local cache changes made by `TimelineRepairService`.
struct TimelineRepairResult {
    var updatedMessages = 0
    var deletedLocalMessages = 0
    var updatedEnvelopeItems = 0
    var retiredEnvelopes = 0

    var didChange: Bool {
        updatedMessages > 0
            || deletedLocalMessages > 0
            || updatedEnvelopeItems > 0
            || retiredEnvelopes > 0
    }
}

/// Local diagnostic maintenance tool for normalizing persisted timeline rows.
///
/// This is a manual repair path for TestFlight/local cache recovery, not part
/// of the normal message sync pipeline. It never redacts or deletes Matrix
/// events on the server; deletions are limited to local duplicate/orphan
/// `storedMessage` rows.
final class TimelineRepairService {

    static let shared = TimelineRepairService(dbQueue: DatabaseService.shared.dbQueue)

    private let dbQueue: DatabaseQueue
    private let log = ScopedLog(.database, prefix: "[TimelineRepair]")

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func repairLocalTimelineCache() throws -> TimelineRepairResult {
        var result = TimelineRepairResult()
        try dbQueue.write { db in
            try repairOutgoingMediaBatchEnvelopes(in: db, result: &result)
            try repairGroupedMessageDuplicates(in: db, result: &result)
            try repairLegacyTransactionIdOrphans(in: db, result: &result)
        }
        log(
            "done updatedMessages=\(result.updatedMessages) deletedLocal=\(result.deletedLocalMessages) updatedItems=\(result.updatedEnvelopeItems) retiredEnvelopes=\(result.retiredEnvelopes)"
        )
        return result
    }

    private func repairOutgoingMediaBatchEnvelopes(
        in db: Database,
        result: inout TimelineRepairResult
    ) throws {
        let envelopes = try OutgoingEnvelopeRecord.fetchAll(
            db,
            sql: """
                SELECT *
                FROM pendingMediaGroup
                WHERE ifnull(kind, 'mediaBatch') = 'mediaBatch'
                ORDER BY createdAt DESC
                """
        )

        for envelope in envelopes {
            var items = try OutgoingEnvelopeItemRecord
                .filter(Column("groupId") == envelope.id)
                .order(Column("itemIndex").asc)
                .fetchAll(db)

            for index in items.indices {
                var item = items[index]

                if item.eventId == nil,
                   let transactionId = item.transactionId,
                   let eventId = try eventIdForTransaction(
                    transactionId,
                    roomId: envelope.roomId,
                    in: db
                   ) {
                    item.eventId = eventId
                    try item.save(db)
                    items[index] = item
                    result.updatedEnvelopeItems += 1
                }

                if let eventId = item.eventId {
                    let updated = try repairEventBackedMediaGroupMessage(
                        roomId: envelope.roomId,
                        eventId: eventId,
                        transactionId: item.transactionId,
                        groupInfo: mediaGroupInfo(for: envelope, itemIndex: item.itemIndex),
                        in: db
                    )
                    result.updatedMessages += updated
                }

                if let eventId = item.eventId,
                   let transactionId = item.transactionId {
                    result.deletedLocalMessages += try deleteLocalTransactionDuplicate(
                        roomId: envelope.roomId,
                        transactionId: transactionId,
                        eventId: eventId,
                        in: db
                    )
                }
            }

            let canRetire = try isFullyHydrated(
                envelope: envelope,
                items: items,
                in: db
            )
            if canRetire {
                _ = try OutgoingEnvelopeRecord.deleteOne(db, key: envelope.id)
                result.retiredEnvelopes += 1
            }
        }
    }

    private func repairGroupedMessageDuplicates(
        in db: Database,
        result: inout TimelineRepairResult
    ) throws {
        let groupedMessages = try StoredMessage.fetchAll(
            db,
            sql: """
                SELECT *
                FROM storedMessage
                WHERE contentType = 'image'
                  AND eventId IS NOT NULL
                  AND zynaAttributesJSON IS NOT NULL
                """
        )

        for anchor in groupedMessages {
            guard let groupInfo = mediaGroupInfo(from: anchor) else { continue }
            result.deletedLocalMessages += try deleteLocalImageDuplicates(
                matching: anchor,
                groupInfo: groupInfo,
                in: db
            )
        }
    }

    private func repairLegacyTransactionIdOrphans(
        in db: Database,
        result: inout TimelineRepairResult
    ) throws {
        let anchors = try StoredMessage.fetchAll(
            db,
            sql: """
                SELECT *
                FROM storedMessage
                WHERE eventId IS NOT NULL
                  AND transactionId IS NOT NULL
                """
        )

        for anchor in anchors {
            guard let transactionId = anchor.transactionId,
                  !transactionId.isEmpty
            else {
                continue
            }
            let legacyId = StoredMessage.storageId(
                roomId: anchor.roomId,
                eventId: nil,
                transactionId: transactionId,
                localId: transactionId
            )
            guard let orphan = try StoredMessage
                .filter(Column("id") == legacyId)
                .fetchOne(db),
                  orphan.eventId == nil,
                  orphan.transactionId == nil,
                  isSafeLegacyTransactionOrphan(orphan, anchor: anchor)
            else {
                continue
            }

            _ = try StoredMessage.deleteOne(db, key: orphan.id)
            result.deletedLocalMessages += 1
            log(
                "delete legacy tx orphan id=\(short(orphan.id)) anchor=\(short(anchor.id)) event=\(short(anchor.eventId)) tx=\(short(transactionId))"
            )
        }
    }

    private func repairEventBackedMediaGroupMessage(
        roomId: String,
        eventId: String,
        transactionId: String?,
        groupInfo: MediaGroupInfo,
        in db: Database
    ) throws -> Int {
        guard var message = try StoredMessage
            .filter(Column("roomId") == roomId && Column("eventId") == eventId)
            .fetchOne(db),
              message.contentType == "image"
        else {
            return 0
        }

        var didChange = false
        var attrs = StoredMessage.decodeZynaAttributes(message.zynaAttributesJSON)
        if attrs.mediaGroup != groupInfo {
            attrs.mediaGroup = groupInfo
            message.zynaAttributesJSON = StoredMessage.encodeZynaAttributes(attrs)
            didChange = true
        }
        if message.transactionId == nil,
           let transactionId,
           !transactionId.isEmpty {
            message.transactionId = transactionId
            didChange = true
        }

        guard didChange else { return 0 }
        try message.save(db)
        return 1
    }

    private func deleteLocalTransactionDuplicate(
        roomId: String,
        transactionId: String,
        eventId: String,
        in db: Database
    ) throws -> Int {
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id
                FROM storedMessage
                WHERE roomId = ?
                  AND transactionId = ?
                  AND eventId IS NULL
                  AND contentType = 'image'
                """,
            arguments: [roomId, transactionId]
        )
        for id in ids {
            _ = try StoredMessage.deleteOne(db, key: id)
            log("delete local tx duplicate id=\(short(id)) event=\(short(eventId)) tx=\(short(transactionId))")
        }
        return ids.count
    }

    private func deleteLocalImageDuplicates(
        matching anchor: StoredMessage,
        groupInfo: MediaGroupInfo,
        in db: Database
    ) throws -> Int {
        let candidates = try StoredMessage.fetchAll(
            db,
            sql: """
                SELECT *
                FROM storedMessage
                WHERE roomId = ?
                  AND senderId = ?
                  AND contentType = 'image'
                  AND eventId IS NULL
                  AND id != ?
                  AND timestamp BETWEEN ? AND ?
                """,
            arguments: [
                anchor.roomId,
                anchor.senderId,
                anchor.id,
                anchor.timestamp - 600,
                anchor.timestamp + 600
            ]
        )

        var deleted = 0
        for candidate in candidates where isLocalDuplicate(
            candidate,
            of: anchor,
            groupInfo: groupInfo
        ) {
            _ = try StoredMessage.deleteOne(db, key: candidate.id)
            deleted += 1
            log("delete local duplicate id=\(short(candidate.id)) anchor=\(short(anchor.id)) group=\(groupInfo.id)#\(groupInfo.index)")
        }
        return deleted
    }

    private func isFullyHydrated(
        envelope: OutgoingEnvelopeRecord,
        items: [OutgoingEnvelopeItemRecord],
        in db: Database
    ) throws -> Bool {
        guard items.count == envelope.expectedItemCount,
              !items.isEmpty,
              items.allSatisfy({ $0.eventId?.isEmpty == false })
        else {
            return false
        }

        for item in items {
            guard let eventId = item.eventId,
                  let message = try StoredMessage
                .filter(Column("roomId") == envelope.roomId && Column("eventId") == eventId)
                .fetchOne(db),
                  message.contentType == "image",
                  mediaGroupInfo(from: message) == mediaGroupInfo(
                    for: envelope,
                    itemIndex: item.itemIndex
                  )
            else {
                return false
            }
        }
        return true
    }

    private func isLocalDuplicate(
        _ candidate: StoredMessage,
        of anchor: StoredMessage,
        groupInfo: MediaGroupInfo
    ) -> Bool {
        if let candidateGroup = mediaGroupInfo(from: candidate) {
            return candidateGroup.id == groupInfo.id
                && candidateGroup.index == groupInfo.index
        }

        return normalizedCaption(candidate.contentCaption) == normalizedCaption(anchor.contentCaption)
            && dimensionsMatch(candidate.contentImageWidth, anchor.contentImageWidth)
            && dimensionsMatch(candidate.contentImageHeight, anchor.contentImageHeight)
    }

    private func isSafeLegacyTransactionOrphan(
        _ orphan: StoredMessage,
        anchor: StoredMessage
    ) -> Bool {
        guard orphan.roomId == anchor.roomId,
              orphan.senderId == anchor.senderId,
              orphan.eventId == nil,
              orphan.transactionId == nil,
              anchor.eventId?.isEmpty == false,
              anchor.transactionId?.isEmpty == false
        else {
            return false
        }

        if anchor.contentType == "redacted" {
            return true
        }

        guard orphan.contentType == anchor.contentType else {
            return false
        }
        if abs(orphan.timestamp - anchor.timestamp) <= 2 {
            return true
        }
        return normalizedCaption(orphan.contentCaption) == normalizedCaption(anchor.contentCaption)
            && dimensionsMatch(orphan.contentImageWidth, anchor.contentImageWidth)
            && dimensionsMatch(orphan.contentImageHeight, anchor.contentImageHeight)
    }

    private func eventIdForTransaction(
        _ transactionId: String,
        roomId: String,
        in db: Database
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
                SELECT eventId
                FROM storedMessage
                WHERE roomId = ?
                  AND transactionId = ?
                  AND eventId IS NOT NULL
                ORDER BY timestamp DESC
                LIMIT 1
                """,
            arguments: [roomId, transactionId]
        )
    }

    private func mediaGroupInfo(
        for envelope: OutgoingEnvelopeRecord,
        itemIndex: Int
    ) -> MediaGroupInfo {
        let payload = envelope.payload
        let layoutOverride: MediaGroupLayoutOverride?
        if case .mediaBatch(let batch) = payload {
            layoutOverride = batch.layoutOverride
        } else {
            layoutOverride = nil
        }

        return MediaGroupInfo(
            id: envelope.id,
            index: itemIndex,
            total: envelope.expectedItemCount,
            captionMode: .replicated,
            captionPlacement: CaptionPlacement(rawValue: envelope.captionPlacement) ?? .bottom,
            layoutOverride: layoutOverride
        )
    }

    private func mediaGroupInfo(from message: StoredMessage) -> MediaGroupInfo? {
        StoredMessage.decodeZynaAttributes(message.zynaAttributesJSON).mediaGroup
    }

    private func normalizedCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let normalized = caption
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func dimensionsMatch(_ lhs: Int64?, _ rhs: Int64?) -> Bool {
        lhs == nil || rhs == nil || lhs == rhs
    }

    private func short(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "-" }
        guard value.count > 22 else { return value }
        return "\(value.prefix(10))...\(value.suffix(8))"
    }
}
