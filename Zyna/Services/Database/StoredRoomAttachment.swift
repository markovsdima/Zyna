//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

private let logRoomAttachmentIndex = ScopedLog(
    .attachments,
    prefix: "[Attachments][trace][index]"
)

/// Durable, derived catalog entry for one remote room attachment.
///
/// This is intentionally not a second message store and does not describe
/// timeline continuity. It only answers "which attachments have we already
/// discovered?" Media bytes remain owned by the media caches.
struct StoredRoomAttachment: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "roomAttachment"

    var roomId: String
    var eventId: String
    var kind: String
    var timestampMs: Int64
    var senderId: String
    var senderDisplayName: String?
    var isOutgoing: Bool
    var filename: String
    var caption: String?
    var mimetype: String?
    var sizeBytes: Int64?
    var pixelWidth: Int64?
    var pixelHeight: Int64?
    var durationSeconds: TimeInterval?
    var blurhash: String?
    var isAnimated: Bool
    var sourceJSON: String
    var isSourceEncrypted: Bool
    var thumbnailSourceJSON: String?
    var thumbnailIsEncrypted: Bool?
    var thumbnailWidth: Int64?
    var thumbnailHeight: Int64?
    var thumbnailSizeBytes: Int64?
    var thumbnailMimetype: String?

    var attachmentKind: RoomAttachmentKind? {
        RoomAttachmentKind(rawValue: kind)
    }

    init(roomId: String, item: AttachmentItem) {
        self.roomId = roomId
        eventId = item.id
        kind = item.kind.rawValue
        timestampMs = Int64(clamping: item.timestampMs)
        senderId = item.sender
        senderDisplayName = item.senderName
        isOutgoing = item.isOwn
        filename = item.filename
        caption = item.caption
        mimetype = item.mimetype
        sizeBytes = item.sizeBytes.map(Int64.init(clamping:))
        pixelWidth = item.pixelWidth.map(Int64.init)
        pixelHeight = item.pixelHeight.map(Int64.init)
        durationSeconds = item.durationSeconds
        blurhash = item.blurhash
        isAnimated = item.isAnimated
        sourceJSON = item.source.toJson()
        isSourceEncrypted = item.isSourceEncrypted
        thumbnailSourceJSON = item.thumbnail?.source.toJson()
        thumbnailIsEncrypted = item.thumbnail?.isEncrypted
        thumbnailWidth = item.thumbnail?.width.map(Int64.init)
        thumbnailHeight = item.thumbnail?.height.map(Int64.init)
        thumbnailSizeBytes = item.thumbnail?.sizeBytes.map(Int64.init(clamping:))
        thumbnailMimetype = item.thumbnail?.mimetype
    }

    /// Backfills what the main chat has already materialized. Rows written
    /// before the media-metadata migration can still lack blurhash or an
    /// original filename until the SDK event is observed again.
    init?(storedMessage message: StoredMessage) {
        guard let eventId = message.eventId, !eventId.isEmpty,
              let sourceJSON = message.contentMediaJSON, !sourceJSON.isEmpty,
              let attachmentKind = RoomAttachmentClassifier.kindForStoredMessage(
                contentType: message.contentType,
                filename: message.contentFilename,
                mimetype: message.contentMimetype
              ),
              message.timestamp.isFinite else {
            return nil
        }

        roomId = message.roomId
        self.eventId = eventId
        kind = attachmentKind.rawValue
        timestampMs = Int64((message.timestamp * 1000).rounded())
        senderId = message.senderId
        senderDisplayName = message.senderDisplayName
        isOutgoing = message.isOutgoing
        filename = message.contentFilename ?? attachmentKind.defaultFilename
        caption = message.contentCaption
        mimetype = message.contentMimetype
        sizeBytes = message.contentFileSize
        switch attachmentKind {
        case .image:
            pixelWidth = message.contentImageWidth
            pixelHeight = message.contentImageHeight
            durationSeconds = nil
        case .video:
            pixelWidth = message.contentVideoWidth
            pixelHeight = message.contentVideoHeight
            durationSeconds = message.contentVideoDuration
        case .audio, .voice:
            pixelWidth = nil
            pixelHeight = nil
            durationSeconds = message.contentVoiceDuration
        case .file:
            pixelWidth = nil
            pixelHeight = nil
            durationSeconds = nil
        }
        blurhash = message.contentBlurhash.flatMap { $0.isEmpty ? nil : $0 }
        isAnimated = message.contentIsAnimated ?? false
        self.sourceJSON = sourceJSON
        isSourceEncrypted = message.contentMediaIsEncrypted
            ?? MediaSourceInspector.isEncrypted(json: sourceJSON)
        thumbnailSourceJSON = message.contentThumbnailMediaJSON
        thumbnailIsEncrypted = message.contentThumbnailMediaJSON.map { json in
            message.contentThumbnailIsEncrypted
                ?? MediaSourceInspector.isEncrypted(json: json)
        }
        thumbnailWidth = message.contentThumbnailWidth
        thumbnailHeight = message.contentThumbnailHeight
        thumbnailSizeBytes = message.contentThumbnailSize
        thumbnailMimetype = message.contentThumbnailMimetype
    }

    func makeAttachmentItem() -> AttachmentItem? {
        guard let kind = attachmentKind,
              timestampMs >= 0,
              let source = try? MediaSource.fromJson(json: sourceJSON) else {
            return nil
        }
        let thumbnail: AttachmentItem.ThumbnailRef? = thumbnailSourceJSON.flatMap { json in
            guard let source = try? MediaSource.fromJson(json: json) else { return nil }
            return AttachmentItem.ThumbnailRef(
                source: source,
                mxc: source.url(),
                isEncrypted: thumbnailIsEncrypted
                    ?? MediaSourceInspector.isEncrypted(json: json),
                width: thumbnailWidth.flatMap(Int.init(exactly:)),
                height: thumbnailHeight.flatMap(Int.init(exactly:)),
                sizeBytes: thumbnailSizeBytes.flatMap(UInt64.init(exactly:)),
                mimetype: thumbnailMimetype
            )
        }
        return AttachmentItem(
            id: eventId,
            uniqueId: eventId,
            kind: kind,
            timestampMs: UInt64(timestampMs),
            sender: senderId,
            senderName: senderDisplayName,
            isOwn: isOutgoing,
            filename: filename,
            caption: caption,
            mimetype: mimetype,
            sizeBytes: sizeBytes.flatMap(UInt64.init(exactly:)),
            pixelWidth: pixelWidth.flatMap(Int.init(exactly:)),
            pixelHeight: pixelHeight.flatMap(Int.init(exactly:)),
            durationSeconds: durationSeconds,
            blurhash: blurhash,
            isAnimated: isAnimated,
            source: source,
            sourceMxc: source.url(),
            isSourceEncrypted: isSourceEncrypted,
            thumbnail: thumbnail
        )
    }

    /// Avoids publishing an identical full-room observation when the SDK
    /// reveals an event that the projection already knows.
    @discardableResult
    func saveIfChanged(in db: Database) throws -> Bool {
        let existing = try Self.fetchOne(
            db,
            key: ["roomId": roomId, "eventId": eventId]
        )
        let candidate = existing.map { mergingMetadata(from: $0) } ?? self
        if existing != candidate {
            try candidate.save(db)
            return true
        }
        return false
    }

    /// Timeline projections can observe the same event with different
    /// metadata readiness. Missing values must not erase richer facts that
    /// another projection or a decoded image has already discovered.
    /// A changed source is a replacement, so source-specific metadata is not
    /// carried across it.
    func mergingMetadata(from existing: StoredRoomAttachment) -> StoredRoomAttachment {
        var merged = self
        merged.senderDisplayName = senderDisplayName ?? existing.senderDisplayName

        guard sourceJSON == existing.sourceJSON else { return merged }

        if filename == attachmentKind?.defaultFilename,
           existing.filename != existing.attachmentKind?.defaultFilename {
            merged.filename = existing.filename
        }
        merged.mimetype = mimetype ?? existing.mimetype
        merged.sizeBytes = sizeBytes ?? existing.sizeBytes
        merged.pixelWidth = pixelWidth ?? existing.pixelWidth
        merged.pixelHeight = pixelHeight ?? existing.pixelHeight
        merged.durationSeconds = durationSeconds ?? existing.durationSeconds
        merged.blurhash = blurhash ?? existing.blurhash
        merged.isAnimated = isAnimated || existing.isAnimated

        if thumbnailSourceJSON == nil {
            merged.thumbnailSourceJSON = existing.thumbnailSourceJSON
            merged.thumbnailIsEncrypted = existing.thumbnailIsEncrypted
            merged.thumbnailWidth = existing.thumbnailWidth
            merged.thumbnailHeight = existing.thumbnailHeight
            merged.thumbnailSizeBytes = existing.thumbnailSizeBytes
            merged.thumbnailMimetype = existing.thumbnailMimetype
        } else if thumbnailSourceJSON == existing.thumbnailSourceJSON {
            merged.thumbnailIsEncrypted = thumbnailIsEncrypted
                ?? existing.thumbnailIsEncrypted
            merged.thumbnailWidth = thumbnailWidth ?? existing.thumbnailWidth
            merged.thumbnailHeight = thumbnailHeight ?? existing.thumbnailHeight
            merged.thumbnailSizeBytes = thumbnailSizeBytes ?? existing.thumbnailSizeBytes
            merged.thumbnailMimetype = thumbnailMimetype ?? existing.thumbnailMimetype
        }
        return merged
    }

    static func fetchAll(
        in db: Database,
        roomId: String,
        kinds: Set<RoomAttachmentKind>? = nil
    ) throws -> [StoredRoomAttachment] {
        var request = filter(Column("roomId") == roomId)
        if let kinds {
            guard !kinds.isEmpty else { return [] }
            request = request.filter(kinds.map(\.rawValue).contains(Column("kind")))
        }
        return try request
            .order(Column("timestampMs").desc, Column("eventId").desc)
            .fetchAll(db)
    }

}

