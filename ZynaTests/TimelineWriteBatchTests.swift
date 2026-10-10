//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

enum TimelineWriteFixture {
    static let roomID = "!write-batch:example.org"

    static func message(_ index: Int) -> StoredMessage {
        var record = RoomPollFixture.poll("$event-\(index)", time: Double(index)).record!
        record.roomId = roomID
        record.id = "row-\(index)"
        record.isOutgoing = false
        record.contentType = "text"
        record.contentBody = "Message \(index)"
        record.contentPollJSON = nil
        return record
    }

    static func membership(_ id: String) -> StoredMatrixRTCCallMembership {
        .init(eventId: id, roomId: roomID, eventType: "org.matrix.msc3401.call.member",
              stateKey: "member", senderId: "@alice:example.org", timestamp: 100,
              isLeave: false, userId: "@alice:example.org", deviceId: "DEVICE",
              memberId: "member", callIntent: nil, expiresAt: nil)
    }

    static func database(path: String? = nil, legacyMessages: [StoredMessage] = []) throws -> AccountDatabase {
        let database = AccountDatabase(try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue())
        try database.write { db in
            func table<T>(_ name: String, sample: T, key: String, excluding: Set<String> = []) throws {
                let columns = Mirror(reflecting: sample).children.compactMap(\.label)
                    .filter { !excluding.contains($0) }
                let definitions = columns.map { $0 == key ? "\"\($0)\" TEXT PRIMARY KEY" : "\"\($0)\"" }
                try db.execute(sql: "CREATE TABLE \(name) (\(definitions.joined(separator: ",")))")
            }
            try table("storedMessage", sample: message(0), key: "id", excluding: ["contentPollJSON"])
            try db.execute(sql: "CREATE UNIQUE INDEX message_event ON storedMessage(roomId, eventId) WHERE eventId IS NOT NULL")
            try db.execute(sql: "CREATE INDEX message_transaction ON storedMessage(transactionId)")
            try db.execute(sql: """
                CREATE TABLE pendingMediaGroup (id TEXT PRIMARY KEY, roomId TEXT, kind TEXT, state TEXT);
                CREATE TABLE pendingMediaGroupItem (id TEXT PRIMARY KEY, groupId TEXT REFERENCES pendingMediaGroup(id),
                    eventId TEXT, transactionId TEXT, itemIndex INTEGER, transportState TEXT);
                CREATE TABLE storedMatrixRTCCall (notificationEventId TEXT PRIMARY KEY);
                """)
            try table("storedMatrixRTCCallMembership", sample: membership("$member"), key: "eventId")
            var media = message(0)
            media.contentType = "image"
            media.contentMediaJSON = "{\"url\":\"mxc://example.org/photo\"}"
            let attachment = try #require(StoredRoomAttachment(storedMessage: media))
            // Match the catalog's composite identity.
            let columns = Mirror(reflecting: attachment).children.compactMap(\.label).map { "\"\($0)\"" }
            try db.execute(sql: "CREATE TABLE roomAttachment (\(columns.joined(separator: ",")), PRIMARY KEY(roomId, eventId))")
            try db.execute(sql: "CREATE TABLE ignoredUser (userId TEXT PRIMARY KEY NOT NULL)")
            try PollStore.migrate(db)
            for message in legacyMessages { try message.insert(db) }
            try MessageDecryptionRepairStore.migrate(db)
            try MessageDecryptionRepairStore.migratePresentation(db)
        }
        return database
    }

    static func event(_ record: StoredMessage) -> [TimelineDiffBatcher.DiffOp] {
        [.upsert(record, isPollStart: record.contentType == "poll", senderProfile: .unavailable)]
    }
}

