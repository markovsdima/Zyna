//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK
import Testing
@testable import Zyna

@Suite("Room attachment index")
struct RoomAttachmentIndexTests {

    private func makeRecord(
        eventId: String,
        timestampMs: UInt64 = 1_789_473_600_123
    ) throws -> StoredRoomAttachment {
        let source = try MediaSource.fromUrl(url: "mxc://example.org/\(eventId)")
        let item = AttachmentItem(
            id: eventId,
            uniqueId: eventId,
            kind: .image,
            timestampMs: timestampMs,
            sender: "@alice:example.org",
            senderName: "Alice",
            isOwn: false,
            filename: "photo.jpg",
            caption: nil,
            mimetype: "image/jpeg",
            sizeBytes: 42_000,
            pixelWidth: 1600,
            pixelHeight: 900,
            durationSeconds: nil,
            blurhash: nil,
            isAnimated: false,
            source: source,
            sourceMxc: source.url(),
            isSourceEncrypted: false,
            thumbnail: nil
        )
        return StoredRoomAttachment(roomId: "!room:example.org", item: item)
    }

    @Test("File classification uses MIME and extension fallbacks")
    func fileClassification() {
        #expect(RoomAttachmentClassifier.kindForFile(
            filename: "capture.bin",
            mimetype: "video/mp4"
        ) == .video)
        #expect(RoomAttachmentClassifier.kindForFile(
            filename: "capture.mov",
            mimetype: nil
        ) == .video)
        #expect(RoomAttachmentClassifier.kindForFile(
            filename: "notes.pdf",
            mimetype: "application/pdf"
        ) == .file)
        #expect(RoomAttachmentClassifier.kindForFile(
            filename: "track.bin",
            mimetype: "audio/ogg"
        ) == .audio)
        #expect(RoomAttachmentClassifier.kindForFile(
            filename: "track.m4a",
            mimetype: nil
        ) == .audio)
    }

    @Test("Voice and ordinary audio stay distinct")
    func audioClassification() {
        #expect(RoomAttachmentClassifier.kindForAudio(isVoice: true) == .voice)
        #expect(RoomAttachmentClassifier.kindForAudio(isVoice: false) == .audio)
    }

    @Test("Forwarded ordinary audio remains m.audio")
    func forwardedAudioMessageType() throws {
        let source = try MediaSource.fromUrl(url: "mxc://example.org/audio")
        let record = PendingForwardedMediaRecord(
            itemId: "item",
            envelopeId: "envelope",
            roomId: "!room:example.org",
            mediaKind: PendingForwardedMediaKind.audio.rawValue,
            sourceJSON: source.toJson(),
            thumbnailSourceJSON: nil,
            filename: nil,
            caption: nil,
            mimetype: nil,
            size: 123,
            width: nil,
            height: nil,
            duration: 2.5,
            waveformJSON: nil,
            transactionId: "tx",
            createdAt: 0,
            updatedAt: 0
        )

        guard case .audio(let content) = try record.messageType(
            zynaAttributes: ZynaMessageAttributes()
        ) else {
            Issue.record("expected m.audio")
            return
        }
        #expect(content.voice == nil)
        #expect(content.audio == nil)
        #expect(content.filename == RoomAttachmentKind.audio.defaultFilename)
        #expect(content.info?.mimetype == RoomAttachmentKind.audio.defaultMimetype)
    }

    @Test("Stored projection round-trips presentation metadata")
    func recordRoundTrip() throws {
        let source = try MediaSource.fromUrl(url: "mxc://example.org/original")
        let thumbnailSource = try MediaSource.fromUrl(url: "mxc://example.org/thumbnail")
        let item = AttachmentItem(
            id: "$event",
            uniqueId: "timeline-item",
            kind: .video,
            timestampMs: 1_789_473_600_123,
            sender: "@alice:example.org",
            senderName: "Alice",
            isOwn: false,
            filename: "clip.mp4",
            caption: "A clip",
            mimetype: "video/mp4",
            sizeBytes: 42_000,
            pixelWidth: 1920,
            pixelHeight: 1080,
            durationSeconds: 3.5,
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
            isAnimated: false,
            source: source,
            sourceMxc: source.url(),
            isSourceEncrypted: false,
            thumbnail: AttachmentItem.ThumbnailRef(
                source: thumbnailSource,
                mxc: thumbnailSource.url(),
                isEncrypted: false,
                width: 320,
                height: 180,
                sizeBytes: 4_200,
                mimetype: "image/jpeg"
            )
        )

        let stored = StoredRoomAttachment(roomId: "!room:example.org", item: item)
        let restored = try #require(stored.makeAttachmentItem())

        #expect(stored.roomId == "!room:example.org")
        #expect(restored.id == item.id)
        #expect(restored.kind == item.kind)
        #expect(restored.timestampMs == item.timestampMs)
        #expect(restored.filename == item.filename)
        #expect(restored.blurhash == item.blurhash)
        #expect(restored.sourceMxc == item.sourceMxc)
        #expect(restored.isSourceEncrypted == item.isSourceEncrypted)
        #expect(restored.thumbnail?.mxc == item.thumbnail?.mxc)
        #expect(restored.thumbnail?.isEncrypted == item.thumbnail?.isEncrypted)
        #expect(restored.thumbnail?.sizeBytes == item.thumbnail?.sizeBytes)
    }

    @Test("Incomplete observations preserve richer metadata for the same source")
    func projectionMerge() throws {
        let source = try MediaSource.fromUrl(url: "mxc://example.org/original")
        let thumbnailSource = try MediaSource.fromUrl(url: "mxc://example.org/thumbnail")
        let item = AttachmentItem(
            id: "$event",
            uniqueId: "timeline-item",
            kind: .image,
            timestampMs: 1_789_473_600_123,
            sender: "@alice:example.org",
            senderName: "Alice",
            isOwn: false,
            filename: "photo.jpg",
            caption: "Old caption",
            mimetype: "image/jpeg",
            sizeBytes: 42_000,
            pixelWidth: 1600,
            pixelHeight: 900,
            durationSeconds: nil,
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
            isAnimated: false,
            source: source,
            sourceMxc: source.url(),
            isSourceEncrypted: false,
            thumbnail: AttachmentItem.ThumbnailRef(
                source: thumbnailSource,
                mxc: thumbnailSource.url(),
                isEncrypted: false,
                width: 320,
                height: 180,
                sizeBytes: 4_200,
                mimetype: "image/jpeg"
            )
        )
        let existing = StoredRoomAttachment(roomId: "!room:example.org", item: item)
        var incoming = existing
        incoming.senderDisplayName = nil
        incoming.caption = nil
        incoming.mimetype = nil
        incoming.sizeBytes = nil
        incoming.pixelWidth = nil
        incoming.pixelHeight = nil
        incoming.blurhash = nil
        incoming.thumbnailSourceJSON = nil
        incoming.thumbnailIsEncrypted = nil
        incoming.thumbnailWidth = nil
        incoming.thumbnailHeight = nil
        incoming.thumbnailSizeBytes = nil
        incoming.thumbnailMimetype = nil

        let merged = incoming.mergingMetadata(from: existing)

        #expect(merged.senderDisplayName == "Alice")
        #expect(merged.caption == nil) // Caption removals remain authoritative.
        #expect(merged.mimetype == "image/jpeg")
        #expect(merged.sizeBytes == 42_000)
        #expect(merged.pixelWidth == 1600)
        #expect(merged.pixelHeight == 900)
        #expect(merged.blurhash == item.blurhash)
        #expect(merged.thumbnailSourceJSON == existing.thumbnailSourceJSON)
        #expect(merged.thumbnailWidth == 320)

        incoming.sourceJSON = try MediaSource
            .fromUrl(url: "mxc://example.org/replacement")
            .toJson()
        let replacement = incoming.mergingMetadata(from: existing)
        #expect(replacement.pixelWidth == nil)
        #expect(replacement.thumbnailSourceJSON == nil)
    }

    @Test("New discoveries stay visible until the durable index acknowledges them")
    func optimisticDiscoveryLifecycle() throws {
        let record = try makeRecord(eventId: "event")
        var state = RoomAttachmentCatalogState()

        state.upsertOptimistically([record])
        #expect(state.visibleRecords.map(\.eventId) == ["event"])

        var sparse = record
        sparse.sizeBytes = nil
        sparse.pixelWidth = nil
        sparse.pixelHeight = nil
        state.upsertOptimistically([sparse])
        #expect(state.visibleRecords.first?.sizeBytes == record.sizeBytes)
        #expect(state.visibleRecords.first?.pixelWidth == record.pixelWidth)

        // An older initial observation must not erase the pending discovery.
        state.replaceIndexed(with: [])
        #expect(state.hasIndexedSnapshot)
        #expect(state.visibleRecords.map(\.eventId) == ["event"])

        // Once GRDB contains it, the durable row replaces the overlay.
        state.replaceIndexed(with: [record])
        #expect(state.visibleRecords.map(\.eventId) == ["event"])

        // Replaying an already indexed value must not rebuild the catalog.
        let repeatedDiscoveryChanged = state.upsertOptimistically([record])
        #expect(!repeatedDiscoveryChanged)
    }

    @Test("Explicit invalidations stay hidden until GRDB confirms deletion")
    func optimisticInvalidationLifecycle() throws {
        let record = try makeRecord(eventId: "event")
        var state = RoomAttachmentCatalogState()
        state.replaceIndexed(with: [record])

        state.invalidate(eventIds: [record.eventId])
        #expect(state.visibleRecords.isEmpty)

        // An unrelated commit can publish the old row while its delete is
        // queued. The tombstone prevents a temporary resurrection.
        state.replaceIndexed(with: [record])
        #expect(state.visibleRecords.isEmpty)

        state.replaceIndexed(with: [])
        state.upsertOptimistically([record])
        #expect(state.visibleRecords.map(\.eventId) == ["event"])

        let invalidated = state.invalidate(eventIds: [record.eventId])
        #expect(invalidated)
        #expect(state.visibleRecords.isEmpty)
        let repeatedInvalidationChanged = state.invalidate(eventIds: [record.eventId])
        #expect(!repeatedInvalidationChanged)
    }
}
