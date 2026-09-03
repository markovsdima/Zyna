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
        kind: AttachmentItem.Kind = .image,
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

    @Test("Snapshot lists media newest first and splits files")
    func snapshotOrderAndSplit() throws {
        let store = AttachmentTimelineStore(publishDelay: 0)
        let summary = store.apply([.reset([
            try attachment("old", timestampMs: Self.may2026Ms),
            .other(uniqueId: "text"),
            try attachment("doc", kind: .file),
            try attachment("new")
        ])])
        #expect(summary.resets == 1)

        let snapshot = store.currentSnapshot()
        #expect(snapshot.rowCount == 4)
        #expect(snapshot.mediaCount == 2)
        #expect(snapshot.fileCount == 1)
        #expect(snapshot.media.map(\.id) == ["2026-09", "2026-05"])
        #expect(snapshot.media.first?.items.map(\.id) == ["new"])
        #expect(snapshot.media.last?.items.map(\.id) == ["old"])
        #expect(snapshot.files.first?.items.map(\.id) == ["doc"])
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

    @Test("Decrypting into a non-attachment removes the tile")
    func mediaReplacedByOther() throws {
        let store = AttachmentTimelineStore(publishDelay: 0)
        store.apply([.reset([try attachment("a"), try attachment("b")])])
        let summary = store.apply([.set(0, .other(uniqueId: "u-a"))])
        #expect(summary.mediaRemoved == ["a"])
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