/// Serial, best-effort writer used by the filtered attachments timeline.
/// Main-chat writes join `TimelineDiffBatcher`'s transaction instead.
final class RoomAttachmentIndex: @unchecked Sendable {
    private static let batchDelay: TimeInterval = 0.04

    private let roomId: String
    private let dbQueue: DatabaseQueue
    private let writeQueue = DispatchQueue(
        label: "com.zyna.db.room-attachment-index",
        qos: .utility
    )
    private let observationQueue = DispatchQueue(
        label: "com.zyna.db.room-attachment-observation",
        qos: .utility
    )
    /// Confined to `writeQueue`. A burst of late decryptions otherwise makes
    /// one SQLite transaction and one full-room observation per event.
    private var pendingUpserts: [String: StoredRoomAttachment] = [:]
    private var pendingRemovals: Set<String> = []
    private var pendingSince: TimeInterval?
    private var flushScheduled = false

    init(roomId: String, dbQueue: DatabaseQueue) {
        self.roomId = roomId
        self.dbQueue = dbQueue
    }

    func upsert(_ records: [StoredRoomAttachment]) {
        guard !records.isEmpty else { return }
        #if DEBUG
        logRoomAttachmentIndex(
            "trace filtered enqueue room=\(roomId) records=\(records.count)"
        )
        #endif
        writeQueue.async { [self] in
            for record in records {
                pendingRemovals.remove(record.eventId)
                pendingUpserts[record.eventId] = pendingUpserts[record.eventId]
                    .map { record.mergingMetadata(from: $0) }
                    ?? record
            }
            scheduleFlushIfNeeded()
        }
    }

