//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import Foundation
import MatrixRustSDK
@testable import Zyna

@Suite("AttachmentTimelineStore")
struct AttachmentTimelineStoreTests {

    /// 2026-09-15T12:00:00Z and 2026-05-15T12:00:00Z: mid-month, so the
    /// month is the same in every time zone.
    private static let september2026Ms: UInt64 = 1789473600_000
    private static let may2026Ms: UInt64 = 1778846400_000

    private func attachment(
        _ id: String,
        kind: RoomAttachmentKind = .image,
        timestampMs: UInt64 = september2026Ms
    ) throws -> AttachmentRow {
        let source = try MediaSource.fromUrl(url: "mxc://example.org/\(id)")
        return .attachment(AttachmentItem(
            id: id,
            uniqueId: "u-\(id)",
            kind: kind,
            timestampMs: timestampMs,
            sender: "@alice:example.org",
            senderName: nil,
            isOwn: false,
            filename: "\(id).bin",
            caption: nil,
            mimetype: nil,
            sizeBytes: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            durationSeconds: nil,
            blurhash: nil,
            isAnimated: false,
            source: source,
            sourceMxc: source.url(),
            isSourceEncrypted: true,
            thumbnail: nil
        ))
    }

    private func pending(_ id: String, sessionId: String? = "session-1") -> AttachmentRow {
        .pendingDecryption(PendingDecryption(
            uniqueId: "u-\(id)", eventId: id, sessionId: sessionId,
            timestampMs: Self.september2026Ms, cause: "unknown"
        ))
    }

    @Test("Count-only snapshots match presentation counts through every SDK vector mutation")
    func metadataCounts() throws {
        let legacy = AttachmentTimelineStore(), light = AttachmentTimelineStore(metadataOnly: true)
        let seed: [AttachmentRow] = [
            try attachment("image"), try attachment("file", kind: .file), try attachment("voice", kind: .voice),
            pending("first"), pending("second"), pending("third", sessionId: nil), .other(uniqueId: "text")
        ]
        func apply(_ diffs: [AttachmentRowDiff]) {
            legacy.apply(diffs); light.apply(diffs)
            let expected = legacy.currentSnapshot(), actual = light.currentSnapshot()
            #expect(actual.rowCount == expected.rowCount)
            #expect(actual.mediaCount == expected.mediaCount)
            #expect(actual.fileCount == expected.fileCount)
            #expect(actual.voiceCount == expected.voiceCount)
            #expect(actual.pendingCount == expected.pendingCount)
            #expect(actual.pendingSessionIds == expected.pendingSessionIds)
            #expect(actual.media.isEmpty && actual.files.isEmpty && actual.voice.isEmpty)
        }
        for _ in 0..<30 {
            apply([.reset(seed)])
            apply([.set(3, seed[2]), .set(4, pending("new", sessionId: "session-2"))])
            apply([.append(seed), .pushFront(seed[4]), .pushBack(seed[1])])
            apply([.insert(2, seed[5]), .set(1, seed[6]), .remove(4), .popFront, .popBack])
            apply([.truncate(4)])
            apply([.clear])
        }
    }

