//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Chat redaction display transitions", .serialized)
@MainActor
struct ChatRedactionDisplayTests {
    @Test("Ordinary updates take the no-deletion path, then a live deletion still animates")
    func ordinaryThenDeleted() async throws {
        let original = TimelineWriteFixture.message(0)
        let (database, window, model) = try fixture([original])
        defer { model.cleanup() }
        var batches: [ChatViewModel.DetectedRedactionBatch] = []
        model.onRedactedDetected = { batches.append($0) }
        window.loadInitial()
        try await model.waitForPresentation()
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Edited'")
        }
        window.refresh(origin: .timelineFlush(.init(setCount: 1)))
        try await model.waitForPresentation()
        #expect(batches.isEmpty)
        #expect(model.messages.first?.content.textPreview == "Edited")
        try redact(original.id, in: database)
        window.refresh(origin: .timelineFlush(.init(setCount: 1, redactedUpsertCount: 1)))
        try await model.waitForPresentation()
        #expect(batches.map(\.messageIds) == [[original.id]])
        #expect(model.messages.count == 1)
        model.hideMessages([original.id])
        try await model.waitForPresentation()
        #expect(model.messages.isEmpty)
    }

    @Test("History redactions stay silent, including an already deleted row in the initial cache")
    func historyDeletion() async throws {
        var cached = TimelineWriteFixture.message(0)
        cached.contentType = "redacted"
        let original = TimelineWriteFixture.message(1)
        let (database, window, model) = try fixture([cached, original])
        defer { model.cleanup() }
        model.onRedactedDetected = { _ in Issue.record("Cached/history deletion animated as live") }
        window.loadInitial()
        try await model.waitForPresentation()
        #expect(model.messages.map(\.id) == [original.id])
        try redact(original.id, in: database)
        window.refresh(origin: .timelineFlush(.init(setCount: 1, includesUnreportedHistory: true)))
        try await model.waitForPresentation()
        #expect(model.messages.isEmpty)
        window.refresh()
        try await model.waitForPresentation()
        #expect(model.messages.isEmpty)
    }

    @Test("Hidden aliases survive a storage-ID change and can be restored")
    func hiddenAliases() async throws {
        let original = TimelineWriteFixture.message(0)
        let (database, window, model) = try fixture([original])
        defer { model.cleanup() }
        window.loadInitial()
        try await model.waitForPresentation()
        model.hideMessages([original.id])
        try await model.waitForPresentation()
        #expect(model.messages.isEmpty)
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET id = 'zz-renamed'")
        }
        window.refresh(origin: .timelineFlush(.init(setCount: 1)))
        try await model.waitForPresentation()
        #expect(model.messages.isEmpty)
        model.restoreMessages(["zz-renamed"])
        try await model.waitForPresentation()
        #expect(model.messages.map(\.eventId) == [original.eventId])
    }

    @Test("A pending animation keeps its original content when a redaction uses a new storage ID")
    func pendingAliases() async throws {
        let original = TimelineWriteFixture.message(0)
        let (database, window, model) = try fixture([original])
        defer { model.cleanup() }
        window.loadInitial()
        try await model.waitForPresentation()
        model.registerPendingAnimatedRedactions([original.id])
        var batches: [ChatViewModel.DetectedRedactionBatch] = []
        model.onRedactedDetected = { batches.append($0) }
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET id = 'zz-renamed', contentType = 'redacted', contentBody = NULL")
        }
        window.refresh(origin: .timelineFlush(.init(setCount: 1, redactedUpsertCount: 1)))
        try await model.waitForPresentation()
        #expect(batches.map(\.messageIds) == [["zz-renamed"]])
        #expect(model.messages.first?.content.textPreview == original.contentBody)
        model.hideMessages(["zz-renamed"])
        try await model.waitForPresentation()
        #expect(model.messages.isEmpty)
    }

    @Test("Media-group deletion keeps members and previews through the splash, then reflows",
          arguments: [false, true])
    func mediaGroup(localAnimation: Bool) async throws {
        let images = (0..<3).map { index -> StoredMessage in
            var record = TimelineWriteFixture.message(index)
            record.contentType = "image"
            record.contentBody = nil
            record.contentMediaJSON = "{\"url\":\"mxc://example.org/image-\(index)\"}"
            // Avoid speculative image requests in this model-only fixture.
            record.contentMediaIsEncrypted = true
            record.contentImageWidth = 100
            record.contentImageHeight = 100
            record.zynaAttributesJSON = StoredMessage.encodeZynaAttributes(.init(mediaGroup: .init(
                id: "group", index: index, total: 3, captionMode: .replicated, captionPlacement: .bottom)))
            return record
        }
        let (database, window, model) = try fixture(images)
        defer { model.cleanup() }
        window.loadInitial()
        try await model.waitForPresentation()
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.mediaGroupPresentation?.items.count == 3)
        // The composite bubble is anchored to one visible message. Exercise
        // its deletion animation; other members have no standalone row.
        let target = try #require(images.first { $0.id == model.messages.first?.id })
        if localAnimation { model.registerPendingAnimatedRedactions([target.id]) }
        let preview = Data([1, 2, 3])
        model.registerPartialReflowPreviews([images[0].id: preview])
        // A normal snapshot must retain active partial state, even though
        // no deletion is present and the expensive identity index is skipped.
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET senderDisplayName = 'Updated' WHERE id = ?",
                           arguments: [images[2].id])
        }
        window.refresh(origin: .timelineFlush(.init(setCount: 1)))
        try await model.waitForPresentation()
        #expect(model.messages.first?.mediaGroupPresentation?.items.count == 3)
        var batches: [ChatViewModel.DetectedRedactionBatch] = []
        model.onRedactedDetected = { batches.append($0) }
        try redact(target.id, in: database)
        window.refresh(origin: .timelineFlush(.init(setCount: 1, redactedUpsertCount: 1)))
        try await model.waitForPresentation()
        let batch = try #require(batches.first)
        #expect(batch.messageIds == [target.id])
        #expect(batch.mediaGroups.first?.allMessageIds == Set(images.map(\.id)))
        #expect(batch.mediaGroups.first?.remainingCountAfter == 2)
        #expect(model.messages.first?.mediaGroupPresentation?.items.count == 3)
        model.hideMessages(batch.messageIds)
        try await model.waitForPresentation()
        let group = try #require(model.messages.first?.mediaGroupPresentation)
        #expect(group.rendersCompositeBubble)
        #expect(group.items.count == 2)
        #expect(!group.items.contains { $0.messageId == target.id })
        #expect(group.items.first { $0.messageId == images[0].id }?.previewImageData == preview)
        window.refresh()
        try await model.waitForPresentation()
        #expect(batches.count == 1)
    }

    private func fixture(_ records: [StoredMessage]) throws -> (AccountDatabase, MessageWindow, ChatViewModel) {
        let database = AccountDatabase(try DatabaseQueue())
        let roomID = "!redaction-display-\(UUID().uuidString):example.org"
        let columns = Mirror(reflecting: records[0]).children.compactMap(\.label)
        try database.write { db in
            let definitions = columns.map {
                $0 == "id" ? "\"id\" TEXT PRIMARY KEY" : $0 == "timestamp" ? "\"timestamp\" REAL" : "\"\($0)\""
            }
            try db.execute(sql: "CREATE TABLE storedMessage (\(definitions.joined(separator: ",")))")
            for var record in records { record.roomId = roomID; try record.insert(db) }
        }
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        return (database, window, ChatViewModel(testingRoomId: roomID, dbQueue: database, window: window))
    }

    private func redact(_ id: String, in database: AccountDatabase) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted', contentBody = NULL WHERE id = ?",
                           arguments: [id])
        }
    }
}
