// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import MatrixRustSDK
import Testing
@testable import Zyna

private func ignoredDatabase() throws -> AccountDatabase {
    let queue = try DatabaseQueue()
    try DatabaseService.migrator.migrate(queue)
    return AccountDatabase(queue)
}

private final class IgnoredWriteHandle: TaskHandle, @unchecked Sendable {
    override func cancel() { }
}

private final class IgnoredWriteClient: Client, @unchecked Sendable {
    let reads = Atomic(0)
    let writes = Atomic<[Bool]>([])
    var writeFails = false
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func ignoredUsers() async throws -> [String] {
        reads.modify { $0 += 1 }
        throw ContentReportFailure.unavailable
    }
    override func ignoreUser(userId: String) async throws {
        if writeFails { throw ContentReportFailure.unavailable }
        writes.modify { $0.append(true) }
    }
    override func unignoreUser(userId: String) async throws {
        if writeFails { throw ContentReportFailure.unavailable }
        writes.modify { $0.append(false) }
    }
    override func subscribeToIgnoredUsers(listener: any IgnoredUsersListener) -> TaskHandle {
        IgnoredWriteHandle(noHandle: .init())
    }
}

@Suite("Blocked cached content", .serialized)
struct IgnoredContentTests {
    private let blocked = "@alice:example.org"

