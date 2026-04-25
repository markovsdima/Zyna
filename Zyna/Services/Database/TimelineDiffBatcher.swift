//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

private let logMediaGroup = ScopedLog(.media, prefix: "[MediaGroup]")

/// Accumulates SDK timeline diffs and flushes them to GRDB in a single
/// transaction after a 50 ms debounce window. Maintains a shadow
/// array for positional diff handling (SDK diffs reference items by index).
final class TimelineDiffBatcher {

    private let roomId: String
    private let dbQueue: DatabaseQueue
    private let log = ScopedLog(.database)
    private let writeQueue = DispatchQueue(label: "com.zyna.db.write", qos: .userInitiated)

    // MARK: - Shadow array

    /// Mirrors SDK timeline positions. Keeps just enough identity to
    /// stitch a local echo to the synced event that later replaces it.
    private struct ShadowItem {
        let storedId: String?
        let transactionId: String?
    }

    private var shadowItems: [ShadowItem] = []

    // MARK: - Pending ops

    private enum DiffOp {
        case upsert(StoredMessage)
        case delete(String)
    }

    private var pendingOps: [DiffOp] = []
    private var debounceWork: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.05

    /// Timestamp of the newest own message read by someone else.
    /// Updated from TimelineService when SDK delivers read receipts.
    private var readCursorTimestamp: TimeInterval?

    /// Called on main queue after each successful flush.
    var onFlush: (() -> Void)?

    // MARK: - Init

    init(roomId: String, dbQueue: DatabaseQueue) {
        self.roomId = roomId
        self.dbQueue = dbQueue
    }

    /// Update read cursor from SDK read receipts. Called from main queue.
    func updateReadCursor(timestamp: TimeInterval) {
        if readCursorTimestamp == nil || timestamp > readCursorTimestamp! {
            readCursorTimestamp = timestamp
            scheduleFlush()
        }
    }

    // MARK: - Public

