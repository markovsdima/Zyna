//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

private let logMediaGroup = ScopedLog(.media, prefix: "[MediaGroup]")
private let logTimelineDB = ScopedLog(.database, prefix: "[TimelineDB]")

/// Accumulates SDK timeline diffs and flushes them to GRDB in a single
/// transaction after a 50 ms debounce window. Maintains a shadow
/// array for positional diff handling (SDK diffs reference items by index).
final class TimelineDiffBatcher {

    private let roomId: String
    private let dbQueue: DatabaseQueue
    private let log = ScopedLog(.database)
    private let writeQueue = DispatchQueue(label: "com.zyna.db.write", qos: .userInitiated)

    // MARK: - Shadow positions

    /// Mirrors the SDK timeline length/order so index-based diffs
    /// (`insert`, `set`, `remove`, `truncate`) can be validated against
    /// the previous SDK state. This intentionally stores no message
    /// identity: durable identity lives in `StoredMessage` as Matrix
    /// eventId / transactionId, because SDK item ids and positions can
    /// change after reset or pagination.
    private struct ShadowPosition {}

    private var shadowPositions: [ShadowPosition] = []

    // MARK: - Pending ops

    private enum DiffOp {
        case upsert(StoredMessage)
        case delete(String)
    }

    private var pendingOps: [DiffOp] = []
    private var pendingFlushSummary = TimelineFlushSummary()
    private var debounceWork: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.05

    /// Timestamp of the newest own message read by someone else.
    /// Updated from TimelineService when SDK delivers read receipts.
    private var readCursorTimestamp: TimeInterval?

    /// Called on main queue after each successful flush.
    var onFlush: ((TimelineFlushSummary) -> Void)?

    // MARK: - Init

    init(roomId: String, dbQueue: DatabaseQueue) {
        self.roomId = roomId
        self.dbQueue = dbQueue
    }