    @MainActor
    @Test("Blocking hides cached history, rejects an old page and restores records on unblock")
    func history() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        try await db.write { db in
            for i in 0..<260 {
                var message = TimelineWriteFixture.message(i)
                message.senderId = i % 2 == 0 ? blocked : "@bob:example.org"
                try message.insert(db)
            }
        }
        let window = MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: db)
        let initial = window.replacementRequest(.newest)
        let initialPage = try await Task.detached { try initial.fetch() }.value
        #expect(window.applyReplacement(try #require(initialPage)))
        let oldRequest = try #require(window.pageRequest(.older))
        let stale = try await Task.detached { try oldRequest.fetch() }.value
        try await db.write { try IgnoredContentStore.replace([blocked], in: $0) }
        window.invalidatePendingReads()
        #expect(!window.applyPage(stale))
        // Even a request prepared from a retained pre-block window must not
        // merge blocked records back into its visible page.
        let afterBlock = try #require(window.pageRequest(.older))
        let page = try await Task.detached { try afterBlock.fetch() }.value
        #expect(window.applyPage(page))
        #expect(window.currentStoredMessages().allSatisfy { $0.senderId != blocked })
        #expect(try await db.read { try StoredMessage.fetchCount($0) } == 260)
        #expect(try await db.read { try StoredMessage.visible.fetchCount($0) } == 130)
        let hidden = window.replacementRequest(.event("$event-250"))
        let hiddenPage = try await Task.detached { try hidden.fetch() }.value
        #expect(hiddenPage == nil)
        try await db.write { try IgnoredContentStore.replace([], in: $0) }
        let restored = window.replacementRequest(.newest)
        let restoredPage = try await Task.detached { try restored.fetch() }.value
        #expect(window.applyReplacement(try #require(restoredPage)))
        #expect(window.currentStoredMessages().contains { $0.senderId == blocked })
    }

    @Test("Blocked pins disappear instead of becoming unloaded placeholders and return after unblock")
    func pinnedMessages() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        try await db.write { db in
            for i in 0..<2 {
                var message = TimelineWriteFixture.message(i)
                message.senderId = i == 0 ? blocked : "@bob:example.org"
                try message.insert(db)
            }
            try IgnoredContentStore.replace([blocked], in: db)
        }
        let eventIDs = ["$event-0", "$event-1", "$not-loaded"]
        let items = await Task.detached {
            PinnedMessagesViewController.buildItems(eventIds: eventIDs,
                roomId: TimelineWriteFixture.roomID, database: db)
        }.value
        #expect(items.map(\.eventId) == ["$event-1", "$not-loaded"])
        #expect(items.map(\.isLoadedLocally) == [true, false])
        let allHidden = await Task.detached {
            PinnedMessagesViewController.buildItems(eventIds: ["$event-0"],
                roomId: TimelineWriteFixture.roomID, database: db)
        }.value
        #expect(allHidden.isEmpty)
        try await db.write { try IgnoredContentStore.replace([], in: $0) }
        let restored = await Task.detached {
            PinnedMessagesViewController.buildItems(eventIds: eventIDs,
                roomId: TimelineWriteFixture.roomID, database: db)
        }.value
        #expect(restored.map(\.eventId) == eventIDs)
        #expect(restored.map(\.isLoadedLocally) == [true, true, false])
    }

    @Test("Media counts, order and payload pages use the same filtered catalog; unblock restores the cache")
    func media() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        let mediaJSON = try MediaSource.fromUrl(url: "mxc://example.org/image").toJson()
        try await db.write { db in
            for i in 0..<8 {
                try db.execute(sql: """
                    INSERT INTO roomAttachment (roomId, eventId, kind, timestampMs, senderId, isOutgoing, filename, sourceJSON)
                    VALUES ('!media:example.org', ?, 'image', ?, ?, 0, 'photo', ?)
                    """, arguments: ["$media\(i)", 1_790_784_000_000 + i,
                                      i % 2 == 0 ? blocked : "@bob:example.org",
                                      mediaJSON])
            }
        }
        let source = RoomMediaDatabase(database: db, roomID: "!media:example.org")
        let initial = try await db.read { try source.snapshot(in: $0) }
        #expect(initial.count == 8)
        try await db.write { try IgnoredContentStore.replace([blocked], in: $0) }
        let snapshot = try await db.read { try source.snapshot(in: $0) }
        #expect(snapshot.count == 4)
        #expect(snapshot.order.id(at: 0) == "$media7")
        #expect(snapshot.order.id(at: 3) == "$media1")
        await #expect(throws: RoomMediaDatabase.CatalogError.self) {
            try await source.page(0..<8, snapshot: initial)
        }
        let payloads = try await source.page(0..<4, snapshot: snapshot)
        #expect(payloads.count == 4)
        #expect(payloads.values.allSatisfy { $0.sender != blocked })
        let records = try await db.read { try StoredRoomAttachment.fetchAll(in: $0, roomId: "!media:example.org") }
        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.senderId != blocked })
        try await db.read { db in
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + RoomMediaDatabase.identityQuery,
                                      arguments: ["!media:example.org"]).map { $0["detail"] as String }
            #expect(plan.contains { $0.contains("COVERING INDEX idx_roomAttachment_visual_order") })
            #expect(!plan.contains { $0.contains("TEMP B-TREE") })
            #expect(try StoredRoomAttachment.fetchCount(db) == 8)
        }
        let changed = try await db.write { try IgnoredContentStore.replace([blocked], in: $0) }
        #expect(!changed)
        let unchanged = try await db.read { try source.snapshot(in: $0) }
        #expect(unchanged.revision == snapshot.revision)
        try await db.write { try IgnoredContentStore.replace([], in: $0) }
        #expect(try await db.read { try source.snapshot(in: $0) }.count == 8)
    }

    @Test("Polls and reply previews hide ignored content without rewriting the source record")
    func relatedContent() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        try await db.write { db in
            var poll = RoomPollFixture.poll("$poll").record!
            try PollStore.ingest(&poll, in: db)
            try IgnoredContentStore.replace([blocked], in: db)
            #expect(try PollStore.fetchPolls(in: db, roomId: RoomPollFixture.roomID, limit: 20).isEmpty)
            try IgnoredContentStore.replace([], in: db)
            #expect(try PollStore.fetchPolls(in: db, roomId: RoomPollFixture.roomID, limit: 20).count == 1)
        }
        var reply = TimelineWriteFixture.message(1)
        reply.replySenderId = blocked; reply.replyEventId = "$quoted"; reply.replyBody = "Hidden quote"
        #expect(reply.hidingIgnoredReply([blocked]).toChatMessage()?.replyInfo == nil)
        #expect(reply.replyBody == "Hidden quote")
        #expect(reply.hidingIgnoredReply([]).toChatMessage()?.replyInfo?.body == "Hidden quote")
    }

    @Test("Starting a refresh never waits for its GET; confirmed changes invalidate its older result")
    func backgroundRead() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        try await db.write { try IgnoredContentStore.replace(["@existing:example.org"], in: $0) }
        let source = PersonTestBlockingSource(), gate = ProfileTestRequest<[String]>()
        source.state.modify { $0.read = gate }
        let service = IgnoredContentService(client: Client(noHandle: .init()), database: db, source: source)
        defer { service.stop() }
        service.start(); service.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.isPending), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.isPending)
        #expect(source.state.wrappedValue.reads == 1)
        #expect(try await service.storedUserIDs() == ["@existing:example.org"])
        async let first: Void = service.applyConfirmedChange(userID: blocked, isIgnored: true)
        async let second: Void = service.applyConfirmedChange(userID: "@other:example.org", isIgnored: true)
        _ = await (first, second)
        await gate.finish([])
        await service.waitForInitialReadForTesting()
        #expect(try await service.storedUserIDs() == ["@existing:example.org", blocked, "@other:example.org"])
        await service.applyConfirmedChange(userID: blocked, isIgnored: false)
        #expect(try await service.storedUserIDs() == ["@existing:example.org", "@other:example.org"])
    }

    @Test("A confirmed delta preserves preceding sync changes to other users")
    func snapshotThenDelta() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        let source = PersonTestBlockingSource()
        let service = IgnoredContentService(client: Client(noHandle: .init()), database: db, source: source)
        defer { service.stop() }
        source.send(["@remote:example.org"])
        await service.applyConfirmedChange(userID: blocked, isIgnored: true)
        #expect(try await service.storedUserIDs() == ["@remote:example.org", blocked])
        // A later sync remains authoritative; only the following local delta
        // is merged on top of it, without resurrecting earlier local writes.
        source.send(["@remote:example.org"])
        await service.applyConfirmedChange(userID: "@next:example.org", isIgnored: true)
        #expect(try await service.storedUserIDs() == ["@remote:example.org", "@next:example.org"])
    }

    @Test("An acknowledged block/unblock needs no GET and keeps unrelated ignored users")
    func confirmedWrites() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        try await db.write { try IgnoredContentStore.replace(["@existing:example.org"], in: $0) }
        let client = IgnoredWriteClient()
        let visibility = IgnoredContentService(client: client, database: db)
        defer { visibility.stop() }
        let service = IgnoredUsersService(client: client, visibility: { _ in visibility })
        try await service.ignore(userId: blocked)
        #expect(try await visibility.storedUserIDs() == ["@existing:example.org", blocked])
        try await service.unignore(userId: blocked)
        #expect(try await visibility.storedUserIDs() == ["@existing:example.org"])
        #expect(client.reads.wrappedValue == 0)
        #expect(client.writes.wrappedValue == [true, false])
        client.writeFails = true
        await #expect(throws: ContentReportFailure.self) { try await service.ignore(userId: blocked) }
        #expect(try await visibility.storedUserIDs() == ["@existing:example.org"])
    }

    @Test("A local cache failure cannot report an acknowledged server block as failed")
    func cacheFailure() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        try await db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_ignored_insert BEFORE INSERT ON ignoredUser
                BEGIN SELECT RAISE(ABORT, 'test cache failure'); END;
                """)
        }
        let client = IgnoredWriteClient()
        let visibility = IgnoredContentService(client: client, database: db)
        defer { visibility.stop() }
        let service = IgnoredUsersService(client: client, visibility: { _ in visibility })
        try await service.ignore(userId: blocked)
        #expect(client.writes.wrappedValue == [true])
        #expect(client.reads.wrappedValue == 0)
    }

    @Test("Hidden space previews survive rollups, persistence and repeated block/unblock without SDK children")
    func spacePreviews() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        func summary(_ id: String, isSpace: Bool, message: String? = nil) -> RoomSummary {
            RoomSummary(id: id, displayName: id, avatarURL: nil,
                lastMessage: message, lastMessageSenderID: message == nil ? nil : blocked,
                lastMessageSenderName: message == nil ? nil : "Alice",
                lastMessageTimestamp: message == nil ? nil : Date(timeIntervalSince1970: 100),
                lastOwnMessageStatus: nil, unreadCount: 0, unreadMentionCount: 0, isMarkedUnread: false,
                isEncrypted: false, isSpace: isSpace, isMuted: false, directUserId: nil,
                spaceChildRoomCount: 0, spaceChildSpaceCount: 0, spaceRecentRooms: [], spaceMetadata: nil)
        }
        let root = summary("!space:example.org", isSpace: true)
        let child = summary("!child:example.org", isSpace: false, message: "Cached text")
        let hidden = child.hidingIgnoredPreview([blocked]).hidingIgnoredPreview([blocked])
        #expect(hidden.lastMessage == nil)
        let rollup = try #require(ZynaRoomListService.enrichSpaceSummaries([root],
            cachedSpaceChildSummariesBySpaceId: [root.id: [hidden]],
            cachedSpaceChildSpaceSummariesBySpaceId: [:]).first)
        #expect(rollup.lastMessage == nil)
        #expect(rollup.hidingIgnoredPreview([]).lastMessage == "Cached text")
        try await db.write { db in
            try StoredRoom(from: rollup, sortOrder: 0).insert(db)
            try StoredSpaceChild(spaceId: root.id, summary: hidden, sortOrder: 0).insert(db)
        }
        let restored = try await db.read { db in
            (try StoredRoom.fetchOne(db)?.toRoomSummary(), try StoredSpaceChild.fetchOne(db)?.toRoomSummary())
        }
        #expect(restored.0?.lastMessage == "Cached text")
        #expect(restored.1?.lastMessage == "Cached text")
        #expect(restored.0?.hidingIgnoredPreview([blocked]).lastMessage == nil)
        let emptySDKChild = summary(child.id, isSpace: false)
        let rebuilt = try #require(ZynaRoomListService.enrichSpaceSummaries([root, emptySDKChild],
            cachedSpaceChildSummariesBySpaceId: [root.id: [hidden.hidingIgnoredPreview([])]],
            cachedSpaceChildSpaceSummariesBySpaceId: [:]).first)
        #expect(rebuilt.lastMessage == "Cached text")
    }

    @Test("A sync update wins over an older ignored-list read; stopping prevents a late write")
    func staleIgnoredRead() async throws {
        let db = try await Task.detached { try ignoredDatabase() }.value
        let source = PersonTestBlockingSource(), gate = ProfileTestRequest<[String]>()
        source.state.modify { $0.read = gate }
        let service = IgnoredContentService(client: Client(noHandle: .init()), database: db, source: source)
        service.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.isPending), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.isPending)
        source.send([blocked])
        await gate.finish([])
        await service.waitForInitialReadForTesting()
        #expect(try await db.read { try IgnoredContentStore.userIDs(in: $0) } == [blocked])
        source.state.modify { $0.read = nil; $0.ids = [] }
        service.stop()
        service.start()
        #expect(try await db.read { try IgnoredContentStore.userIDs(in: $0) } == [blocked])
    }
}
