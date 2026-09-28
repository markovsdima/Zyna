//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Navigation from the poll catalog", .serialized)
@MainActor
struct ChatPollNavigationTests {
    private let roomId = TimelineWriteFixture.roomID

    private func poll() -> StoredMessage {
        var record = RoomPollFixture.poll("$poll", time: -1).record!
        record.roomId = roomId
        return record
    }

    private func model(_ database: AccountDatabase) -> (MessageWindow, ChatViewModel) {
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        return (window, ChatViewModel(testingRoomId: roomId, dbQueue: database, window: window))
    }

    @Test("A catalog-only poll loads ordinary history and prepares off-main before committing the jump")
    func catalogOnly() async throws {
        let database = try TimelineWriteFixture.database()
        let record = poll()
        let catalog = RoomPollCatalog(roomId: roomId, database: database)
        try await Task.detached {
            try catalog.ingest([(record: record, isPollStart: true, senderProfile: .unavailable)])
        }.value
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 0)
        let (window, model) = model(database)
        defer { model.cleanup() }
        model.onRenderPreparedForTesting = { #expect(!Thread.isMainThread) }
        var calls = 0
        let prepared = try await model.preparePollNavigation(eventId: "$poll", paginate: {
            calls += 1
            let records = calls == 3 ? [record] : [TimelineWriteFixture.message(calls)]
            do {
                try await Task.detached {
                    try TimelineDiffBatcher.writeMappedEvents(records.map(TimelineWriteFixture.event),
                        roomId: record.roomId, database: database, currentUserId: RoomPollFixture.userID,
                        summary: .init(pushFrontCount: records.count), historyRevision: TimelineHistoryRevision()) { _ in }
                }.value
            } catch { Issue.record(error); return .failed }
            return .page(reachedStart: calls == 3)
        })
        #expect(calls == 3)
        #expect(window.currentStoredMessages().isEmpty)
        #expect(model.indexOfMessage(eventId: "$poll") == nil)
        #expect(prepared.open())
        #expect(model.indexOfMessage(eventId: "$poll") != nil)
        #expect(window.currentStoredMessages().count == 3)
        #expect(!prepared.open())
    }

    @Test("Cached full polls open without pagination; retired or superseded preparations cannot commit",
          arguments: [false, true])
    func cached(retire: Bool) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: [poll()])
        let (_, model) = model(database)
        defer { model.cleanup() }
        let prepared = try await model.preparePollNavigation(eventId: "$poll", paginate: {
            Issue.record("Cached navigation paginated")
            return .failed
        })
        if retire { try await Task.detached { try database.close() }.value }
        else { model.cancelPendingHistoryReplacement() }
        #expect(!prepared.open())
        #expect(model.messages.isEmpty)
    }

    @Test("The final SDK reply may precede the full poll projection", arguments: [false, true])
    func trailingProjection(legacy: Bool) async throws {
        var placeholder = poll()
        placeholder.contentType = legacy ? "text" : "unableToDecrypt"
        placeholder.contentBody = legacy ? "Unable to decrypt message" : nil
        placeholder.contentPollJSON = nil
        let database = try TimelineWriteFixture.database(legacyMessages: [placeholder])
        let record = poll()
        var writer: Task<Void, Error>?
        var calls = 0
        try await ChatPollNavigation.load(eventId: "$poll", roomId: roomId, database: database,
            isCurrent: { true }, paginate: {
                calls += 1
                writer = Task {
                    try await Task.sleep(for: .milliseconds(20))
                    try await database.write { try record.save($0) }
                }
                return .page(reachedStart: true)
            })
        try await writer?.value
        #expect(calls == 1)
    }

    @Test("Missing targets and SDK errors finish without applying a window",
          arguments: [HistoryPaginationResult.failed, .unavailable, .page(reachedStart: true)])
    func failure(result: HistoryPaginationResult) async throws {
        let database = try TimelineWriteFixture.database()
        var calls = 0
        await #expect(throws: PollNavigationError.self) {
            try await ChatPollNavigation.load(eventId: "$poll", roomId: roomId, database: database,
                settle: .zero, isCurrent: { true }, paginate: { calls += 1; return result })
        }
        #expect(calls == 1)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 0)
    }

    @Test("A deleted poll is not opened as an unrelated window")
    func deleted() async throws {
        var record = poll()
        record.contentType = "redacted"
        let database = try TimelineWriteFixture.database(legacyMessages: [record])
        let (_, model) = model(database)
        defer { model.cleanup() }
        await #expect(throws: PollNavigationError.self) {
            _ = try await model.preparePollNavigation(eventId: "$poll", paginate: {
                Issue.record("Deleted target paginated")
                return .failed
            })
        }
        #expect(model.messages.isEmpty)
    }

    @Test("A full but locally hidden poll does not commit an empty destination")
    func hidden() async throws {
        let record = poll()
        let database = try TimelineWriteFixture.database(legacyMessages: [record])
        let (_, model) = model(database)
        defer { model.cleanup() }
        model.hideMessage(record.id)
        await #expect(throws: PollNavigationError.self) {
            _ = try await model.preparePollNavigation(eventId: "$poll")
        }
        #expect(model.messages.isEmpty)
    }

    @Test("Cancellation and account changes reject a late successful page", arguments: [false, true])
    func latePage(cancel: Bool) async throws {
        let database = try TimelineWriteFixture.database()
        let record = poll()
        var current = true
        var gate: CheckedContinuation<HistoryPaginationResult, Never>?
        let task = Task {
            try await ChatPollNavigation.load(eventId: "$poll", roomId: roomId, database: database,
                isCurrent: { current }, paginate: { await withCheckedContinuation { gate = $0 } })
        }
        try await ChatBackgroundPresentationTests.wait { gate != nil }
        if cancel { task.cancel() } else { current = false }
        try await database.write { try record.save($0) }
        gate?.resume(returning: .page(reachedStart: true))
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("An unfinished history search has a finite budget")
    func budget() async throws {
        let database = try TimelineWriteFixture.database()
        await #expect(throws: PollNavigationError.self) {
            try await ChatPollNavigation.load(eventId: "$poll", roomId: roomId, database: database,
                budget: .zero, isCurrent: { true }, paginate: {
                    Issue.record("Budget exhausted")
                    return .page(reachedStart: false)
                })
        }
    }
}