    /// Update read cursor from SDK read receipts. Called from main queue.
    func updateReadCursor(timestamp: TimeInterval) {
        if readCursorTimestamp == nil || timestamp > readCursorTimestamp! {
            readCursorTimestamp = timestamp
            pendingFlushSummary.readReceiptCount += 1
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
                self.recordSummary(for: diff)
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
        var summary = pendingFlushSummary
        pendingFlushSummary = TimelineFlushSummary()
        let cursorTs = readCursorTimestamp
        readCursorTimestamp = nil

        guard !ops.isEmpty || cursorTs != nil else { return }

        let roomId = self.roomId
        let dbQueue = self.dbQueue
        summary.upsertCount = ops.filter { if case .upsert = $0 { return true }; return false }.count
        summary.deleteCount = ops.count - summary.upsertCount
        summary.redactedUpsertCount = ops.reduce(into: 0) { count, op in
            if case .upsert(let record) = op, record.contentType == "redacted" {
                count += 1
            }
        }

        writeQueue.async { [weak self] in
            var internalDeleteCount = 0
            var detachedIdentityCount = 0
            do {
                try dbQueue.write { db in
                    // Collect eventIds already marked as read so upserts don't downgrade them
                    let readEventIds = try Set(String.fetchAll(db,
                        sql: "SELECT eventId FROM storedMessage WHERE roomId = ? AND sendStatus = 'read' AND isOutgoing = 1 AND eventId IS NOT NULL AND eventId != ''",
                        arguments: [roomId]))

                    for op in ops {
                        switch op {
                        case .upsert(var record):
                            Self.inheritExistingZynaAttributesIfNeeded(
                                for: &record,
                                in: db
                            )
                            Self.inheritExistingPendingEditIfNeeded(
                                for: &record,
                                in: db
                            )
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

                            let existing = try Self.existingStoredMessage(
                                for: record,
                                in: db
                            )
                            let shouldLogDirectRawTextBind = Self.shouldLogDirectRawTextBind(
                                incoming: record,
                                existing: existing
                            )
                            if let existing {
                                Self.applyMonotonicMerge(
                                    existing: existing,
                                    incoming: &record
                                )
                            }

                            if record.sendStatus != "read",
                               let eventId = record.eventId,
                               readEventIds.contains(eventId) {
                                record.sendStatus = "read"
                            }

                            if let eventId = record.eventId,
                               record.isOutgoing,
                               record.contentType == "text",
                               let transactionId = record.transactionId,
                               !transactionId.isEmpty,
                               shouldLogDirectRawTextBind {
                                logTimelineDB(
                                    "DirectRawTx db bind text event=\(eventId) tx=\(transactionId) status=\(record.sendStatus)"
                                )
                            }

                            if let eventId = record.eventId {
                                let result = try Self.resolveEventIdDuplicates(
                                    for: record,
                                    eventId: eventId,
                                    in: db
                                )
                                internalDeleteCount += result.deleted
                                detachedIdentityCount += result.detached
                            }
                            if let txnId = record.transactionId {
                                internalDeleteCount += try Self.deleteSafeTransactionDuplicates(
                                    for: record,
                                    transactionId: txnId,
                                    in: db
                                )
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
                                  AND eventId IS NOT NULL
                                  AND eventId != ''
                                  AND timestamp <= ? AND sendStatus != 'read'
                                """,
                            arguments: [roomId, cursorTs]
                        )
                    }
                }

                let total = try dbQueue.read { db in
                    try StoredMessage.filter(Column("roomId") == roomId).fetchCount(db)
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onFlush?(summary)
                    let dedupe = internalDeleteCount > 0 || detachedIdentityCount > 0
                        ? " dedupe=\(internalDeleteCount)↓ detached=\(detachedIdentityCount)"
                        : ""
                    self.log("Flushed \(ops.count) ops (\(summary.upsertCount)↑ \(summary.deleteCount)↓)\(dedupe) for room \(roomId) — \(total) stored")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.log("Flush failed: \(error)")
                }
            }
        }
    }

    // MARK: - Enqueue

    private func recordSummary(for diff: TimelineDiff) {
        switch diff {
        case .append:
            pendingFlushSummary.appendCount += 1
        case .pushBack:
            pendingFlushSummary.pushBackCount += 1
        case .pushFront:
            pendingFlushSummary.pushFrontCount += 1
        case .insert:
            pendingFlushSummary.insertCount += 1
        case .set:
            pendingFlushSummary.setCount += 1
        case .remove:
            pendingFlushSummary.removeCount += 1
        case .popBack:
            pendingFlushSummary.removeCount += 1
        case .popFront:
            pendingFlushSummary.removeCount += 1
        case .reset:
            pendingFlushSummary.resetCount += 1
        case .truncate:
            pendingFlushSummary.truncateCount += 1
        case .clear:
            pendingFlushSummary.clearCount += 1
        }
    }

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
            shadowPositions.insert(shadowPosition(for: msg), at: 0)
            if let msg {
                pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
            }

        case .insert(let index, let item):
            let idx = Int(index)
            guard idx <= shadowPositions.count else { return }
            let msg = TimelineService.mapTimelineItem(item)
            shadowPositions.insert(shadowPosition(for: msg), at: idx)
            if let msg {
                pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
            }

        case .set(let index, let item):
            let idx = Int(index)
            guard idx < shadowPositions.count else { return }
            let msg = TimelineService.mapTimelineItem(item)
            shadowPositions[idx] = shadowPosition(for: msg)

            if let msg {
                let record = StoredMessage(from: msg, roomId: roomId)
                pendingOps.append(.upsert(record))
            }

        case .remove(let index):
            let idx = Int(index)
            guard idx < shadowPositions.count else { return }
            shadowPositions.remove(at: idx)

        case .popBack:
            guard !shadowPositions.isEmpty else { return }
            shadowPositions.removeLast()

        case .popFront:
            guard !shadowPositions.isEmpty else { return }
            shadowPositions.removeFirst()

        case .reset(let items):
            shadowPositions.removeAll()
            for item in items {
                appendItem(item)
            }

        case .truncate(let length):
            let len = Int(length)
            while shadowPositions.count > len {
                shadowPositions.removeLast()
            }

        case .clear:
            shadowPositions.removeAll()
        }
    }

    // MARK: - Helpers

    private func appendItem(_ item: TimelineItem) {
        let msg = TimelineService.mapTimelineItem(item)
        shadowPositions.append(shadowPosition(for: msg))
        if let msg {
            pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
        }
    }

    private func shadowPosition(for _: ChatMessage?) -> ShadowPosition {
        ShadowPosition()
    }

    private static func inheritExistingZynaAttributesIfNeeded(
        for record: inout StoredMessage,
        in db: Database
    ) {
        guard record.contentType == "redacted",
              (record.zynaAttributesJSON ?? "").isEmpty,
              let existing = (try? existingStoredMessage(for: record, in: db)) ?? nil,
              let existingAttrs = existing.zynaAttributesJSON,
              !existingAttrs.isEmpty
        else {
            return
        }

        record.zynaAttributesJSON = existingAttrs
        if let group = existing.toChatMessage()?.zynaAttributes.mediaGroup {
            logMediaGroup(
                "db preserve redacted attrs item=\(record.eventId ?? record.transactionId ?? record.id) group=\(describe(group: group))"
            )
        }
    }

    private static func inheritExistingPendingEditIfNeeded(
        for record: inout StoredMessage,
        in db: Database
    ) {
        guard record.isOutgoing else {
            return
        }

        if record.latestEditEventId?.isEmpty == false {
            record.isEditPending = false
            record.isEditFailed = false
            record.editTransactionId = nil
            return
        }

        guard let existing = (try? existingStoredMessage(for: record, in: db)) ?? nil,
              existing.isEditPending || existing.isEditFailed
        else {
            return
        }

        if existing.isEditPending && !record.isEditPending {
            record.isEditPending = true
        }
        if existing.isEditFailed && !record.isEditPending {
            record.isEditFailed = true
        }
        if record.editTransactionId == nil {
            record.editTransactionId = existing.editTransactionId
        }
    }

    private static func existingStoredMessage(
        for record: StoredMessage,
        in db: Database
    ) throws -> StoredMessage? {
        if let existing = try StoredMessage.fetchOne(db, key: record.id) {
            return existing
        }
        if let eventId = record.eventId,
           !eventId.isEmpty {
            let candidates = try StoredMessage
            .filter(Column("roomId") == record.roomId && Column("eventId") == eventId)
            .fetchAll(db)
            if let existing = preferredExistingEventMessage(
                for: record,
                candidates: candidates
            ) {
                return existing
            }
        }
        if let transactionId = record.transactionId,
           !transactionId.isEmpty {
            let candidates = try StoredMessage
            .filter(Column("roomId") == record.roomId && Column("transactionId") == transactionId)
            .fetchAll(db)
            if let existing = candidates.first(where: {
                isSafeTransactionDuplicate($0, of: record)
            }) {
                return existing
            }
        }
        return nil
    }

    private static func shouldLogDirectRawTextBind(
        incoming: StoredMessage,
        existing: StoredMessage?
    ) -> Bool {
        guard incoming.isOutgoing,
              incoming.contentType == "text",
              incoming.eventId?.isEmpty == false,
              incoming.transactionId?.isEmpty == false else {
            return false
        }
        guard let existing else { return true }
        return existing.eventId != incoming.eventId
            || existing.transactionId != incoming.transactionId
    }

    private struct DedupeResult {
        var deleted = 0
        var detached = 0
    }

    private static func preferredExistingEventMessage(
        for record: StoredMessage,
        candidates: [StoredMessage]
    ) -> StoredMessage? {
        if let sameEvent = candidates.first(where: {
            isSafeEventDuplicate($0, of: record)
        }) {
            return sameEvent
        }
        return nil
    }

    private static func resolveEventIdDuplicates(
        for record: StoredMessage,
        eventId: String,
        in db: Database
    ) throws -> DedupeResult {
        let candidates = try StoredMessage
            .filter(
                Column("roomId") == record.roomId
                    && Column("eventId") == eventId
                    && Column("id") != record.id
            )
            .fetchAll(db)

        var result = DedupeResult()
        for candidate in candidates {
            if isSafeEventDuplicate(candidate, of: record) {
                logTimelineDB(
                    "event duplicate delete existing=\(describeForDedupe(candidate)) incoming=\(describeForDedupe(record))"
                )
                _ = try StoredMessage.deleteOne(db, key: candidate.id)
                result.deleted += 1
            } else {
                logTimelineDB(
                    "event duplicate detach existing=\(describeForDedupe(candidate)) incoming=\(describeForDedupe(record))"
                )
                if candidate.transactionId != nil,
                   candidate.transactionId == record.transactionId {
                    try db.execute(
                        sql: """
                            UPDATE storedMessage
                            SET eventId = NULL, transactionId = NULL
                            WHERE id = ?
                            """,
                        arguments: [candidate.id]
                    )
                } else {
                    try db.execute(
                        sql: """
                            UPDATE storedMessage
                            SET eventId = NULL
                            WHERE id = ?
                            """,
                        arguments: [candidate.id]
                    )
                }
                result.detached += 1
            }
        }
        return result
    }

    private static func deleteSafeTransactionDuplicates(
        for record: StoredMessage,
        transactionId: String,
        in db: Database
    ) throws -> Int {
        guard record.isOutgoing else { return 0 }

        let candidates = try StoredMessage
            .filter(
                Column("roomId") == record.roomId
                    && Column("transactionId") == transactionId
                    && Column("id") != record.id
                    && Column("isOutgoing") == true
                    && Column("senderId") == record.senderId
            )
            .fetchAll(db)

        var deleted = 0
        for candidate in candidates where isSafeTransactionDuplicate(
            candidate,
            of: record
        ) {
            logTimelineDB(
                "tx duplicate delete existing=\(describeForDedupe(candidate)) incoming=\(describeForDedupe(record))"
            )
            _ = try StoredMessage.deleteOne(db, key: candidate.id)
            deleted += 1
        }
        return deleted
    }

    private static func isSafeEventDuplicate(
        _ candidate: StoredMessage,
        of record: StoredMessage
    ) -> Bool {
        guard candidate.senderId == record.senderId else {
            return false
        }
        if abs(candidate.timestamp - record.timestamp) <= 0.05 {
            return true
        }
        return contentFingerprint(candidate) == contentFingerprint(record)
    }

    private static func isSafeTransactionDuplicate(
        _ candidate: StoredMessage,
        of record: StoredMessage
    ) -> Bool {
        guard candidate.senderId == record.senderId,
              candidate.isOutgoing == record.isOutgoing
        else {
            return false
        }
        if let candidateEventId = candidate.eventId,
           let recordEventId = record.eventId,
           candidateEventId != recordEventId {
            return false
        }
        if candidate.isOutgoing,
           candidate.transactionId != nil,
           candidate.transactionId == record.transactionId {
            return true
        }
        if candidate.contentType != record.contentType {
            return false
        }
        return contentFingerprint(candidate) == contentFingerprint(record)
    }

    private struct ContentFingerprint: Equatable {
        let contentType: String
        let body: String
        let caption: String
        let filename: String
        let mimetype: String
        let fileSize: Int64
        let imageWidth: Int64
        let imageHeight: Int64
        let videoWidth: Int64
        let videoHeight: Int64
        let videoDuration: TimeInterval
        let zynaAttributesJSON: String
    }

    private static func contentFingerprint(_ message: StoredMessage) -> ContentFingerprint {
        ContentFingerprint(
            contentType: message.contentType,
            body: message.contentBody ?? "",
            caption: message.contentCaption ?? "",
            filename: message.contentFilename ?? "",
            mimetype: message.contentMimetype ?? "",
            fileSize: message.contentFileSize ?? -1,
            imageWidth: message.contentImageWidth ?? -1,
            imageHeight: message.contentImageHeight ?? -1,
            videoWidth: message.contentVideoWidth ?? -1,
            videoHeight: message.contentVideoHeight ?? -1,
            videoDuration: message.contentVideoDuration ?? -1,
            zynaAttributesJSON: message.zynaAttributesJSON ?? ""
        )
    }

    private static func describeForDedupe(_ message: StoredMessage) -> String {
        let timestamp = String(format: "%.3f", message.timestamp)
        let detail = message.contentBody
            ?? message.contentCaption
            ?? message.contentFilename
            ?? "-"
        return "id=\(shortForDedupe(message.id)) event=\(shortForDedupe(message.eventId)) tx=\(shortForDedupe(message.transactionId)) type=\(message.contentType) out=\(message.isOutgoing) status=\(message.sendStatus) ts=\(timestamp) detail=\(shortForDedupe(detail))"
    }

    private static func shortForDedupe(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "-" }
        guard value.count > 22 else { return value }
        return "\(value.prefix(10))...\(value.suffix(8))"
    }

    private static func applyMonotonicMerge(
        existing: StoredMessage,
        incoming record: inout StoredMessage
    ) {
        // Matrix eventId is the stable identity. The SDK timeline item id
        // can change after reset/pagination, so keep the first stored row id
        // and treat later snapshots of the same event/transaction as updates.
        record.id = existing.id
        if record.eventId == nil {
            record.eventId = existing.eventId
        }
        if record.transactionId == nil {
            record.transactionId = existing.transactionId
        }

        if existing.contentType == "redacted",
           record.contentType != "redacted" {
            var preserved = existing
            preserved.senderDisplayName = record.senderDisplayName ?? existing.senderDisplayName
            preserved.senderAvatarUrl = record.senderAvatarUrl ?? existing.senderAvatarUrl
            preserved.sendStatus = preferredSendStatus(existing.sendStatus, record.sendStatus)
            preserved.reactionsJSON = record.reactionsJSON
            if preserved.eventId == nil {
                preserved.eventId = record.eventId
            }
            if preserved.transactionId == nil {
                preserved.transactionId = record.transactionId
            }
            record = preserved
            return
        }

        record.sendStatus = preferredSendStatus(existing.sendStatus, record.sendStatus)
        if (record.zynaAttributesJSON ?? "").isEmpty,
           let existingAttrs = existing.zynaAttributesJSON,
           !existingAttrs.isEmpty {
            record.zynaAttributesJSON = existingAttrs
        }

        guard existing.latestEditEventId?.isEmpty == false,
              record.latestEditEventId == nil,
              existing.contentType == record.contentType,
              record.contentType != "redacted"
        else {
            return
        }

        preserveContentFields(from: existing, into: &record)
        record.isEdited = true
        record.latestEditEventId = existing.latestEditEventId
    }

    private static func preferredSendStatus(_ existing: String, _ incoming: String) -> String {
        sendStatusRank(existing) >= sendStatusRank(incoming) ? existing : incoming
    }

    private static func sendStatusRank(_ status: String) -> Int {
        switch status {
        case "failed":
            return 0
        case "sending":
            return 1
        case "sent", "synced":
            return 2
        case "read":
            return 3
        default:
            return 1
        }
    }

    private static func preserveContentFields(
        from existing: StoredMessage,
        into record: inout StoredMessage
    ) {
        record.contentBody = existing.contentBody
        record.contentMediaJSON = existing.contentMediaJSON
        record.contentImageWidth = existing.contentImageWidth
        record.contentImageHeight = existing.contentImageHeight
        record.contentCaption = existing.contentCaption
        record.contentVoiceDuration = existing.contentVoiceDuration
        record.contentVoiceWaveform = existing.contentVoiceWaveform
        record.contentFilename = existing.contentFilename
        record.contentMimetype = existing.contentMimetype
        record.contentFileSize = existing.contentFileSize
        record.contentThumbnailMediaJSON = existing.contentThumbnailMediaJSON
        record.contentVideoWidth = existing.contentVideoWidth
        record.contentVideoHeight = existing.contentVideoHeight
        record.contentVideoDuration = existing.contentVideoDuration
        record.zynaAttributesJSON = existing.zynaAttributesJSON
    }

    private static func findMatchingPendingTransactionId(
        for record: StoredMessage,
        in db: Database
    ) throws -> String? {
        guard record.eventId != nil,
              record.transactionId == nil,
              record.isOutgoing,
              record.contentType != "redacted" else {
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

        if record.contentType == "video" {
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
                      AND contentType = 'video'
                      AND ABS(timestamp - ?) < 600
                      AND ifnull(contentCaption, '') = ?
                      AND ifnull(contentFilename, '') = ?
                      AND ifnull(zynaAttributesJSON, '') = ?
                      AND (? = -1 OR ifnull(contentVideoWidth, -1) = ? OR ifnull(contentVideoWidth, -1) = -1)
                      AND (? = -1 OR ifnull(contentVideoHeight, -1) = ? OR ifnull(contentVideoHeight, -1) = -1)
                      AND (? < 0 OR ifnull(contentVideoDuration, -1) < 0 OR ABS(ifnull(contentVideoDuration, -1) - ?) < 0.5)
                      AND (? = '' OR ifnull(contentMimetype, '') = '' OR ifnull(contentMimetype, '') = ?)
                      AND (? = -1 OR ifnull(contentFileSize, -1) = ? OR ifnull(contentFileSize, -1) = -1)
                    ORDER BY ABS(timestamp - ?) ASC
                    LIMIT 1
                    """,
                arguments: [
                    record.roomId,
                    record.senderId,
                    record.timestamp,
                    record.contentCaption ?? "",
                    record.contentFilename ?? "",
                    record.zynaAttributesJSON ?? "",
                    record.contentVideoWidth ?? -1,
                    record.contentVideoWidth ?? -1,
                    record.contentVideoHeight ?? -1,
                    record.contentVideoHeight ?? -1,
                    record.contentVideoDuration ?? -1,
                    record.contentVideoDuration ?? -1,
                    record.contentMimetype ?? "",
                    record.contentMimetype ?? "",
                    record.contentFileSize ?? -1,
                    record.contentFileSize ?? -1,
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
        if let existing = try existingStoredMessage(for: record, in: db),
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