@Suite("Bounded timeline persistence")
struct TimelineWriteBatchTests {
    @Test("Incoming counts survive mixed history/live batches and exclude replay, repair, outgoing and hidden rows")
    func incomingMessages() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: [TimelineWriteFixture.message(0)])
        let events = (0..<130).map { index -> [TimelineDiffBatcher.DiffOp] in
            var record = TimelineWriteFixture.message(index)
            if index == 2 { record.isOutgoing = true }
            if index == 3 { record.contentType = "redacted" }
            if index == 4 { record.contentType = "unableToDecrypt" }
            if index == 5 { record.senderId = "@ignored:example.org" }
            if index == 6 { record.contentType = "call" }
            // 1 is historical; 0 is already stored (a replay or update).
            return TimelineWriteFixture.event(record) + (index == 1 ? [] : [.liveArrival])
        }
        try await database.write { try $0.execute(sql: "INSERT INTO ignoredUser VALUES ('@ignored:example.org')") }
        let counts = try await Task.detached {
            var counts: [Int] = []
            for _ in 0..<2 {
                try TimelineDiffBatcher.writeMappedEvents(events, roomId: TimelineWriteFixture.roomID,
                    database: database, currentUserId: "", summary: .init(pushBackCount: 129, pushFrontCount: 1),
                    historyRevision: TimelineHistoryRevision(),
                    limits: .init(maximumCount: 8, maximumDuration: 60)) {
                        counts.append($0.incomingMessageCount)
                    }
            }
            return counts
        }.value
        #expect(counts == [123, 0])
    }

    @Test("The incoming count includes only committed chunks after a later write fails")
    func incomingRollback() async throws {
        let database = try TimelineWriteFixture.database()
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_message BEFORE INSERT ON storedMessage
                WHEN NEW.id = 'row-3' BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
                """)
        }
        let count = await Task.detached {
            var count = 0
            let events = (0..<5).map { TimelineWriteFixture.event(TimelineWriteFixture.message($0)) + [.liveArrival] }
            #expect(throws: DatabaseError.self) {
                try TimelineDiffBatcher.writeMappedEvents(events, roomId: TimelineWriteFixture.roomID,
                    database: database, currentUserId: "", summary: .init(pushBackCount: 5),
                    historyRevision: TimelineHistoryRevision(),
                    limits: .init(maximumCount: 2, maximumDuration: 60)) { count += $0.incomingMessageCount }
            }
            return count
        }.value
        #expect(count == 2)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 2)
    }

    @Test("A cache read queued during a large write runs between chunks, before the batch completes")
    func cachedReadInterleaves() async throws {
        let database = try TimelineWriteFixture.database()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        try await database.write { db in
            for (id, ended) in [("$active", false), ("$ended", true)] {
                var record = RoomPollFixture.poll(id, ended: ended).record!
                record.roomId = TimelineWriteFixture.roomID
                try PollStore.ingest(&record, in: db)
            }
            db.add(function: DatabaseFunction("hold_first_insert", argumentCount: 0) { _ in
                entered.signal()
                guard gate.wait(timeout: .now() + 5) == .success else {
                    throw TestFailure.timeout
                }
                return 0
            })
            try db.execute(sql: """
                CREATE TRIGGER hold_first BEFORE INSERT ON storedMessage WHEN NEW.id = 'row-0'
                BEGIN SELECT hold_first_insert(); END;
                """)
        }
        let events = (0..<1024).map { TimelineWriteFixture.event(TimelineWriteFixture.message($0)) }
        let revision = TimelineHistoryRevision()
        let writer = Task.detached {
            var summaries: [TimelineFlushSummary] = []
            try TimelineDiffBatcher.writeMappedEvents(events, roomId: TimelineWriteFixture.roomID,
                database: database, currentUserId: "", summary: .init(resetCount: 1), historyRevision: revision,
                limits: .init(maximumCount: 16, maximumDuration: 60)) { summaries.append($0) }
            return summaries
        }
        let didEnter = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
        #expect(didEnter)
        let result: (Int, [RoomPollItem], UInt64) = try await withCheckedThrowingContinuation { continuation in
            // Enqueue before releasing the writer. Dispatch FIFO ordering
            // makes this deterministic, without a wall-clock speed assertion.
            database.asyncRead { result in
                do {
                    let db = try result.get()
                    continuation.resume(returning: (
                        try StoredMessage.fetchCount(db),
                        try PollStore.fetchPolls(in: db, roomId: TimelineWriteFixture.roomID, limit: 31),
                        revision.current))
                } catch { continuation.resume(throwing: error) }
            }
            gate.signal()
        }
        #expect(result.0 == 16)
        #expect(Set(result.1.map(\.eventId)) == ["$active", "$ended"])
        #expect(result.1.filter(\.snapshot.hasEnded).count == 1)
        #expect(result.2 == 1)
        #expect(!TimelineFlushSummary(setCount: 1).coveringSnapshot(historyRevision: result.2).allowsRemoteRedactionAnimation)
        let summaries = try await writer.value
        #expect(summaries.count == 1)
        #expect(summaries.first?.upsertCount == 1024)
        #expect(summaries.first?.committedHistoryRevision == 64)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 1024)
    }

    @Test("A failed event rolls back its poll, message, and sidecars; the earlier prefix is reported",
          arguments: [0, 1])
    func rollbackPreservesEventAtomicity(failingIndex: Int) async throws {
        let database = try TimelineWriteFixture.database()
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_member BEFORE INSERT ON storedMatrixRTCCallMembership
                WHEN NEW.eventId = '$fail' BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
                """)
        }
        let events: [[TimelineDiffBatcher.DiffOp]] = (0..<3).map { index in
            var record = RoomPollFixture.poll("$poll-\(index)").record!
            record.roomId = TimelineWriteFixture.roomID
            return TimelineWriteFixture.event(record) + [
                .upsertMatrixRTCMembership(TimelineWriteFixture.membership(index == failingIndex ? "$fail" : "$member-\(index)"))
            ]
        }
        let revision = TimelineHistoryRevision()
        let summaries = await Task.detached {
            var summaries: [TimelineFlushSummary] = []
            #expect(throws: DatabaseError.self) {
                try TimelineDiffBatcher.writeMappedEvents(events, roomId: TimelineWriteFixture.roomID,
                    database: database, currentUserId: "", summary: .init(resetCount: 1, readReceiptCount: 1),
                    cursorTs: 500, historyRevision: revision,
                    limits: .init(maximumCount: 1, maximumDuration: 60)) { summaries.append($0) }
            }
            return summaries
        }.value
        #expect(summaries.count == failingIndex)
        #expect(summaries.first?.upsertCount ?? 0 == failingIndex)
        #expect(summaries.first?.readReceiptCount ?? 0 == 0)
        #expect(revision.current == UInt64(failingIndex))
        try await database.read { db throws -> Void in
            #expect(try StoredMessage.fetchCount(db) == failingIndex)
            #expect(try StoredRoomPoll.fetchCount(db) == failingIndex)
            #expect(try StoredMatrixRTCCallMembership.fetchCount(db) == failingIndex)
        }
    }

    @Test("Replaying cached history performs no message writes and preserves stable identity and read state")
    func replayIsNoOp() async throws {
        let database = try TimelineWriteFixture.database()
        let original = (0..<200).map { index in
            var record = TimelineWriteFixture.message(index)
            record.sendStatus = "read"
            record.isOutgoing = true
            record.transactionId = "txn-\(index)"
            return record
        }
        try await Task.detached {
            let revision = TimelineHistoryRevision()
            try TimelineDiffBatcher.writeMappedEvents(original.map(TimelineWriteFixture.event),
                roomId: TimelineWriteFixture.roomID, database: database, currentUserId: "",
                summary: .init(resetCount: 1), historyRevision: revision) { _ in }
            try await database.write { db in
                try db.execute(sql: """
                    CREATE TABLE message_writes (id TEXT);
                    CREATE TRIGGER record_message_write AFTER UPDATE ON storedMessage
                    BEGIN INSERT INTO message_writes VALUES (NEW.id); END;
                    """)
            }
            let replay = original.map { old -> [TimelineDiffBatcher.DiffOp] in
                var record = old
                record.id = "new-sdk-identity-" + old.id
                record.transactionId = nil
                record.sendStatus = "synced"
                return TimelineWriteFixture.event(record)
            }
            try TimelineDiffBatcher.writeMappedEvents(replay, roomId: TimelineWriteFixture.roomID,
                database: database, currentUserId: "", summary: .init(resetCount: 1),
                historyRevision: revision) { _ in }
            try await database.read { db throws -> Void in
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_writes") == 0)
                #expect(try StoredMessage.order(Column("timestamp")).fetchAll(db) == original)
            }
            var edited = original[0]
            edited.contentBody = "Updated content"
            try TimelineDiffBatcher.writeMappedEvents([TimelineWriteFixture.event(edited)],
                roomId: TimelineWriteFixture.roomID, database: database, currentUserId: "",
                summary: .init(setCount: 1), historyRevision: revision) { summary in
                #expect(summary.allowsRemoteRedactionAnimation)
            }
            #expect(try await database.read { try StoredMessage.fetchOne($0, key: edited.id)?.contentBody } == "Updated content")
        }.value
    }

    @Test("A cached ended poll cannot reopen across chunk boundaries and a receipt-only batch still commits")
    func monotonicPollAndReceipt() async throws {
        let database = try TimelineWriteFixture.database()
        var ended = RoomPollFixture.poll("$poll", ended: true).record!
        ended.roomId = TimelineWriteFixture.roomID
        var active = ended
        active.id = "another-sdk-id"
        active.contentPollJSON = RoomPollFixture.poll("$poll").record?.contentPollJSON
        let records = [ended, active]
        try await Task.detached {
            let revision = TimelineHistoryRevision()
            try TimelineDiffBatcher.writeMappedEvents(records.map(TimelineWriteFixture.event),
                roomId: TimelineWriteFixture.roomID, database: database, currentUserId: "",
                summary: .init(resetCount: 1), historyRevision: revision,
                limits: .init(maximumCount: 1, maximumDuration: 60)) { _ in }
            try TimelineDiffBatcher.writeMappedEvents([], roomId: TimelineWriteFixture.roomID,
                database: database, currentUserId: "", summary: .init(readReceiptCount: 1),
                cursorTs: 500, historyRevision: revision) { summary in
                #expect(summary.readReceiptCount == 1)
                #expect(summary.upsertCount == 0)
            }
            try await database.read { db throws -> Void in
                let saved = try #require(try StoredMessage.fetchOne(db))
                #expect(saved.id == records[0].id)
                #expect(saved.sendStatus == "read")
                #expect(PollCoding.decode(PollSnapshot.self, from: saved.contentPollJSON)?.hasEnded == true)
            }
        }.value
    }

    @Test("A slow indivisible event yields at the time budget, before the count limit")
    func timeBudget() async throws {
        let ranges = try await Task.detached {
            let database = AccountDatabase(try DatabaseQueue())
            var ranges: [Range<Int>] = []
            try DatabaseWriteBatch.write(Array(0..<3), to: database, source: "test",
                limits: .init(maximumCount: 64, maximumDuration: 0.001), apply: { _, _ in
                    Thread.sleep(forTimeInterval: 0.005)
                }, didCommit: { ranges.append($0) })
            return ranges
        }.value
        #expect(ranges == [0..<1, 1..<2, 2..<3])
    }

    @Test("The attachment index retains the uncommitted suffix and merges a newer discovery over it")
    func attachmentRetrySuffix() async throws {
        let database = try TimelineWriteFixture.database()
        let failure = DispatchSemaphore(value: 0)
        try await database.write { db in
            db.add(function: DatabaseFunction("fail_attachment", argumentCount: 0) { _ in
                failure.signal()
                throw TestFailure.injected
            })
            try db.execute(sql: """
                CREATE TRIGGER stop_attachment_batch BEFORE INSERT ON roomAttachment
                WHEN (SELECT COUNT(*) FROM roomAttachment) >= 80
                BEGIN SELECT fail_attachment(); END;
                """)
        }
        let records = try (0..<100).map { index -> StoredRoomAttachment in
            var record = TimelineWriteFixture.message(index)
            record.contentType = "image"
            record.contentMediaJSON = "{\"url\":\"mxc://example.org/\(index)\"}"
            return try #require(StoredRoomAttachment(storedMessage: record))
        }
        let index = RoomAttachmentIndex(roomId: TimelineWriteFixture.roomID, dbQueue: database)
        index.upsert(records)
        let didFail = await Task.detached { failure.wait(timeout: .now() + 5) == .success }.value
        #expect(didFail)
        try await database.write { db throws -> Void in
            let count = try StoredRoomAttachment.fetchCount(db)
            #expect(count > 0 && count <= 80)
            try db.execute(sql: "DROP TRIGGER stop_attachment_batch")
        }
        var renamed = records[0]
        renamed.filename = "renamed.jpg"
        index.upsert([renamed])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var count = 0
        repeat {
            count = try await database.read { try StoredRoomAttachment.fetchCount($0) }
            if count == 100 { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        #expect(count == 100)
        let filename = try await database.read { db in
            try StoredRoomAttachment.filter(Column("eventId") == records[0].eventId).fetchOne(db)?.filename
        }
        #expect(filename == "renamed.jpg")
    }

    private enum TestFailure: Error { case timeout, injected }
}