    /// Called from the SDK listener thread with raw timeline diffs.
    func receive(diffs: [TimelineDiff]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let types = diffs.map { Self.diffName($0) }
            self.log("Received diffs: \(types.joined(separator: ", "))")
            for diff in diffs {
                self.enqueueDiff(diff)
            }
            self.scheduleFlush()
        }
    }

    private static func diffName(_ diff: TimelineDiff) -> String {
        switch diff {
        case .append(let items): return "append(\(items.count))"
        case .pushBack: return "pushBack"
        case .pushFront: return "pushFront"
        case .insert(let idx, _): return "insert(\(idx))"
        case .set(let idx, _): return "set(\(idx))"
        case .remove(let idx): return "remove(\(idx))"
        case .popBack: return "popBack"
        case .popFront: return "popFront"
        case .reset(let items): return "reset(\(items.count))"
        case .truncate(let len): return "truncate(\(len))"
        case .clear: return "clear"
        }
    }

    // MARK: - Debounce

    private func scheduleFlush() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    // MARK: - Flush

    private func flush() {
        let ops = pendingOps
        pendingOps.removeAll()
        let cursorTs = readCursorTimestamp
        readCursorTimestamp = nil

        guard !ops.isEmpty || cursorTs != nil else { return }

        let roomId = self.roomId
        let dbQueue = self.dbQueue

        writeQueue.async { [weak self] in
            do {
                try dbQueue.write { db in
                    // Collect eventIds already marked as read so upserts don't downgrade them
                    let readEventIds = try Set(String.fetchAll(db,
                        sql: "SELECT eventId FROM storedMessage WHERE roomId = ? AND sendStatus = 'read' AND isOutgoing = 1 AND eventId IS NOT NULL",
                        arguments: [roomId]))

                    for op in ops {
                        switch op {
                        case .upsert(var record):
                            let previousGroupDescription = try Self.existingMediaGroupDescription(
                                for: record,
                                in: db
                            )
                            if record.eventId != nil,
                               record.transactionId == nil,
                               record.isOutgoing {
                                record.transactionId = try Self.findMatchingPendingTransactionId(
                                    for: record,
                                    in: db
                                )
                            }

                            if record.sendStatus != "read",
                               let eventId = record.eventId,
                               readEventIds.contains(eventId) {
                                record.sendStatus = "read"
                            }

                            if let eventId = record.eventId {
                                try StoredMessage
                                    .filter(Column("roomId") == record.roomId && Column("eventId") == eventId && Column("id") != record.id)
                                    .deleteAll(db)
                            }
                            if let txnId = record.transactionId {
                                try StoredMessage
                                    .filter(Column("roomId") == record.roomId && Column("transactionId") == txnId && Column("id") != record.id)
                                    .deleteAll(db)
                            }
                            Self.logMediaGroupUpsert(
                                record,
                                previousGroupDescription: previousGroupDescription
                            )
                            try record.save(db)
                        case .delete(let id):
                            _ = try StoredMessage.deleteOne(db, key: id)
                        }
                    }

                    // Mark all outgoing messages up to the read cursor as "read"
                    if let cursorTs {
                        try db.execute(
                            sql: """
                                UPDATE storedMessage
                                SET sendStatus = 'read'
                                WHERE roomId = ? AND isOutgoing = 1
                                  AND timestamp <= ? AND sendStatus != 'read'
                                """,
                            arguments: [roomId, cursorTs]
                        )
                    }
                }

                let total = try dbQueue.read { db in
                    try StoredMessage.filter(Column("roomId") == roomId).fetchCount(db)
                }

                let upserts = ops.filter { if case .upsert = $0 { return true }; return false }.count
                let deletes = ops.count - upserts

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onFlush?()
                    self.log("Flushed \(ops.count) ops (\(upserts)↑ \(deletes)↓) for room \(roomId) — \(total) stored")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.log("Flush failed: \(error)")
                }
            }
        }
    }

    // MARK: - Enqueue

    private func enqueueDiff(_ diff: TimelineDiff) {
        switch diff {

        case .append(let items):
            for item in items {
                appendItem(item)
            }

        case .pushBack(let item):
            appendItem(item)

        case .pushFront(let item):
            let msg = TimelineService.mapTimelineItem(item)
            shadowItems.insert(shadowItem(for: msg), at: 0)
            if let msg {
                pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
            }

        case .insert(let index, let item):
            let idx = Int(index)
            guard idx <= shadowItems.count else { return }
            let msg = TimelineService.mapTimelineItem(item)
            shadowItems.insert(shadowItem(for: msg), at: idx)
            if let msg {
                pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
            }

        case .set(let index, let item):
            let idx = Int(index)
            guard idx < shadowItems.count else { return }
            let oldShadowItem = shadowItems[idx]
            let msg = TimelineService.mapTimelineItem(item)
            shadowItems[idx] = shadowItem(for: msg, fallbackTransactionId: oldShadowItem.transactionId)

            if let msg {
                var record = StoredMessage(from: msg, roomId: roomId)
                if record.transactionId == nil {
                    record.transactionId = oldShadowItem.transactionId
                }
                let newStoredId = storedId(msg.id)
                if let oldId = oldShadowItem.storedId, oldId != newStoredId {
                    pendingOps.append(.delete(oldId))
                }
                pendingOps.append(.upsert(record))
            }

        case .remove(let index):
            let idx = Int(index)
            guard idx < shadowItems.count else { return }
            shadowItems.remove(at: idx)

        case .popBack:
            guard !shadowItems.isEmpty else { return }
            shadowItems.removeLast()

        case .popFront:
            guard !shadowItems.isEmpty else { return }
            shadowItems.removeFirst()

        case .reset(let items):
            shadowItems.removeAll()
            for item in items {
                appendItem(item)
            }

        case .truncate(let length):
            let len = Int(length)
            while shadowItems.count > len {
                shadowItems.removeLast()
            }

        case .clear:
            shadowItems.removeAll()
        }
    }

    // MARK: - Helpers

    private func storedId(_ msgId: String) -> String {
        "\(roomId):\(msgId)"
    }

    private func appendItem(_ item: TimelineItem) {
        let msg = TimelineService.mapTimelineItem(item)
        shadowItems.append(shadowItem(for: msg))
        if let msg {
            pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
        }
    }

    private func shadowItem(
        for message: ChatMessage?,
        fallbackTransactionId: String? = nil
    ) -> ShadowItem {
        ShadowItem(
            storedId: message.map { storedId($0.id) },
            transactionId: message?.transactionId ?? fallbackTransactionId
        )
    }

    private static func findMatchingPendingTransactionId(
        for record: StoredMessage,
        in db: Database
    ) throws -> String? {
        guard record.eventId != nil,
              record.transactionId == nil,
              record.isOutgoing else {
            return record.transactionId
        }

        if let transactionId = try findOutgoingEnvelopeTransactionId(
            for: record,
            in: db
        ) {
            logMediaGroup(
                "db match tx explicit item=\(record.eventId ?? record.id) tx=\(transactionId)"
            )
            return transactionId
        }

        if record.contentType == "image" {
            return try String.fetchOne(
                db,
                sql: """
                    SELECT transactionId
                    FROM storedMessage
                    WHERE roomId = ?
                      AND eventId IS NULL
                      AND transactionId IS NOT NULL
                      AND isOutgoing = 1
                      AND senderId = ?
                      AND contentType = 'image'
                      AND ABS(timestamp - ?) < 3
                      AND ifnull(contentCaption, '') = ?
                      AND ifnull(zynaAttributesJSON, '') = ?
                      AND (? = -1 OR ifnull(contentImageWidth, -1) = ? OR ifnull(contentImageWidth, -1) = -1)
                      AND (? = -1 OR ifnull(contentImageHeight, -1) = ? OR ifnull(contentImageHeight, -1) = -1)
                    ORDER BY ABS(timestamp - ?) ASC
                    LIMIT 1
                    """,
                arguments: [
                    record.roomId,
                    record.senderId,
                    record.timestamp,
                    record.contentCaption ?? "",
                    record.zynaAttributesJSON ?? "",
                    record.contentImageWidth ?? -1,
                    record.contentImageWidth ?? -1,
                    record.contentImageHeight ?? -1,
                    record.contentImageHeight ?? -1,
                    record.timestamp
                ]
            )
        }

        return try String.fetchOne(
            db,
            sql: """
                SELECT transactionId
                FROM storedMessage
                WHERE roomId = ?
                  AND eventId IS NULL
                  AND transactionId IS NOT NULL
                  AND isOutgoing = 1
                  AND senderId = ?
                  AND contentType = ?
                  AND ABS(timestamp - ?) < 1
                  AND ifnull(contentBody, '') = ?
                  AND ifnull(contentCaption, '') = ?
                  AND ifnull(contentFilename, '') = ?
                  AND ifnull(contentMediaJSON, '') = ?
                  AND ifnull(zynaAttributesJSON, '') = ?
                ORDER BY ABS(timestamp - ?) ASC
                LIMIT 1
                """,
            arguments: [
                record.roomId,
                record.senderId,
                record.contentType,
                record.timestamp,
                record.contentBody ?? "",
                record.contentCaption ?? "",
                record.contentFilename ?? "",
                record.contentMediaJSON ?? "",
                record.zynaAttributesJSON ?? "",
                record.timestamp
            ]
        )
    }

    private static func findOutgoingEnvelopeTransactionId(
        for record: StoredMessage,
        in db: Database
    ) throws -> String? {
        guard record.isOutgoing,
              let eventId = record.eventId
        else {
            return nil
        }

        if let transactionId = try String.fetchOne(
            db,
            sql: """
                SELECT item.transactionId
                FROM pendingMediaGroupItem AS item
                JOIN pendingMediaGroup AS groupRecord
                  ON groupRecord.id = item.groupId
                WHERE groupRecord.roomId = ?
                  AND item.eventId = ?
                  AND item.transactionId IS NOT NULL
                LIMIT 1
                """,
            arguments: [record.roomId, eventId]
        ) {
            return transactionId
        }

        guard record.contentType == "image",
              let mediaGroup = record.toChatMessage()?.zynaAttributes.mediaGroup
        else {
            return nil
        }

        return try String.fetchOne(
            db,
            sql: """
                SELECT item.transactionId
                FROM pendingMediaGroupItem AS item
                JOIN pendingMediaGroup AS groupRecord
                  ON groupRecord.id = item.groupId
                WHERE groupRecord.roomId = ?
                  AND ifnull(groupRecord.kind, 'mediaBatch') = 'mediaBatch'
                  AND item.groupId = ?
                  AND item.itemIndex = ?
                  AND item.transactionId IS NOT NULL
                LIMIT 1
                """,
            arguments: [record.roomId, mediaGroup.id, mediaGroup.index]
        )
    }

    private static func existingMediaGroupDescription(
        for record: StoredMessage,
        in db: Database
    ) throws -> String? {
        if let existing = try StoredMessage.fetchOne(db, key: record.id),
           let group = existing.toChatMessage()?.zynaAttributes.mediaGroup {
            return describe(group: group)
        }
        if let eventId = record.eventId,
           let existing = try StoredMessage
            .filter(Column("roomId") == record.roomId && Column("eventId") == eventId)
            .fetchOne(db),
           let group = existing.toChatMessage()?.zynaAttributes.mediaGroup {
            return describe(group: group)
        }
        if let transactionId = record.transactionId,
           let existing = try StoredMessage
            .filter(Column("roomId") == record.roomId && Column("transactionId") == transactionId)
            .fetchOne(db),
           let group = existing.toChatMessage()?.zynaAttributes.mediaGroup {
            return describe(group: group)
        }
        return nil
    }

    private static func logMediaGroupUpsert(
        _ record: StoredMessage,
        previousGroupDescription: String?
    ) {
        guard record.isOutgoing, record.contentType == "image" else { return }

        let newGroupDescription = record.toChatMessage()?.zynaAttributes.mediaGroup.map(describe(group:))
        let itemId = record.eventId ?? record.transactionId ?? record.id

        if previousGroupDescription != newGroupDescription {
            logMediaGroup(
                "db upsert image item=\(itemId) group=\(previousGroupDescription ?? "none")->\(newGroupDescription ?? "none") status=\(record.sendStatus)"
            )
        } else {
            logMediaGroup(
                "db upsert image item=\(itemId) group=\(newGroupDescription ?? "none") status=\(record.sendStatus)"
            )
        }
    }

    private static func describe(group: MediaGroupInfo) -> String {
        "\(group.id)#\(group.index + 1)/\(group.total) \(group.captionPlacement.rawValue)"
    }
}