    @Test("Count-only discovery skips repeated SDK sets but persists changed metadata")
    func metadataDeduplication() throws {
        let item = try #require(try attachment("stable", kind: .file).attachment)
        let base = StoredRoomAttachment(roomId: "!dedup:example.org", item: item)
        let original = try #require(base.makeAttachmentItem())
        let store = AttachmentTimelineStore(metadataOnly: true)
        var discoveries: [AttachmentItem] = []
        store.onAttachmentsDiscovered = { discoveries += $0 }
        store.apply([.reset([.attachment(original)])])
        discoveries.removeAll()
        store.apply((0..<100).map { _ in .set(0, .attachment(base.makeAttachmentItem()!)) })
        #expect(discoveries.isEmpty)
        let changes: [(inout StoredRoomAttachment) -> Void] = [
            { $0.filename = "Renamed" }, { $0.caption = "Caption" },
            { $0.senderId = "@bob:example.org" }, { $0.senderDisplayName = "Bob" },
            { $0.isOutgoing = true }, { $0.kind = "voice" }, { $0.timestampMs += 1 },
            { $0.mimetype = "audio/ogg" }, { $0.sizeBytes = 42 },
            { $0.pixelWidth = 300 }, { $0.pixelHeight = 200 }, { $0.durationSeconds = 12 },
            { $0.blurhash = "hash" }, { $0.isAnimated = true }, { $0.isSourceEncrypted = false },
            { $0.sourceJSON = try! MediaSource.fromUrl(url: "mxc://example.org/replacement").toJson() }
        ]
        for change in changes {
            store.apply([.set(0, .attachment(original))])
            discoveries.removeAll()
            var record = base; change(&record)
            let changed = try #require(record.makeAttachmentItem())
            #expect(changed != original)
            store.apply([.set(0, .attachment(changed)), .set(0, .attachment(changed))])
            #expect(discoveries == [changed])
        }
        var thumbnail = base
        thumbnail.thumbnailSourceJSON = try MediaSource.fromUrl(url: "mxc://example.org/preview").toJson()
        let withThumbnail = try #require(thumbnail.makeAttachmentItem())
        let thumbnailChanges: [(inout StoredRoomAttachment) -> Void] = [
            { $0.thumbnailWidth = 100 }, { $0.thumbnailHeight = 50 },
            { $0.thumbnailSizeBytes = 1000 }, { $0.thumbnailMimetype = "image/png" },
            { $0.thumbnailIsEncrypted = true }
        ]
        for change in thumbnailChanges {
            store.apply([.set(0, .attachment(withThumbnail))])
            discoveries.removeAll()
            var record = thumbnail; change(&record)
            let changed = try #require(record.makeAttachmentItem())
            store.apply([.set(0, .attachment(changed)), .set(0, .attachment(changed))])
            #expect(discoveries == [changed])
        }
        #expect(store.currentRows.first?.attachment == nil)
    }

    @Test("Snapshot lists media newest first and splits voice from files")
    func snapshotOrderAndSplit() throws {
        let store = AttachmentTimelineStore(publishDelay: 0)
        let summary = store.apply([.reset([
            try attachment("old", timestampMs: Self.may2026Ms),
            .other(uniqueId: "text"),
            try attachment("doc", kind: .file),
            try attachment("voice", kind: .voice),
            try attachment("audio", kind: .audio),
            try attachment("new")
        ])])
        #expect(summary.resets == 1)

        let snapshot = store.currentSnapshot()
        #expect(snapshot.rowCount == 6)
        #expect(snapshot.mediaCount == 2)
        #expect(snapshot.voiceCount == 1)
        #expect(snapshot.fileCount == 2)
        #expect(snapshot.media.map(\.id) == ["2026-09", "2026-05"])
        #expect(snapshot.media.first?.items.map(\.id) == ["new"])
        #expect(snapshot.media.last?.items.map(\.id) == ["old"])
        #expect(snapshot.voice.first?.items.map(\.id) == ["voice"])
        #expect(snapshot.files.first?.items.map(\.id) == ["audio", "doc"])
    }

    @Test("Late decryption replaces a pending row in place")
    func lateDecryption() throws {
        let store = AttachmentTimelineStore(publishDelay: 0)
        store.apply([.reset([try attachment("a"), pending("utd"), try attachment("b")])])
        var snapshot = store.currentSnapshot()
        #expect(snapshot.pendingCount == 1)
        #expect(snapshot.pendingSessionIds == ["session-1"])
        #expect(snapshot.media.first?.items.map(\.id) == ["b", "a"])

        let summary = store.apply([.set(1, try attachment("utd"))])
        #expect(summary.utdResolvedToMedia == ["utd"])
        snapshot = store.currentSnapshot()
        #expect(snapshot.pendingCount == 0)
        #expect(snapshot.pendingSessionIds.isEmpty)
        #expect(snapshot.media.first?.items.map(\.id) == ["b", "utd", "a"])
    }

