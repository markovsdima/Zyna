//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import Foundation
import GRDB
import Testing
import UIKit
@testable import Zyna

@Suite("Chat history pagination", .serialized)
@MainActor
struct ChatHistoryPaginationTests {
    private let roomId = "!pagination:example.org"

    private func message(_ index: Int, timestamp: TimeInterval? = nil) -> StoredMessage {
        let id = String(format: "%04d", index)
        let message = ChatMessage(
            id: id, eventId: "$\(id)", transactionId: nil,
            itemIdentifier: .eventId("$\(id)"), senderId: "@alice:example.org",
            senderDisplayName: "Alice", senderAvatarUrl: nil, isOutgoing: false,
            timestamp: Date(timeIntervalSince1970: timestamp ?? Double(index)),
            content: .text(body: "Message \(id)"), reactions: [], replyInfo: nil,
            isEditable: false, isEdited: false, isEditPending: false,
            isEditFailed: false, latestEditEventId: nil,
            zynaAttributes: ZynaMessageAttributes(), sendStatus: "synced"
        )
        var stored = StoredMessage(from: message, roomId: roomId)
        stored.id = id
        return stored
    }

    private func database(_ records: [StoredMessage]) throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        // Include nullable record fields too, without copying the production
        // migrations for unrelated room, attachment and outbox tables.
        let columns = Mirror(reflecting: message(0)).children.compactMap(\.label)
        try database.write { db in
            let definitions = columns.map { column in
                switch column {
                case "id": return "\"id\" TEXT PRIMARY KEY"
                case "timestamp": return "\"timestamp\" REAL"
                default: return "\"\(column)\""
                }
            }
            try db.execute(sql: "CREATE TABLE storedMessage (\(definitions.joined(separator: ",")))")
            for record in records { try record.insert(db) }
        }
        return database
    }

    @Test("Equal timestamps paginate without gaps and retain earlier pages")
    func equalTimestamps() async throws {
        let records = (0..<420).map { message($0, timestamp: 1_000) }
        let database = try database(records)
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        #expect(window.currentStoredMessages().count == 200)
        var pages = 0
        while window.hasOlderInDB && pages < 10 {
            let request = try #require(window.pageRequest(.older))
            let page = try await Task.detached { try request.fetch() }.value
            #expect(window.applyPage(page))
            pages += 1
        }
        #expect(pages == 5)
        #expect(!window.hasOlderInDB)
        #expect(window.currentStoredMessages().map(\.id) == records.reversed().map(\.id))
    }

    @Test("Prepared apply and boundary lookup perform no further DB reads")
    func preparedApply() async throws {
        let database = try database((0..<300).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let request = try #require(window.pageRequest(.older))
        let page = try await Task.detached { try request.fetch() }.value
        try database.close()
        var changes = 0
        window.onChange = { records, _, origin in
            #expect(Thread.isMainThread)
            #expect(origin == .databasePagination)
            #expect(records.count == 250)
            #expect(window.peekOlderNeighbor()?.timestamp.timeIntervalSince1970 == 49)
            #expect(window.peekNewerNeighbor() == nil)
            changes += 1
        }
        #expect(window.applyPage(page))
        #expect(window.hasOlderInDB)
        #expect(changes == 1)
        window.onChange = nil
    }

    @Test("A refresh invalidates a prepared page and preserves updated content")
    func refreshDuringQuery() async throws {
        let database = try database((0..<300).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let request = try #require(window.pageRequest(.older))
        let page = try await Task.detached { try request.fetch() }.value
        var edited = message(299)
        edited.contentBody = "Edited while the page was loading"
        let editedRecord = edited
        let incoming = message(300)
        try await database.write { db in
            try editedRecord.update(db)
            try incoming.insert(db)
        }
        window.refresh()
        #expect(!window.applyPage(page))
        #expect(window.currentStoredMessages().first?.id == incoming.id)
        #expect(window.currentStoredMessages().first { $0.id == edited.id }?.contentBody == edited.contentBody)
        #expect(window.currentStoredMessages().count == 201)
    }

    @Test("A jump invalidates old requests even if they finish afterwards")
    func jumpDuringQuery() async throws {
        let database = try database((0..<500).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let generation = window.generation
        let request = try #require(window.pageRequest(.older))
        window.jumpToOldest()
        let page = try await Task.detached { try request.fetch() }.value
        #expect(window.generation != generation)
        #expect(!window.applyPage(page))
        #expect(window.currentStoredMessages().first?.id == "0199")
        #expect(window.currentStoredMessages().last?.id == "0000")
    }

    @Test("An entirely deduplicated page still advances the database cursor")
    func deduplicatedPageProgress() throws {
        var records = (0..<202).map { message($0, timestamp: 1_000) }
        records[201].isOutgoing = true
        records[201].contentBody = "Same outgoing message"
        records[1].isOutgoing = true
        records[1].contentBody = "Same outgoing message"
        records[1].eventId = nil
        records[1].transactionId = "pending"
        let database = try database(records)
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let first = try #require(window.pageRequest(.older, count: 1)).fetch()
        #expect(first.fetchedCount == 1)
        #expect(window.applyPage(first))
        #expect(window.currentStoredMessages().count == 200)
        let second = try #require(window.pageRequest(.older, count: 1)).fetch()
        #expect(window.applyPage(second))
        #expect(window.currentStoredMessages().last?.id == "0000")
        #expect(!window.hasOlderInDB)
    }

    @Test("Database failure is not reported as exhausted history")
    func databaseFailure() throws {
        let database = try database([message(0)])
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let request = try #require(window.pageRequest(.older))
        // A closed GRDB connection is programmer misuse and can trap.
        // A SQL error exercises the recoverable failure path instead.
        try database.write { db in try db.drop(table: "storedMessage") }
        #expect(throws: (any Error).self) { try request.fetch() }
    }

    @Test("Prefetch and Texture join one request until the table is ready")
    func joinedRequests() {
        let loader = ChatHistoryPageLoader()
        var fetches = 0
        var result: ((ChatHistoryPageLoader.Result) -> Void)?
        var tableReady: (() -> Void)?
        var completions: [ChatHistoryPageLoader.Result] = []
        let fetch: (@escaping (ChatHistoryPageLoader.Result) -> Void) -> Void = {
            fetches += 1
            result = $0
        }
        let wait: (@escaping () -> Void) -> Void = { tableReady = $0 }
        loader.load(fetch: fetch, waitForUpdates: wait) { completions.append($0) }
        loader.load(fetch: fetch, waitForUpdates: wait) { completions.append($0) }
        #expect(fetches == 1)
        result?(.applied)
        #expect(loader.isLoading)
        #expect(completions.isEmpty)
        loader.load(fetch: fetch, waitForUpdates: wait) { completions.append($0) }
        #expect(fetches == 1)
        tableReady?()
        #expect(!loader.isLoading)
        #expect(completions == [.applied, .applied, .applied])
    }

    @Test("A completion can start the next page without consuming its callbacks")
    func reentrantCompletion() {
        let loader = ChatHistoryPageLoader()
        var firstResult: ((ChatHistoryPageLoader.Result) -> Void)?
        var nextResult: ((ChatHistoryPageLoader.Result) -> Void)?
        var results: [ChatHistoryPageLoader.Result] = []
        loader.load(fetch: { firstResult = $0 }, waitForUpdates: { $0() }) { result in
            results.append(result)
            loader.load(fetch: { nextResult = $0 }, waitForUpdates: { $0() }) {
                results.append($0)
            }
        }
        firstResult?(.applied)
        #expect(loader.isLoading)
        #expect(results == [.applied])
        nextResult?(.exhausted)
        #expect(!loader.isLoading)
        #expect(results == [.applied, .exhausted])
    }

    @Test("An exhausted page waits for its boundary update in Texture")
    func exhaustedBoundaryUpdate() {
        let loader = ChatHistoryPageLoader()
        var tableReady: (() -> Void)?
        var result: ChatHistoryPageLoader.Result?
        loader.load(fetch: { $0(.exhausted) }, waitForUpdates: { tableReady = $0 }) {
            result = $0
        }
        #expect(loader.isLoading)
        #expect(result == nil)
        tableReady?()
        #expect(!loader.isLoading)
        #expect(result == .exhausted)
    }

    @Test("A late server completion cannot finish a reused Texture context")
    func reusedServerBatchContext() {
        let context = ASBatchContext()
        let wait = ChatServerBatchFetch()
        var firstCancellations = 0
        var secondCancellations = 0

        context.beginBatchFetching()
        let first = wait.begin(context: context)
        wait.setSubscription(AnyCancellable { firstCancellations += 1 }, for: first)
        wait.finish(first)
        #expect(!context.isFetching())
        #expect(firstCancellations == 1)

        context.beginBatchFetching()
        let second = wait.begin(context: context)
        wait.setSubscription(AnyCancellable { secondCancellations += 1 }, for: second)
        #expect(first != second)
        #expect(!wait.isCurrent(first))
        wait.finish(first)
        #expect(wait.isCurrent(second))
        #expect(context.isFetching())
        #expect(firstCancellations == 1)
        #expect(secondCancellations == 0)

        wait.finish(second)
        #expect(!wait.isActive)
        #expect(!context.isFetching())
        #expect(secondCancellations == 1)
    }

    @Test("A late subscription cannot replace the next server request's subscription")
    func lateServerSubscription() {
        let context = ASBatchContext()
        let wait = ChatServerBatchFetch()
        context.beginBatchFetching()
        let first = wait.begin(context: context)
        wait.finish(first)
        context.beginBatchFetching()
        let second = wait.begin(context: context)
        var lateCancellations = 0
        var currentCancellations = 0
        wait.setSubscription(AnyCancellable { currentCancellations += 1 }, for: second)
        wait.setSubscription(AnyCancellable { lateCancellations += 1 }, for: first)
        #expect(lateCancellations == 1)
        #expect(currentCancellations == 0)
        #expect(wait.isCurrent(second))
        #expect(context.isFetching())
        wait.finish(second)
        #expect(currentCancellations == 1)
    }

    @Test("Local prefetch is independent of SDK pagination and overscroll")
    func localEligibility() {
        #expect(ChatHistoryPageLoader.canFetch(hasLocal: true, serverBusy: true, serverExhausted: true))
        #expect(!ChatHistoryPageLoader.canFetch(hasLocal: false, serverBusy: true, serverExhausted: false))
        #expect(!ChatHistoryPageLoader.canFetch(hasLocal: false, serverBusy: false, serverExhausted: true))
        #expect(ChatHistoryPageLoader.shouldPrefetch(remaining: 1_000, viewportHeight: 800))
        #expect(ChatHistoryPageLoader.shouldPrefetch(remaining: -30, viewportHeight: 800))
        #expect(!ChatHistoryPageLoader.shouldPrefetch(remaining: 4_000, viewportHeight: 800))
        #expect(!ChatHistoryPageLoader.shouldPrefetch(remaining: 0, viewportHeight: 0))
    }

    @Test("Presentation cache copies preserve old content and accept edits")
    func presentationCache() {
        let record = message(1)
        var original = StoredMessagePresentationCache()
        #expect(original.message(for: record)?.content == .text(body: "Message 0001"))
        var edited = record
        edited.contentBody = "Edited"
        var copy = original
        copy.prepare([edited])
        #expect(copy.message(for: edited)?.content == .text(body: "Edited"))
        #expect(original.message(for: record)?.content == .text(body: "Message 0001"))
    }

    @Test("An unchanged SDK refresh keeps a local page valid and emits no update")
    func unchangedTimelineRefresh() async throws {
        let database = try database((0..<300).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        _ = window.peekOlderNeighbor()
        let olderRequest = try #require(window.pageRequest(.older))
        let refreshRequest = window.refreshRequest()
        let refresh = try await Task.detached { try refreshRequest.fetch() }.value
        var changes = 0
        window.onChange = { _, _, _ in changes += 1 }
        #expect(!refresh.contentChanged)
        #expect(window.applyRefresh(refresh, summary: TimelineFlushSummary(pushFrontCount: 1)))
        #expect(changes == 0)
        #expect(window.applyPage(try olderRequest.fetch()))
        #expect(changes == 1)
    }

    @Test("History changes beyond the boundary do not rebuild the current window")
    func refreshOutsideWindow() async throws {
        let database = try database((0..<300).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        _ = window.peekOlderNeighbor()
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Older edit' WHERE id = '0001'")
        }
        let request = window.refreshRequest()
        let page = try await Task.detached { try request.fetch() }.value
        var changes = 0
        window.onChange = { _, _, _ in changes += 1 }
        #expect(window.applyRefresh(page, summary: TimelineFlushSummary(pushFrontCount: 1)))
        #expect(changes == 0)
        #expect(window.hasOlderInDB)
    }

    @Test("A changed boundary updates clustering even if loaded records match")
    func refreshBoundary() async throws {
        let database = try database((0..<300).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        _ = window.peekOlderNeighbor()
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET senderId = '@bob:example.org' WHERE id = '0099'")
        }
        let request = window.refreshRequest()
        let page = try await Task.detached { try request.fetch() }.value
        #expect(!page.contentChanged)
        try database.close()
        var changes = 0
        window.onChange = { records, _, _ in
            #expect(records.count == 200)
            #expect(window.peekOlderNeighbor()?.senderId == "@bob:example.org")
            changes += 1
        }
        #expect(window.applyRefresh(page, summary: TimelineFlushSummary(setCount: 1)))
        #expect(changes == 1)
        window.onChange = nil
    }

    @Test("Refresh applies edits, reactions, receipts and new messages without main DB reads")
    func changedTimelineRefresh() async throws {
        let database = try database((0..<300).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let incoming = message(300)
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Edited', reactionsJSON = '[]', sendStatus = 'read' WHERE id = '0299'")
            try incoming.insert(db)
        }
        let request = window.refreshRequest()
        let page = try await Task.detached { try request.fetch() }.value
        #expect(page.contentChanged)
        try database.close()
        var changes = 0
        let summary = TimelineFlushSummary(pushBackCount: 1, setCount: 1, readReceiptCount: 1)
        window.onChange = { records, previous, origin in
            #expect(Thread.isMainThread)
            #expect(previous?.count == 200)
            #expect(records.count == 201)
            #expect(records.first?.id == "0300")
            #expect(records[1].contentBody == "Edited")
            #expect(records[1].reactionsJSON == "[]")
            #expect(records[1].sendStatus == "read")
            #expect(origin == .timelineFlush(summary))
            #expect(window.peekOlderNeighbor()?.timestamp.timeIntervalSince1970 == 99)
            changes += 1
        }
        #expect(window.applyRefresh(page, summary: summary))
        #expect(changes == 1)
        window.onChange = nil
    }

    @Test("A refresh cannot replace a page loaded while its snapshot was prepared")
    func pageDuringTimelineRefresh() async throws {
        let database = try database((0..<400).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let request = window.refreshRequest()
        let refresh = try await Task.detached { try request.fetch() }.value
        let older = try #require(window.pageRequest(.older)).fetch()
        #expect(window.applyPage(older))
        #expect(!window.applyRefresh(refresh, summary: TimelineFlushSummary(pushFrontCount: 1)))
        #expect(window.currentStoredMessages().count == 250)
        let nextRequest = window.refreshRequest()
        let nextRefresh = try await Task.detached { try nextRequest.fetch() }.value
        #expect(window.applyRefresh(nextRefresh, summary: TimelineFlushSummary(pushFrontCount: 1)))
        #expect(window.currentStoredMessages().count == 250)
    }

    @Test("An initial SDK refresh loads the window and cannot undo a later jump")
    func initialRefreshAndJump() async throws {
        let database = try database((0..<400).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        let initialRequest = window.refreshRequest()
        let initial = try await Task.detached { try initialRequest.fetch() }.value
        #expect(window.applyRefresh(initial, summary: TimelineFlushSummary(resetCount: 1)))
        #expect(window.currentStoredMessages().count == 200)
        #expect(window.currentStoredMessages().first?.id == "0399")
        let request = window.refreshRequest()
        let refresh = try await Task.detached { try request.fetch() }.value
        window.jumpToOldest()
        #expect(!window.applyRefresh(refresh, summary: TimelineFlushSummary(setCount: 1)))
        #expect(window.currentStoredMessages().first?.id == "0199")
        #expect(window.hasNewerInDB)
    }

    @Test("Metadata-only changes still notify the timeline", arguments: ["sendStatus", "reactionsJSON"])
    func metadataOnlyRefresh(column: String) async throws {
        let database = try database([message(1)])
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        _ = window.peekOlderNeighbor()
        let value = column == "sendStatus" ? "read" : "[{\"key\":\"👍\",\"count\":1}]"
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET \(column) = ?", arguments: [value])
        }
        let request = window.refreshRequest()
        let page = try await Task.detached { try request.fetch() }.value
        var changes = 0
        window.onChange = { _, _, _ in changes += 1 }
        #expect(page.contentChanged)
        #expect(window.applyRefresh(page, summary: TimelineFlushSummary(setCount: 1)))
        #expect(changes == 1)
    }

    @Test("Pending deletion reconciliation can notify with identical stored content")
    func forcedTimelineRefresh() async throws {
        let database = try database([message(1)])
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        _ = window.peekOlderNeighbor()
        let request = window.refreshRequest()
        let page = try await Task.detached { try request.fetch() }.value
        var changes = 0
        window.onChange = { _, _, _ in changes += 1 }
        #expect(!page.contentChanged)
        #expect(window.applyRefresh(page, summary: TimelineFlushSummary(setCount: 1), forceNotify: true))
        #expect(changes == 1)
    }

    @Test("A superseded refresh merges queued provenance before retrying")
    func coalescedTimelineRefresh() {
        var summaries: [TimelineFlushSummary] = []
        var finish: ((ChatTimelineRefreshQueue.Result) -> Void)?
        let queue = ChatTimelineRefreshQueue { summary, completion in
            summaries.append(summary)
            finish = completion
        }
        queue.enqueue(TimelineFlushSummary(setCount: 1))
        queue.enqueue(TimelineFlushSummary(pushFrontCount: 1))
        queue.enqueue(TimelineFlushSummary(readReceiptCount: 1))
        #expect(summaries.count == 1)
        #expect(queue.hasPending)
        finish?(.superseded)
        #expect(summaries.count == 2)
        #expect(summaries[1] == TimelineFlushSummary(pushFrontCount: 1, setCount: 1, readReceiptCount: 1))
        #expect(!summaries[1].allowsRemoteRedactionAnimation)
        #expect(!queue.hasPending)
        finish?(.applied)
        #expect(summaries.count == 2)
    }

    @Test("Closing the chat discards queued refreshes and late completions")
    func cancelledTimelineRefresh() {
        var starts = 0
        var finish: ((ChatTimelineRefreshQueue.Result) -> Void)?
        let queue = ChatTimelineRefreshQueue { _, completion in
            starts += 1
            finish = completion
        }
        queue.enqueue(TimelineFlushSummary(setCount: 1))
        queue.enqueue(TimelineFlushSummary(pushFrontCount: 1))
        queue.cancel()
        finish?(.superseded)
        queue.enqueue(TimelineFlushSummary(setCount: 1))
        #expect(starts == 1)
        #expect(!queue.hasPending)
    }

    @Test("A failed refresh retains provenance without a busy retry loop")
    func failedTimelineRefresh() {
        var summaries: [TimelineFlushSummary] = []
        var finish: ((ChatTimelineRefreshQueue.Result) -> Void)?
        let queue = ChatTimelineRefreshQueue { summary, completion in
            summaries.append(summary)
            finish = completion
        }
        queue.enqueue(TimelineFlushSummary(pushFrontCount: 1))
        finish?(.failed)
        #expect(summaries.count == 1)
        queue.enqueue(TimelineFlushSummary(setCount: 1))
        #expect(summaries.count == 2)
        #expect(!summaries[1].allowsRemoteRedactionAnimation)
        finish?(.applied)
    }

    @Test("Continuous flushes apply snapshots while preserving a follow-up read")
    func continuousTimelineRefresh() {
        var starts = 0
        var active = TimelineFlushSummary()
        var finish: ((ChatTimelineRefreshQueue.Result) -> Void)?
        let queue = ChatTimelineRefreshQueue { summary, completion in
            starts += 1
            active = summary
            finish = completion
        }
        queue.enqueue(TimelineFlushSummary(setCount: 1))
        var applied = 0
        for _ in 0..<10 {
            queue.enqueue(TimelineFlushSummary(pushFrontCount: 1))
            let effective = queue.summaryForApplying(active)
            #expect(!effective.allowsRemoteRedactionAnimation)
            #expect(queue.hasPending)
            applied += 1
            finish?(.applied)
            #expect(starts == applied + 1)
        }
        finish?(.applied)
        #expect(applied == 10)
        #expect(!queue.hasPending)
    }

    @Test("Superseded server reads retry but cannot establish exhaustion")
    func supersededServerRead() {
        #expect(ChatHistoryPageLoader.serverWaitAction(
            result: .superseded, attemptsRemaining: 3, displayCountIncreased: false
        ) == .retry)
        #expect(ChatHistoryPageLoader.serverWaitAction(
            result: .superseded, attemptsRemaining: 1, displayCountIncreased: false
        ) == .finish)
        #expect(ChatHistoryPageLoader.serverWaitAction(
            result: .exhausted, attemptsRemaining: 1, displayCountIncreased: false
        ) == .exhausted)
        #expect(ChatHistoryPageLoader.serverWaitAction(
            result: .exhausted, attemptsRemaining: 1, displayCountIncreased: true
        ) == .finish)
    }

    @Test("Jump, refresh and both pagination directions keep equal timestamps contiguous")
    func equalTimestampJump() throws {
        var records = (0..<420).map { message($0, timestamp: 1_000) }
        records[110].senderId = "@older:example.org"
        records[311].senderId = "@newer:example.org"
        let database = try database(records)
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.jumpTo(eventId: "$0210")
        let expected = Array(records[111...310].reversed().map(\.id))
        #expect(window.currentStoredMessages().map(\.id) == expected)
        #expect(window.hasOlderInDB && window.hasNewerInDB)
        #expect(window.peekOlderNeighbor()?.senderId == "@older:example.org")
        #expect(window.peekNewerNeighbor()?.senderId == "@newer:example.org")
        #expect(window.position(of: "$0110") == .olderThanCurrentWindow)
        #expect(window.position(of: "$0311") == .newerThanCurrentWindow)
        window.refresh()
        #expect(window.currentStoredMessages().map(\.id) == expected)
        for _ in 0..<10 where window.hasOlderInDB {
            #expect(window.applyPage(try #require(window.pageRequest(.older)).fetch()))
        }
        for _ in 0..<10 where window.hasNewerInDB {
            #expect(window.applyPage(try #require(window.pageRequest(.newer)).fetch()))
        }
        #expect(window.currentStoredMessages().map(\.id) == records.reversed().map(\.id))
        #expect(!window.hasOlderInDB && !window.hasNewerInDB)
        window.jumpToOldest()
        #expect(window.hasNewerInDB)
        #expect(window.applyPage(try #require(window.pageRequest(.newer, count: 1)).fetch()))
        #expect(window.currentStoredMessages().first?.id == "0200")
        window.jumpToLive()
        #expect(window.currentStoredMessages().map(\.id) == records.suffix(200).reversed().map(\.id))
    }

    @Test("A jump from distant history loads only the newest window and retires old pages")
    func boundedJumpToLive() async throws {
        let records = (0..<1_000).map { message($0) }
        let database = try database(records)
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.jumpTo(eventId: "$0100")
        let generation = window.generation
        let request = try #require(window.pageRequest(.newer))
        let stalePage = try await Task.detached { try request.fetch() }.value
        var jumpChanges = 0
        window.onChange = { _, _, origin in
            #expect(origin == .jump)
            #expect(window.isAtLiveEdge)
            #expect(window.peekNewerNeighbor() == nil)
            #expect(window.peekOlderNeighbor()?.timestamp.timeIntervalSince1970 == 799)
            jumpChanges += 1
        }
        window.jumpToLive()
        window.onChange = nil
        #expect(jumpChanges == 1)
        #expect(window.generation != generation)
        #expect(!window.applyPage(stalePage))
        #expect(window.currentStoredMessages().map(\.id) == records.suffix(200).reversed().map(\.id))
        #expect(window.hasOlderInDB)
        let olderRequest = try #require(window.pageRequest(.older))
        let olderPage = try await Task.detached { try olderRequest.fetch() }.value
        #expect(window.applyPage(olderPage))
        #expect(window.currentStoredMessages().map(\.id) == records.suffix(250).reversed().map(\.id))
    }

    @Test("A jump within a live window retains loaded history and includes new commits")
    func liveJumpRetainsHistory() async throws {
        let records = (0..<500).map { message($0) }
        let database = try database(records)
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let request = try #require(window.pageRequest(.older))
        let page = try await Task.detached { try request.fetch() }.value
        #expect(window.applyPage(page))
        #expect(window.isAtLiveEdge)
        let incoming = message(500)
        try await database.write { db in try incoming.insert(db) }
        window.jumpToLive()
        #expect(window.currentStoredMessages().map(\.id) == [incoming.id] + records.suffix(250).reversed().map(\.id))
        #expect(window.isAtLiveEdge)
        #expect(window.peekNewerNeighbor() == nil)
        #expect(window.peekOlderNeighbor()?.timestamp.timeIntervalSince1970 == 249)
    }

    @Test("A prepared newer page applies with cached neighbors and no DB reads")
    func preparedNewerApply() async throws {
        let database = try database((0..<500).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.jumpTo(eventId: "$0210")
        let request = try #require(window.pageRequest(.newer))
        let page = try await Task.detached { try request.fetch() }.value
        try database.close()
        var changes = 0
        window.onChange = { records, _, origin in
            #expect(Thread.isMainThread)
            #expect(origin == .databasePagination)
            #expect(records.count == 250)
            #expect(records.first?.id == "0360")
            #expect(records.last?.id == "0111")
            #expect(window.peekOlderNeighbor()?.timestamp.timeIntervalSince1970 == 110)
            #expect(window.peekNewerNeighbor()?.timestamp.timeIntervalSince1970 == 361)
            changes += 1
        }
        #expect(window.applyPage(page))
        #expect(changes == 1)
        window.onChange = nil
    }

    @Test("A newer page cannot undo a refresh, opposite page, or jump",
           arguments: ["refresh", "older", "jump"])
    func supersededNewerPage(change: String) async throws {
        let database = try database((0..<500).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.jumpTo(eventId: "$0210")
        let request = try #require(window.pageRequest(.newer))
        let page = try await Task.detached { try request.fetch() }.value
        switch change {
        case "refresh":
            try await database.write { db in
                try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Edited' WHERE id = '0210'")
            }
            window.refresh()
        case "older":
            #expect(window.applyPage(try #require(window.pageRequest(.older)).fetch()))
        default:
            window.jumpToLive()
        }
        let expected = window.currentStoredMessages()
        #expect(!window.applyPage(page))
        #expect(window.currentStoredMessages() == expected)
    }

    @Test("Reaching live keeps a later incoming message eligible for refresh")
    func newerPageReachesLive() async throws {
        let database = try database((0..<201).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.jumpToOldest()
        let request = try #require(window.pageRequest(.newer))
        let page = try await Task.detached { try request.fetch() }.value
        let incoming = message(201)
        try await database.write { db in try incoming.insert(db) }
        #expect(window.applyPage(page))
        #expect(window.isAtLiveEdge)
        #expect(window.pageRequest(.newer) == nil)
        #expect(window.currentStoredMessages().first?.id == "0200")
        let refresh = window.refreshRequest()
        let refreshed = try await Task.detached { try refresh.fetch() }.value
        #expect(window.applyRefresh(refreshed, summary: TimelineFlushSummary(pushBackCount: 1)))
        #expect(window.currentStoredMessages().first?.id == incoming.id)
    }

    @Test("An empty newer page retires refreshes captured before reaching live")
    func emptyNewerPage() async throws {
        let database = try database((0..<201).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.jumpToOldest()
        let refresh = window.refreshRequest()
        let request = try #require(window.pageRequest(.newer))
        try await database.write { db in
            try db.execute(sql: "DELETE FROM storedMessage WHERE id = '0200'")
        }
        let page = try await Task.detached { try request.fetch() }.value
        let staleRefresh = try await Task.detached { try refresh.fetch() }.value
        #expect(page.fetchedCount == 0)
        var boundaryUpdates = 0
        window.onChange = { _, _, origin in
            #expect(origin == .databasePagination)
            #expect(window.peekNewerNeighbor() == nil)
            boundaryUpdates += 1
        }
        #expect(window.applyPage(page))
        #expect(boundaryUpdates == 1)
        #expect(window.isAtLiveEdge)
        #expect(window.peekNewerNeighbor() == nil)
        #expect(!window.canApply(staleRefresh))
        window.onChange = nil
    }

    @Test("Prefetch fills the nearer available edge before the viewport reaches it")
    func bidirectionalPrefetch() {
        #expect(ChatHistoryPageLoader.prefetchDirection(
            olderRemaining: 5_000, newerRemaining: 2_000, viewportHeight: 800,
            hasOlder: true, hasNewer: true
        ) == .newer)
        #expect(ChatHistoryPageLoader.prefetchDirection(
            olderRemaining: 2_000, newerRemaining: 5_000, viewportHeight: 800,
            hasOlder: true, hasNewer: true
        ) == .older)
        #expect(ChatHistoryPageLoader.prefetchDirection(
            olderRemaining: 300, newerRemaining: 100, viewportHeight: 800,
            hasOlder: true, hasNewer: true
        ) == .newer)
        #expect(ChatHistoryPageLoader.prefetchDirection(
            olderRemaining: 300, newerRemaining: -20, viewportHeight: 800,
            hasOlder: true, hasNewer: false
        ) == .older)
        #expect(ChatHistoryPageLoader.prefetchDirection(
            olderRemaining: 5_000, newerRemaining: 3_000, viewportHeight: 800,
            hasOlder: true, hasNewer: true
        ) == nil)
    }

    @Test("History pages, jumps and local rebuilds never increment the incoming badge")
    func badgeIgnoresHistory() throws {
        let rows: [ChatTimelineRow] = try (0..<50).map { .message(try #require(message($0).toChatMessage())) }
        let update = TableUpdate.batch(
            deletions: [], insertions: (0..<50).map { IndexPath(row: $0, section: 0) },
            moves: [], updates: [], animated: false
        )
        let origins: [MessageWindowChangeOrigin] = [
            .databasePagination, .jump, .initialLoad, .localMutation
        ]
        for origin in origins {
            #expect(update.unseenIncomingCount(
                rows: rows, origin: origin, minimumVisibleRowBeforeUpdate: 30
            ) == 0)
        }
        #expect(update.unseenIncomingCount(
            rows: rows, origin: .timelineFlush(TimelineFlushSummary(pushBackCount: 50)),
            minimumVisibleRowBeforeUpdate: 30
        ) == 30)
        // SDK summaries can combine live arrivals with a history flush;
        // the history/reset flag is an animation policy, not a read count.
        #expect(update.unseenIncomingCount(
            rows: rows, origin: .timelineFlush(TimelineFlushSummary(pushBackCount: 50, pushFrontCount: 1)),
            minimumVisibleRowBeforeUpdate: 30
        ) == 30)
    }

    @Test("The incoming badge uses the submitted rows and excludes outgoing messages")
    func badgeSnapshot() throws {
        var outgoingRecord = message(1)
        outgoingRecord.isOutgoing = true
        let outgoing = try #require(outgoingRecord.toChatMessage())
        var rows: [ChatTimelineRow] = [
            .message(try #require(message(0).toChatMessage())), .message(outgoing)
        ]
        let update = TableUpdate.batch(
            deletions: [], insertions: [IndexPath(row: 0, section: 0), IndexPath(row: 1, section: 0)],
            moves: [], updates: [], animated: false
        )
        let count = update.unseenIncomingCount(
            rows: rows, origin: .timelineFlush(TimelineFlushSummary(pushBackCount: 2)),
            minimumVisibleRowBeforeUpdate: 5
        )
        // A subsequent datasource update must not affect the captured count.
        rows = [.message(outgoing)]
        #expect(count == 1)
        #expect(update.unseenIncomingCount(
            rows: rows, origin: .timelineFlush(TimelineFlushSummary(pushBackCount: 2)),
            minimumVisibleRowBeforeUpdate: 5
        ) == 0)
    }

    @Test("A newer page advances past a normalized-away pending duplicate")
    func deduplicatedNewerPage() throws {
        var records = (0..<202).map { message($0) }
        for i in [199, 200] {
            records[i].isOutgoing = true
            records[i].contentBody = "Same outgoing message"
        }
        records[200].eventId = nil
        records[200].transactionId = "pending"
        let database = try database(records)
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.jumpToOldest()
        #expect(window.applyPage(try #require(window.pageRequest(.newer, count: 1)).fetch()))
        #expect(window.currentStoredMessages().count == 200)
        #expect(window.applyPage(try #require(window.pageRequest(.newer, count: 1)).fetch()))
        #expect(window.currentStoredMessages().first?.id == "0201")
        #expect(!window.hasNewerInDB)
    }

    @Test("Older pagination has no phantom newer neighbor at the live edge")
    func liveEdgeDuringInsert() async throws {
        let database = try database((0..<300).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let request = try #require(window.pageRequest(.older))
        let incoming = message(300)
        try await database.write { db in try incoming.insert(db) }
        let page = try await Task.detached { try request.fetch() }.value
        #expect(window.applyPage(page))
        #expect(window.isAtLiveEdge)
        #expect(window.peekNewerNeighbor() == nil)
        let refreshRequest = window.refreshRequest()
        let refresh = try await Task.detached { try refreshRequest.fetch() }.value
        #expect(window.applyRefresh(refresh, summary: TimelineFlushSummary(pushBackCount: 1)))
        #expect(window.currentStoredMessages().first?.id == incoming.id)
        #expect(window.peekNewerNeighbor() == nil)
    }

    @Test("New local history signals availability after the window commit")
    func historyAvailability() async throws {
        let database = try database((0..<10).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        #expect(!window.hasOlderInDB)
        var signals = 0
        var didApply = false
        window.onChange = { _, _, _ in didApply = true }
        window.onOlderHistoryAvailable = {
            #expect(didApply)
            #expect(window.hasOlderInDB)
            signals += 1
        }
        let older = message(-1)
        try await database.write { db in try older.insert(db) }
        for _ in 0..<2 {
            let request = window.refreshRequest()
            let page = try await Task.detached { try request.fetch() }.value
            #expect(window.applyRefresh(page, summary: TimelineFlushSummary(pushFrontCount: 1)))
        }
        #expect(signals == 1)
        window.onOlderHistoryAvailable = nil
    }

    @Test("A call-only history flush can continue pagination without rebuilding the table")
    func filteredHistoryMaintenance() async throws {
        let database = try database([message(1)])
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        var call = message(0)
        call.contentType = "call"
        let callRecord = call
        try await database.write { db in try callRecord.insert(db) }
        let request = window.refreshRequest()
        let page = try await Task.detached { try request.fetch() }.value
        var changes = 0
        window.onChange = { _, _, _ in changes += 1 }
        #expect(window.applyRefresh(page, summary: TimelineFlushSummary(pushFrontCount: 1)))
        #expect(changes == 0)
        #expect(ChatHistoryPageLoader.shouldLoadSparseHistory(
            displayCount: 1, hasLocal: window.hasOlderInDB, serverExhausted: false
        ))
        #expect(!ChatHistoryPageLoader.shouldLoadSparseHistory(
            displayCount: 1, hasLocal: false, serverExhausted: true
        ))
    }

    @Test("Service-side confirmations are probed without consuming them on a stale refresh")
    func serviceRedactionConfirmation() async throws {
        var record = message(1)
        record.contentType = "redacted"
        let database = try database([record])
        let room = roomId
        let pending = PendingRedactionRecord(
            messageId: record.id, roomId: room, itemIdentifier: .eventId("$0001")
        )
        let columns = Mirror(reflecting: pending).children.compactMap(\.label)
        try await database.write { db in
            let definitions = columns.map {
                $0 == "messageId" ? "\"messageId\" TEXT PRIMARY KEY" : "\"\($0)\""
            }
            try db.execute(sql: "CREATE TABLE pendingRedaction (\(definitions.joined(separator: ",")))")
            try pending.insert(db)
        }
        let window = MessageWindow(roomId: room, dbQueue: database)
        window.loadInitial()
        let request = window.refreshRequest()
        let page = try await Task.detached { try request.fetch() }.value
        let resolved = try await database.read { db in
            try PendingRedactionService.resolvedPendingRedactions(roomId: room, in: db)
        }
        #expect(resolved.messageIds == [record.id])
        #expect(!resolved.identityKeys.isEmpty)
        #expect(!page.contentChanged)
        window.jumpToOldest()
        #expect(!window.applyRefresh(page, summary: TimelineFlushSummary(setCount: 1), forceNotify: true))
        let remaining = try await database.read { db in try PendingRedactionRecord.fetchCount(db) }
        #expect(remaining == 1)
        let nextRequest = window.refreshRequest()
        let nextPage = try await Task.detached { try nextRequest.fetch() }.value
        var changes = 0
        window.onChange = { _, _, _ in changes += 1 }
        #expect(window.applyRefresh(
            nextPage, summary: TimelineFlushSummary(setCount: 1),
            forceNotify: !resolved.messageIds.isEmpty
        ))
        #expect(changes == 1)
    }

    @Test("A snapshot sees committed history even before its notification reaches main")
    func unreportedHistoryCommit() async throws {
        let database = try database((0..<300).map { message($0) })
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        window.loadInitial()
        let revision = TimelineHistoryRevision()
        let request = window.refreshRequest()
        // A focused set is already delivered; a history commit happens
        // before its onFlush notification has been dispatched to main.
        let delivered = TimelineFlushSummary(setCount: 1)
        try await database.write { db in
            revision.observeCommit(TimelineFlushSummary(pushFrontCount: 1), in: db)
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted' WHERE id = '0299'")
        }
        let page = try await Task.detached { try request.fetch(historyRevision: revision) }.value
        #expect(page.contentChanged)
        let effective = delivered.coveringSnapshot(historyRevision: page.committedHistoryRevision)
        #expect(effective.includesUnreportedHistory)
        #expect(!effective.allowsRemoteRedactionAnimation)
        #expect(window.applyRefresh(page, summary: effective))
        // Once that history revision has been reported, later focused sets
        // are eligible again; this is not a permanent suppression flag.
        let nextLive = TimelineFlushSummary(setCount: 1, committedHistoryRevision: revision.current)
        #expect(nextLive.coveringSnapshot(historyRevision: revision.current).allowsRemoteRedactionAnimation)
    }

    @Test("Rolled-back history and live updates do not advance history provenance")
    func historyCommitRollback() throws {
        enum Failure: Error { case rollback }
        let database = try database([message(1)])
        let revision = TimelineHistoryRevision()
        #expect(throws: Failure.self) {
            try database.write { db in
                revision.observeCommit(TimelineFlushSummary(pushFrontCount: 1), in: db)
                try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Rolled back'")
                throw Failure.rollback
            }
        }
        #expect(revision.current == 0)
        try database.write { db in
            revision.observeCommit(TimelineFlushSummary(setCount: 1), in: db)
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Live edit'")
        }
        #expect(revision.current == 0)
        try database.write { db in
            revision.observeCommit(TimelineFlushSummary(resetCount: 1), in: db)
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'History snapshot'")
        }
        #expect(revision.current == 1)
    }
}
