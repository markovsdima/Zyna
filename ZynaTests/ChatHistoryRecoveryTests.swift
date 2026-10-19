//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK
import Testing
@testable import Zyna

@Suite("History admission and recovery", .serialized)
@MainActor
struct ChatHistoryRecoveryTests {
    private let roomID = TimelineWriteFixture.roomID

    @Test("Pages of unresolved events advance both cursors without producing bubbles", arguments: [false, true])
    func hiddenPages(newer: Bool) async throws {
        let records = (0...610).map { index in
            var row = index == 0 || index == 610 ? TimelineWriteFixture.message(index) : Self.placeholder(index)
            row.id = String(format: "%04d", index)
            row.timestamp = 1000 // Cursor ties must advance too.
            if index == 0 || index == 610 { row.senderId = "@visible:example.org" }
            return row
        }
        let database = try TimelineWriteFixture.database(legacyMessages: records)
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        if newer { window.jumpToOldest() } else { window.loadInitial() }
        #expect(window.currentStoredMessages().count == 1)
        let neighbor = newer ? window.peekNewerNeighbor() : window.peekOlderNeighbor()
        #expect(neighbor?.senderId == "@visible:example.org")
        var pages = 0
        var invisiblePages = 0
        while (newer ? window.hasNewerInDB : window.hasOlderInDB), pages < 20 {
            let previous = window.currentStoredMessages()
            let request = try #require(window.pageRequest(newer ? .newer : .older))
            let page = try await Task.detached { try request.fetch() }.value
            #expect(page.fetchedCount > 0)
            #expect(window.applyPage(page))
            if previous == window.currentStoredMessages() { invisiblePages += 1 }
            pages += 1
        }
        #expect(pages == 9)
        #expect(invisiblePages == 8)
        #expect(window.currentStoredMessages().map(\.id) == ["0610", "0000"])
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 611)
    }

    @Test("Initial and jump snapshots admit neither legacy labels nor typed failures")
    func initialAndJump() async throws {
        var english = TimelineWriteFixture.message(0)
        english.contentBody = "Unable to decrypt message"
        var russian = TimelineWriteFixture.message(1)
        russian.contentBody = "Не удалось расшифровать сообщение"
        let records = [english, russian, Self.placeholder(2), TimelineWriteFixture.message(3)]
        let database = try TimelineWriteFixture.database(legacyMessages: records)
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        var snapshots = [[String]]()
        window.onChange = { messages, _, _ in snapshots.append(messages.map(\.id)) }
        window.loadInitial()
        window.jumpTo(eventId: "$event-1")
        window.jumpToOldest()
        window.jumpToLive()
        #expect(snapshots == Array(repeating: ["row-3"], count: 4))
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 4)

        // The same words in an authoritative SDK message are ordinary text.
        let summary = try await Self.project([english], database: database)
        window.refresh(origin: .timelineFlush(summary))
        #expect(window.currentStoredMessages().map(\.id) == ["row-3", "row-0"])
        #expect(summary.includesUnreportedHistory)
    }

    @Test("Inspection alone never reveals an unaggregated event; SDK hydration inserts it once")
    func hydration() async throws {
        let hidden = Self.placeholder(100)
        let database = try TimelineWriteFixture.database(legacyMessages: [hidden, TimelineWriteFixture.message(200)])
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        window.loadInitial()
        let candidate = try #require(try await database.read {
            try MessageDecryptionRepairStore.candidates(in: $0, roomID: hidden.roomId, now: 1000).first
        })
        try await database.write { db throws -> Void in
            #expect(try !MessageDecryptionRepairStore.apply(Self.inspection(hidden, disposition: .visible),
                to: candidate, in: db, now: 1000))
        }
        window.refresh()
        #expect(window.currentStoredMessages().map(\.id) == ["row-200"])
        let revision = TimelineHistoryRevision()
        let summary = try await Self.project([TimelineWriteFixture.message(100)], database: database, revision: revision)
        #expect(summary.includesUnreportedHistory)
        #expect(revision.current == 1)
        #expect(summary.recoveredEventIDs == ["$event-100"])
        #expect(!summary.allowsRemoteRedactionAnimation)
        #expect(MessageWindowChangeOrigin.timelineFlush(summary).preservesHistoryViewport)
        window.refresh(origin: .timelineFlush(summary))
        #expect(window.currentStoredMessages().map(\.id) == ["row-200", "row-100"])
        // Stale missing-key replay does not hide an already hydrated message.
        let replay = try await Self.project([hidden], database: database)
        #expect(!replay.includesUnreportedHistory)
        window.refresh(origin: .timelineFlush(replay))
        #expect(window.currentStoredMessages().map(\.id) == ["row-200", "row-100"])
    }

    @Test("An entirely unresolved initial window retains raw bounds for later hydration")
    func emptyVisibleWindow() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<250).map(Self.placeholder))
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        window.loadInitial()
        #expect(window.currentStoredMessages().isEmpty)
        #expect(window.hasOlderInDB)
        #expect(window.recoveryFocus == .init(oldest: 50, newest: 249))
        let request = try #require(window.pageRequest(.older))
        let page = try await Task.detached { try request.fetch() }.value
        #expect(window.applyPage(page))
        #expect(!window.hasOlderInDB)
        let summary = try await Self.project([TimelineWriteFixture.message(20)], database: database)
        window.refresh(origin: .timelineFlush(summary))
        #expect(window.currentStoredMessages().map(\.id) == ["row-20"])
    }

    @Test("Jump preparation performs SQL off-main and applies only admitted rows")
    func preparedJump() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: [Self.placeholder(1), TimelineWriteFixture.message(2)])
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database, window: window)
        defer { model.cleanup() }
        try await database.write { db in
            db.trace { _ in #expect(!Thread.isMainThread) }
        }
        var applied = false
        model.prepareHistoryReplacement(.event("$event-1")) { apply in
            #expect(Thread.isMainThread)
            apply()
            applied = true
        }
        try await wait { applied }
        #expect(window.currentStoredMessages().map(\.id) == ["row-2"])
        #expect(model.rows.allSatisfy { $0.message?.content != .unableToDecrypt(.unavailable) })
    }

    @Test("Focus takes priority over newest history; manual retry is bounded to that span")
    func focusAndRetry() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<100).map(Self.placeholder))
        try await database.write { db in
            let focus = MessageDecryptionRepairStore.Focus(oldest: 30, newest: 69)
            let candidates = try MessageDecryptionRepairStore.candidates(in: db,
                roomID: TimelineWriteFixture.roomID, now: 1000, focus: focus)
            #expect(candidates.map(\.message.timestamp) == (62...69).reversed().map(Double.init))
            try db.execute(sql: "UPDATE messageDecryptionRepair SET nextAttemptAt = 5000, lastOutcome = 'failed'")
            try MessageDecryptionRepairStore.retryPage(in: db, roomID: TimelineWriteFixture.roomID, focus: focus)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageDecryptionRepair WHERE nextAttemptAt = 0") == 32)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageDecryptionRepair WHERE nextAttemptAt = 0 AND priorityTimestamp NOT BETWEEN 30 AND 69") == 0)
        }
    }

    @Test("A prepared jump cannot override newer navigation or a closed chat", arguments: [false, true])
    func supersededJump(cleanup: Bool) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: [TimelineWriteFixture.message(1)])
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database, window: window)
        defer { model.cleanup() }
        let queried = Atomic(false)
        try await database.write { db in db.trace { _ in queried.wrappedValue = true } }
        model.prepareHistoryReplacement(.event("$event-1")) { _ in Issue.record("Stale navigation became ready") }
        // Both actions happen on main before a preparation callback can run.
        if cleanup { model.cleanup() } else { model.cancelPendingHistoryReplacement() }
        try await wait { queried.wrappedValue }
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.currentStoredMessages().isEmpty)
    }

    @Test("A delayed notice describes unresolved history without admitting its rows")
    func notice() async throws {
        let hidden = Self.placeholder(1)
        let database = try TimelineWriteFixture.database(legacyMessages: [hidden])
        let recovery = ChatHistoryRecovery(roomID: roomID, database: database, revealDelay: 0.15)
        defer { recovery.stop() }
        try await wait { recovery.snapshot.pending }
        #expect(!recovery.isNoticeVisible)
        try await wait { recovery.isNoticeVisible }
        try await database.write { db in
            let candidate = try #require(MessageDecryptionRepairStore.candidates(in: db,
                roomID: hidden.roomId, now: 1000).first)
            try MessageDecryptionRepairStore.apply(Self.inspection(hidden, disposition: .unableToDecrypt),
                to: candidate, in: db, now: 1000)
        }
        try await wait { recovery.snapshot.waitingForKeys }
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        window.loadInitial()
        #expect(window.currentStoredMessages().isEmpty)
        _ = try await Self.project([TimelineWriteFixture.message(1)], database: database)
        try await wait { !recovery.isNoticeVisible && recovery.snapshot.isEmpty }
    }

    @Test("Repairing an app-excluded event closes the recovery notice and refreshes history")
    func excludedEventClosesNotice() async throws {
        let message = Self.placeholder(1)
        let database = try TimelineWriteFixture.database(legacyMessages: [message])
        let recovery = ChatHistoryRecovery(roomID: roomID, database: database, revealDelay: 0)
        defer { recovery.stop() }
        try await wait { recovery.isNoticeVisible }
        let revision = TimelineHistoryRevision()
        var refreshed = false
        let repair = MessageDecryptionRepair(roomID: roomID, database: database, historyRevision: revision,
            inspect: { _ in
                var result = Self.inspection(message, disposition: .visible)
                result.event.eventType = "m.call.invite"
                result.event.contentJson = #"{"call_id":"call","offer":{"type":"offer","sdp":"sdp"}}"#
                return result
            }, didChange: { summary in
                #expect(!summary.allowsRemoteRedactionAnimation)
                #expect(summary.canRefreshBoundsOnly)
                #expect(summary.recoveredEventIDs.isEmpty)
                refreshed = true
            })
        defer { repair.stop() }
        try await wait { refreshed && recovery.snapshot.isEmpty && !recovery.isNoticeVisible }
        #expect(revision.current == 1)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 0)
        repair.stop()
        await repair.waitUntilStopped()
    }

    @Test("Manual retry interrupts a long backlog at the next bounded batch")
    func retryDuringBacklog() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<100).map(Self.placeholder))
        try await database.write { db in
            try db.execute(sql: "UPDATE messageDecryptionRepair SET nextAttemptAt = 99999999999 WHERE messageId = 'row-0'")
        }
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let calls = Atomic<[String]>([])
        let repair = MessageDecryptionRepair(roomID: roomID, database: database,
            historyRevision: TimelineHistoryRevision(), inspect: { eventID in
                let first = calls.withValue { $0.append(eventID); return $0.count == 1 }
                if first { for await _ in gate.stream { break } }
                return Self.inspection(Self.placeholder(Int(eventID.dropFirst("$event-".count))!), disposition: .indeterminate)
            }, didChange: { _ in Issue.record("Unknown events changed presentation") })
        defer { gate.continuation.finish(); repair.stop() }
        try await wait { calls.wrappedValue.count == 1 }
        repair.prioritize(.init(oldest: 0, newest: 0))
        repair.retry()
        gate.continuation.yield(())
        try await wait { calls.wrappedValue.contains("$event-0") }
        #expect(calls.wrappedValue.firstIndex(of: "$event-0") == 8)
        repair.stop()
        await repair.waitUntilStopped()
    }

    @Test("Fast resolution, cleanup and account retirement prevent a late notice", arguments: [0, 1, 2])
    func cancelledNotice(_ reason: Int) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: [Self.placeholder(1)])
        let recovery = ChatHistoryRecovery(roomID: roomID, database: database, revealDelay: 0.25)
        defer { recovery.stop() }
        try await wait { recovery.snapshot.pending }
        switch reason {
        case 0:
            _ = try await Self.project([TimelineWriteFixture.message(1)], database: database)
            try await wait { recovery.snapshot.isEmpty }
        case 1: recovery.stop()
        default: try await Task.detached { try database.close() }.value
        }
        try await Task.sleep(for: .milliseconds(350))
        #expect(!recovery.isNoticeVisible)
    }

    @Test("An already applied v30 upgrades without resetting pending work or hidden proofs", arguments: [false, true])
    func migrationFromV30(earlySchema: Bool) async throws {
        let queue = try DatabaseQueue()
        try await Task.detached {
            try DatabaseService.migrator.migrate(queue, upTo: "v29_polls")
            try queue.write { db in
                try Self.placeholder(1).insert(db)
                try Self.placeholder(2).insert(db)
            }
            try DatabaseService.migrator.migrate(queue, upTo: "v30_messageDecryptionRepair")
            try queue.write { db in
                try db.execute(sql: "UPDATE messageDecryptionRepair SET generation = 'retained', nextAttemptAt = 1000")
                try db.execute(sql: "UPDATE messageDecryptionRepair SET isHidden = 1 WHERE messageId = 'row-1'")
                try StoredMessage.deleteOne(db, key: "row-1")
                if earlySchema {
                    try db.execute(sql: """
                        DROP INDEX messageDecryptionRepair_due;
                        ALTER TABLE messageDecryptionRepair DROP COLUMN priorityTimestamp;
                        CREATE INDEX messageDecryptionRepair_due ON messageDecryptionRepair(roomId, isHidden, nextAttemptAt);
                        """)
                }
            }
            try DatabaseService.migrator.migrate(queue)
            try queue.read { db throws -> Void in
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageDecryptionRepair WHERE generation = 'retained' AND nextAttemptAt = 1000 AND lastOutcome = 'pending'") == 2)
                #expect(try Bool.fetchOne(db, sql: "SELECT isHidden FROM messageDecryptionRepair WHERE messageId = 'row-1'") == true)
                #expect(try MessageDecryptionRepairStore.admitted(StoredMessage.fetchAll(db), in: db).isEmpty)
                #expect(try Double.fetchOne(db, sql: "SELECT priorityTimestamp FROM messageDecryptionRepair WHERE messageId = 'row-2'") == 2)
            }
        }.value
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    nonisolated private static func placeholder(_ index: Int) -> StoredMessage {
        var message = TimelineWriteFixture.message(index)
        message.contentType = "unableToDecrypt"
        message.contentBody = "unavailable"
        return message
    }

    nonisolated private static func inspection(_ message: StoredMessage,
        disposition: RoomTimelineEventDisposition) -> RoomTimelineEventInspection {
        .init(event: .init(roomId: message.roomId, eventType: "m.room.message", eventId: message.eventId,
            sender: message.senderId, originServerTsMs: UInt64(message.timestamp * 1000),
            contentJson: "{}", rawJson: "{}", encryptionInfo: nil), disposition: disposition,
            decryptionFailure: disposition == .unableToDecrypt ? .unknown : nil)
    }

    nonisolated private static func project(_ messages: [StoredMessage], database: AccountDatabase,
        revision: TimelineHistoryRevision = TimelineHistoryRevision()) async throws -> TimelineFlushSummary {
        try await Task.detached {
            var committed = TimelineFlushSummary()
            try TimelineDiffBatcher.writeMappedEvents(messages.map(TimelineWriteFixture.event),
                roomId: TimelineWriteFixture.roomID, database: database, currentUserId: "",
                summary: .init(setCount: messages.count), historyRevision: revision) { committed = $0 }
            return committed
        }.value
    }
}