    @Test("Paged media discovery keeps counts and callbacks without publishing a second media array")
    func pagedProjection() throws {
        let store = AttachmentTimelineStore(publishDelay: 0, projectsMedia: false)
        var discovered: [String] = []
        store.onAttachmentsDiscovered = { discovered += $0.map(\.id) }
        store.apply([.reset([try attachment("photo"), pending("utd"), try attachment("doc", kind: .file)])])
        store.apply([.set(1, try attachment("utd", kind: .video))])
        let snapshot = store.currentSnapshot()
        #expect(snapshot.media.isEmpty)
        #expect(snapshot.mediaCount == 2 && snapshot.fileCount == 1)
        #expect(snapshot.pendingCount == 0)
        #expect(Set(discovered) == ["photo", "doc", "utd"])
        #expect(snapshot.files.first?.items.first?.id == "doc")
    }

    @Test("Decrypting into a non-attachment removes the tile")
    func mediaReplacedByOther() throws {
        let store = AttachmentTimelineStore(publishDelay: 0)
        var invalidated: [String] = []
        store.onAttachmentsInvalidated = { invalidated += $0 }
        store.apply([.reset([try attachment("a"), try attachment("b")])])
        let summary = store.apply([.set(0, .other(uniqueId: "u-a"))])
        #expect(summary.mediaRemoved == ["a"])
        #expect(invalidated == ["a"])
        #expect(store.currentSnapshot().mediaCount == 1)
    }

    @Test("Positional diffs keep SDK order")
    func positionalDiffs() throws {
        let store = AttachmentTimelineStore(publishDelay: 0)
        store.apply([.reset([try attachment("a"), try attachment("b")])])
        store.apply([
            .pushFront(try attachment("front")),
            .pushBack(try attachment("back")),
            .insert(2, try attachment("mid"))
        ])
        #expect(store.currentRows.map(\.uniqueId) == ["u-front", "u-a", "u-mid", "u-b", "u-back"])

        var summary = store.apply([.remove(2), .popFront, .popBack])
        #expect(summary.removed == 3)
        #expect(summary.mediaRemoved == ["mid", "front", "back"])
        #expect(store.currentRows.map(\.uniqueId) == ["u-a", "u-b"])

        summary = store.apply([.truncate(1)])
        #expect(summary.mediaRemoved == ["b"])
        #expect(store.currentRows.map(\.uniqueId) == ["u-a"])

        summary = store.apply([.clear])
        #expect(summary.mediaRemoved == ["a"])
        #expect(store.currentRows.isEmpty)
    }

    @Test("Out-of-range indices are counted, not applied")
    func outOfRange() throws {
        let store = AttachmentTimelineStore(publishDelay: 0)
        store.apply([.reset([try attachment("a")])])
        let summary = store.apply([
            .set(5, try attachment("x")),
            .remove(9),
            .insert(3, try attachment("y")),
            .truncate(7)
        ])
        #expect(summary.indexErrors == 4)
        #expect(store.currentRows.count == 1)
    }

    @Test("Discovery reports values but window removal does not delete them")
    func discoveryIsMonotonic() throws {
        let store = AttachmentTimelineStore(publishDelay: 0)
        var discovered: [String] = []
        var invalidated: [String] = []
        store.onAttachmentsDiscovered = { items in
            discovered.append(contentsOf: items.map(\.id))
        }
        store.onAttachmentsInvalidated = { invalidated += $0 }

        store.apply([.reset([try attachment("a"), .other(uniqueId: "text")])])
        store.apply([.set(0, try attachment("a"))])
        store.apply([.pushBack(try attachment("b")), .popFront, .clear])

        #expect(discovered == ["a", "b"])
        #expect(invalidated.isEmpty)
    }

    @Test("Month grouping labels the current month")
    func currentMonthTitle() throws {
        let now = Date()
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
        guard case .attachment(let item) = try attachment("now", timestampMs: nowMs) else {
            Issue.record("expected attachment")
            return
        }
        let groups = AttachmentTimelineStore.groupByMonth([item], now: now)
        #expect(groups.count == 1)
        #expect(groups.first?.title == String(localized: "This Month"))
    }
}