    func remove(eventIds: [String]) {
        guard !eventIds.isEmpty else { return }
        writeQueue.async { [self] in
            for eventId in eventIds {
                pendingUpserts.removeValue(forKey: eventId)
                pendingRemovals.insert(eventId)
            }
            scheduleFlushIfNeeded()
        }
    }

    private func scheduleFlushIfNeeded() {
        dispatchPrecondition(condition: .onQueue(writeQueue))
        guard !flushScheduled else { return }
        flushScheduled = true
        pendingSince = ProcessInfo.processInfo.systemUptime
        writeQueue.asyncAfter(deadline: .now() + Self.batchDelay) { [self] in
            flushPending()
        }
    }

    private func flushPending() {
        dispatchPrecondition(condition: .onQueue(writeQueue))
        flushScheduled = false
        let upserts = Array(pendingUpserts.values)
        let removals = Array(pendingRemovals)
        let enqueuedAt = pendingSince ?? ProcessInfo.processInfo.systemUptime
        pendingUpserts.removeAll(keepingCapacity: true)
        pendingRemovals.removeAll(keepingCapacity: true)
        pendingSince = nil
        guard !upserts.isEmpty || !removals.isEmpty else { return }

        #if DEBUG
        let writeStarted = ProcessInfo.processInfo.systemUptime
        #endif
        do {
            var changedUpserts = 0
            let deleted = try dbQueue.write { db in
                let deleted: Int
                if removals.isEmpty {
                    deleted = 0
                } else {
                    deleted = try StoredRoomAttachment
                        .filter(Column("roomId") == roomId)
                        .filter(removals.contains(Column("eventId")))
                        .deleteAll(db)
                }
                for record in upserts {
                    if try record.saveIfChanged(in: db) {
                        changedUpserts += 1
                    }
                }
                return deleted
            }
            #if DEBUG
            let finished = ProcessInfo.processInfo.systemUptime
            logRoomAttachmentIndex(
                "trace filtered commit room=\(roomId) upserts=\(upserts.count) "
                + "changed=\(changedUpserts) removals=\(removals.count) "
                + "deleted=\(deleted) queueMs=\(Self.traceMs(writeStarted - enqueuedAt)) "
                + "writeMs=\(Self.traceMs(finished - writeStarted))"
            )
            #endif
        } catch {
            logRoomAttachmentIndex("batch write failed: \(error)")
        }
    }

    /// Emits the complete known catalog immediately and after committed
    /// changes. One room-level observation replaces per-tile database reads.
    func observe(
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable ([StoredRoomAttachment]) -> Void
    ) -> AnyDatabaseCancellable {
        let roomId = roomId
        let observation = ValueObservation.tracking { db in
            #if DEBUG
            let started = ProcessInfo.processInfo.systemUptime
            #endif
            let records = try StoredRoomAttachment.fetchAll(in: db, roomId: roomId)
            #if DEBUG
            logRoomAttachmentIndex(
                "trace observe fetch room=\(roomId) records=\(records.count) "
                + "ms=\(Self.traceMs(ProcessInfo.processInfo.systemUptime - started))"
            )
            #endif
            return records
        }.removeDuplicates()
        return observation.start(
            in: dbQueue,
            scheduling: .async(onQueue: observationQueue),
            onError: onError,
            onChange: onChange
        )
    }

    #if DEBUG
    private static func traceMs(_ seconds: TimeInterval) -> String {
        String(format: "%.0f", seconds * 1000)
    }
    #endif
}
