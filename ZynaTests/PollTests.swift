//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import Foundation
import GRDB
import MatrixRustSDK
import os
import Testing
@testable import Zyna

private let pollRoom = "!poll:example.org"
private let pollUser = "@alice:example.org"

private func definition() -> PollDefinition {
    PollDefinition(question: "Where shall we meet?", answers: [
        .init(id: "park", text: "In the park"), .init(id: "cafe", text: "At the café")
    ], maxSelections: 1, kind: .disclosed)
}

private func message(_ poll: PollSnapshot, id: String = "$poll") -> ChatMessage {
    ChatMessage(id: id, eventId: id, transactionId: nil, itemIdentifier: .eventId(id),
        senderId: pollUser, senderDisplayName: "Alice", senderAvatarUrl: nil, isOutgoing: true,
        timestamp: Date(timeIntervalSince1970: 100), content: .poll(poll), reactions: [], replyInfo: nil,
        isEditable: poll.isEditable, isEdited: poll.isEdited, isEditPending: false, isEditFailed: false,
        latestEditEventId: nil, zynaAttributes: ZynaMessageAttributes(), sendStatus: "synced")
}

@Suite("Poll values")
struct PollTests {
    @Test("Stable answer IDs survive normalization, persistence and SDK conversion")
    func stableIDs() throws {
        var value = definition()
        value.question = "  Question  "
        value.answers[0].text = " Park\n"
        let restored = try #require(PollCoding.decode(PollDefinition.self, from: PollCoding.encode(value.normalized)))
        #expect(restored.question == "Question")
        #expect(restored.answers[0].text == "Park")
        #expect(try restored.sdkData().answers.map(\.id) == ["park", "cafe"])
        #expect(OutgoingEnvelopePayload.decodeJSON(OutgoingEnvelopePayload.poll(restored).encodeJSON()) == .poll(restored))
    }

    @Test("Invalid input is rejected before creating an outgoing operation")
    func validation() {
        var value = definition()
        #expect(value.isValidForCreation)
        value.maxSelections = 0
        #expect(!value.isValidForCreation)
        value.maxSelections = 3
        #expect(!value.isValidForCreation)
        value.maxSelections = 1
        value.answers[1] = .init(id: "park", text: "Duplicate ID")
        #expect(!value.isValidForCreation)
        value = definition()
        value.answers[0].text = " \n"
        #expect(!value.isValidForCreation)
        value = definition()
        value.answers = Array(repeating: .init(text: "Answer"), count: 21)
        #expect(!value.isValidForCreation)
    }

    @Test("Multiple answers count unique voters, and hidden results stay hidden")
    func aggregation() {
        let poll = PollSnapshot.fromSDK(question: "Question", kind: .undisclosed, maxSelections: 2,
            answers: [.init(id: "park", text: "Park"), .init(id: "cafe", text: "Café")],
            votes: ["park": [pollUser, pollUser, "@bob:example.org"], "cafe": [pollUser], "invalid": ["@x:x"]],
            endTime: nil, isEditable: false, isEdited: false, currentUserID: pollUser)
        #expect(poll.totalVoters == 2)
        #expect(poll.voteCounts == ["park": 2, "cafe": 1])
        #expect(poll.selectedAnswerIDs == ["park", "cafe"])
        #expect(!poll.showsResults)
        #expect(!poll.accessibilityDescription.contains("2 votes"))
        #expect(poll.validatesResponse([]))
        #expect(!poll.validatesResponse(["park", "park"]))
        #expect(!poll.validatesResponse(["invalid"]))
    }

    @Test("Only content geometry changes replace a poll cell")
    func inPlaceUpdates() {
        let original = PollSnapshot.empty(definition())
        var voted = original
        voted.voteCounts = ["park": 20, "cafe": 3]
        voted.totalVoters = 23
        voted.selectedAnswerIDs = ["park"]
        voted.isEditable = false
        #expect(MessageCellNode.canUpdateInPlace(old: message(original), new: message(voted)))
        voted.endTimestamp = 200
        #expect(MessageCellNode.canUpdateInPlace(old: message(original), new: message(voted)))
        voted.definition.question += " A different question."
        #expect(!MessageCellNode.canUpdateInPlace(old: message(original), new: message(voted)))
    }
}

@Suite("Poll redaction display", .serialized)
@MainActor
struct PollRedactionDisplayTests {
    @Test("A live poll redaction starts deletion and removes the row on animation completion",
          arguments: [true, false])
    func deletionLifecycle(localDeletion: Bool) async throws {
        let roomId = "!poll-redaction-\(UUID().uuidString):example.org"
        let original = StoredMessage(from: message(.empty(definition())), roomId: roomId)
        let database = AccountDatabase(try DatabaseQueue())
        // Match the message record without duplicating unrelated app migrations.
        let columns = Mirror(reflecting: original).children.compactMap(\.label)
        try await database.write { db in
            let definitions = columns.map { column in
                switch column {
                case "id": return "\"id\" TEXT PRIMARY KEY"
                case "timestamp": return "\"timestamp\" REAL"
                default: return "\"\(column)\""
                }
            }
            try db.execute(sql: "CREATE TABLE ignoredUser (userId TEXT PRIMARY KEY NOT NULL)")
            try db.execute(sql: "CREATE TABLE storedMessage (\(definitions.joined(separator: ",")))")
            try original.insert(db)
        }
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomId, dbQueue: database, window: window)
        defer { model.cleanup() }
        window.loadInitial()
        try await model.waitForPresentation()
        #expect(model.messages.map(\.id) == [original.id])
        if localDeletion {
            // The context menu retains the bubble until the splash finishes.
            model.registerPendingAnimatedRedactions([original.id])
        }
        var batches: [ChatViewModel.DetectedRedactionBatch] = []
        model.onRedactedDetected = { batches.append($0) }
        var rowDeletions: [IndexPath] = []
        model.onTableUpdate = { update, _ in
            if case .batch(let deletions, _, _, _, _) = update {
                rowDeletions.append(contentsOf: deletions)
            }
        }
        let originalRow = try #require(model.rows.firstIndex { $0.message?.id == original.id })

        // Materialize the server echo, then use the production observation path.
        try await database.write { db in
            var redacted = original
            redacted.contentType = "redacted"
            redacted.contentBody = nil
            redacted.contentPollJSON = nil
            try redacted.update(db)
        }
        window.refresh(origin: .timelineFlush(TimelineFlushSummary(setCount: 1, redactedUpsertCount: 1)))
        try await model.waitForPresentation()
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.messageIds == [original.id])
        #expect(batch.identityKeys.contains(original.timelineIdentityKey))
        #expect(batch.mediaGroups.isEmpty)
        #expect(model.messages.map(\.id) == [original.id])
        if localDeletion {
            guard case .poll = model.messages.first?.content else {
                Issue.record("The poll bubble must survive until the deletion animation completes")
                return
            }
        }

        // ChatView calls this when the splash completes (or immediately offscreen).
        model.hideMessages(batch.messageIds)
        try await model.waitForPresentation()
        #expect(model.messages.isEmpty)
        #expect(model.rows.isEmpty)
        #expect(rowDeletions.contains(IndexPath(row: originalRow, section: 0)))
        window.refresh()
        try await model.waitForPresentation()
        #expect(model.messages.isEmpty)
        #expect(batches.count == 1)
    }
}


@Suite("Durable poll operations")
struct PollStoreTests {
    private func database() throws -> AccountDatabase {
        AccountDatabase(try rawDatabase())
    }

    private func rawDatabase(beforePolls: Bool = false) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ignoredUser (userId TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE storedMessage (id TEXT PRIMARY KEY, roomId TEXT NOT NULL, eventId TEXT, contentType TEXT, contentBody TEXT);
                CREATE TABLE pendingMediaGroup (
                    id TEXT PRIMARY KEY, roomId TEXT NOT NULL, caption TEXT, captionPlacement TEXT,
                    expectedItemCount INTEGER, createdAt DOUBLE, replyEventId TEXT, replySenderId TEXT,
                    replySenderName TEXT, replyBody TEXT, kind TEXT, state TEXT, payloadJSON TEXT,
                    zynaAttributesJSON TEXT, matrixSessionId TEXT);
                CREATE TABLE pendingMediaGroupItem (
                    id TEXT PRIMARY KEY, groupId TEXT REFERENCES pendingMediaGroup(id) ON DELETE CASCADE,
                    itemIndex INTEGER, bindingToken TEXT, transactionId TEXT, eventId TEXT, mediaSourceJSON TEXT,
                    previewImageData BLOB, previewWidth INTEGER, previewHeight INTEGER, transportState TEXT);
                """)
        }
        if !beforePolls {
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v29_polls", migrate: PollStore.migrate)
            try migrator.migrate(queue)
        }
        return queue
    }

    private func ingest(_ snapshot: PollSnapshot, in queue: AccountDatabase, id: String = "$poll") throws {
        try queue.write { db in
            var record = StoredMessage(from: message(snapshot, id: id), roomId: pollRoom)
            try PollStore.ingest(&record, in: db)
            try db.execute(sql: "INSERT OR REPLACE INTO storedMessage (id, roomId, eventId, contentType, contentPollJSON, contentBody) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [record.id, record.roomId, record.eventId, record.contentType, record.contentPollJSON, record.contentBody])
        }
    }

    @Test("Creation and retry preserve one envelope and the complete original payload")
    func creationRetry() async throws {
        let db = try database()
        let store = PollStore(database: { db })
        let updates = OSAllocatedUnfairLock(initialState: [PollStore.RoomUpdate]())
        let subscription = store.roomDidUpdate.sink { update in updates.withLock { $0.append(update) } }
        defer { subscription.cancel() }
        let id = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "session")
        let initial = try #require(try await store.candidates().first)
        #expect(initial.id == id && initial.transactionId == id && initial.envelopeId == id)
        let sending = try #require(try await store.begin(initial))
        try await store.fail(sending, retryAfter: nil)
        let reopened = PollStore(database: { db })
        let reopenedSubscription = reopened.roomDidUpdate.sink { update in updates.withLock { $0.append(update) } }
        defer { reopenedSubscription.cancel() }
        try await reopened.retry(id: id, sessionId: "session")
        let retry = try #require(try await reopened.candidates().first)
        #expect(retry.transactionId == initial.transactionId)
        #expect(retry.definitionJSON == initial.definitionJSON)
        #expect(retry.attemptCount == 1)
        try await reopened.accept(retry, eventId: "$created")
        #expect(updates.withLock { $0 } == Array(repeating: .init(roomId: pollRoom, origin: .localMutation), count: 4))
        try await db.read { (db: Database) throws -> Void in
            #expect(try OutgoingEnvelopeRecord.fetchCount(db) == 1)
            #expect(try OutgoingEnvelopeItemRecord.fetchOne(db)?.eventId == "$created")
            #expect(try OutgoingEnvelopeRecord.fetchOne(db)?.state == "sent")
        }
    }

    @Test("An envelope write failure rolls back every part of creation")
    func atomicCreation() async throws {
        let db = try database()
        try await db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_poll BEFORE INSERT ON pendingPollOperation BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        let store = PollStore(database: { db })
        await #expect(throws: (any Error).self) {
            _ = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "session")
        }
        try await db.read { (db: Database) throws -> Void in
            #expect(try OutgoingEnvelopeRecord.fetchCount(db) == 0)
            #expect(try OutgoingEnvelopeItemRecord.fetchCount(db) == 0)
        }
    }

    @Test("Server echo retires the creation bubble by event ID, even after a remote edit")
    func envelopeHydration() async throws {
        let db = try database()
        let store = PollStore(database: { db })
        let id = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "session")
        let operation = try #require(try await store.candidates().first)
        try await store.fail(operation, retryAfter: nil)
        let failed = try await db.read { db in
            OutgoingEnvelopeSnapshot(record: try #require(try OutgoingEnvelopeRecord.fetchOne(db, key: id)),
                                     items: try OutgoingEnvelopeItemRecord.fetchAll(db))
        }
        let pending = ChatViewModel.singleEnvelopePlanForTesting(failed, messages: [], sessionId: "session")
        #expect(pending.pending?.canRetryOutgoingEnvelope == true)
        #expect(!pending.retired)
        #expect(ChatViewModel.singleEnvelopePlanForTesting(failed, messages: [], sessionId: "other").pending?.canRetryOutgoingEnvelope == false)
        try await store.accept(operation, eventId: "$created")
        let accepted = try await db.read { db in
            OutgoingEnvelopeSnapshot(record: try #require(try OutgoingEnvelopeRecord.fetchOne(db, key: id)),
                                     items: try OutgoingEnvelopeItemRecord.fetchAll(db))
        }
        var edited = PollSnapshot.empty(definition())
        edited.definition.question = "Updated elsewhere"
        edited.isEdited = true
        #expect(ChatViewModel.singleEnvelopePlanForTesting(accepted, messages: [message(edited, id: "$created")], sessionId: "session").retired)
        #expect(!ChatViewModel.singleEnvelopePlanForTesting(accepted, messages: [message(.empty(definition()), id: "$unrelated")], sessionId: "session").retired)
    }

    @Test("Unsent votes coalesce but an attempted vote remains immutable and ordered")
    func voteOrdering() async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "session")
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["cafe"], sessionId: "session")
        #expect(try await store.candidates().count == 1)
        let first = try #require(try await store.candidates().first)
        #expect(first.answers == ["cafe"])
        let sending = try #require(try await store.begin(first))
        try await store.fail(sending, retryAfter: 30)
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "session")
        let candidates = try await store.candidates()
        #expect(candidates.count == 2)
        #expect(candidates[0].transactionId == first.transactionId)
        #expect(candidates[0].answers == ["cafe"])
        #expect(candidates[1].answers == ["park"])
        let projected = try await db.read { db in try PollStore.presentation(.empty(definition()), roomId: pollRoom, eventId: "$poll", in: db) }
        #expect(projected.displayedSelection == ["park"])
        #expect(projected.totalVoters == 0)
    }

    @Test("Sync before HTTP completion settles the accepted action without a duplicate send")
    func syncBeforeAccept() async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        var result = PollSnapshot.empty(definition())
        result.selectedAnswerIDs = ["park"]
        result.voteCounts = ["park": 1]
        result.totalVoters = 1
        result.isEditable = false
        try ingest(result, in: db)
        try await store.accept(sending, eventId: "$vote")
        #expect(try await store.candidates().isEmpty)
        #expect(try await db.read { try PendingPollOperation.fetchCount($0) } == 0)
    }

    @Test("End prevents further actions and survives an incomplete timeline reset")
    func endingAndReset() async throws {
        let db = try database()
        var result = PollSnapshot.empty(definition())
        try ingest(result, in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .end, sessionId: "session")
        await #expect(throws: PollError.self) {
            try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "session")
        }
        result.endTimestamp = 200
        result.voteCounts = ["park": 4]
        result.totalVoters = 4
        result.isEditable = false
        try ingest(result, in: db)
        try ingest(.empty(definition()), in: db)
        let poll = try #require(try await store.polls(roomId: pollRoom).first?.snapshot)
        #expect(poll.hasEnded && poll.totalVoters == 4)
        #expect(try await store.candidates().isEmpty)
        #expect(try await db.read { try PendingPollOperation.fetchCount($0) } == 0)
    }

    @Test("Redaction cancels pending actions and permanently removes the poll from the index")
    func redaction() async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: [], sessionId: "session")
        try await db.write { db in
            var record = StoredMessage(from: message(.empty(definition())), roomId: pollRoom)
            record.contentType = "redacted"
            try PollStore.ingest(&record, in: db)
            #expect(record.contentBody == nil)
            #expect(record.contentPollJSON == nil)
            #expect(try StoredRoomPoll.fetchOne(db)?.snapshotJSON == "{}")
        }
        try ingest(.empty(definition()), in: db)
        #expect(try await store.candidates().isEmpty)
        #expect(try await store.polls(roomId: pollRoom).isEmpty)
        try await db.read { db in
            let record = try #require(try Row.fetchOne(db, sql: "SELECT * FROM storedMessage"))
            #expect(record["contentBody"] as String? == nil)
            #expect(record["contentPollJSON"] as String? == nil)
        }
    }

    @Test("Keyset pagination is deterministic for identical timestamps")
    func pagination() async throws {
        let db = try database()
        for id in ["$a", "$b", "$c"] { try ingest(.empty(definition()), in: db, id: id) }
        let store = PollStore(database: { db })
        let page = try await store.polls(roomId: pollRoom, limit: 2)
        #expect(page.map(\.eventId) == ["$c", "$b"])
        let last = try #require(page.last)
        let next = try await store.polls(roomId: pollRoom, before: .init(timestamp: last.timestamp, eventId: last.eventId), limit: 2)
        #expect(next.map(\.eventId) == ["$a"])
    }

    @Test("A later vote from another device settles an older accepted response")
    func supersededResponse() async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        try await store.accept(sending, eventId: "$oldVote")
        let accepted = try #require(try await store.awaitingConfirmation().first)
        let content = #"{"m.relates_to":{"rel_type":"m.reference","event_id":"$poll"},"org.matrix.msc3381.poll.response":{"answers":["cafe"]}}"#
        var event = RawRoomEvent(roomId: pollRoom, eventType: "org.matrix.msc3381.poll.response",
            eventId: "$newVote", sender: "@bob:example.org", originServerTsMs: 201,
            contentJson: content, rawJson: "{}", encryptionInfo: nil)
        try await store.reconcileConfirmationPage(accepted, serverTimestamp: 200, events: [event], next: "page2", userId: pollUser)
        let nextPage = try #require(try await store.awaitingConfirmation().first)
        #expect(nextPage.confirmationCursor == "page2")
        event.sender = pollUser
        try await store.reconcileConfirmationPage(nextPage, serverTimestamp: 200, events: [event], next: nil, userId: pollUser)
        #expect(try await store.awaitingConfirmation().isEmpty)
    }

    @Test("A previous login's operation cannot be retried under a new session")
    func sessionIsolation() async throws {
        let db = try database()
        let store = PollStore(database: { db })
        let id = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "old")
        let operation = try #require(try await store.candidates().first)
        try await store.fail(operation, retryAfter: nil)
        await #expect(throws: PollError.self) { try await store.retry(id: id, sessionId: "new") }
        #expect(try await store.candidates().isEmpty)
    }

    private func editEvent(_ id: String, sender: String = pollUser) -> RawRoomEvent {
        let content = #"{"m.relates_to":{"rel_type":"m.replace","event_id":"$poll"},"m.new_content":{"org.matrix.msc3381.poll.start":{"question":{"org.matrix.msc1767.text":"Edited"}}}}"#
        return RawRoomEvent(roomId: pollRoom, eventType: "org.matrix.msc3381.poll.start",
            eventId: id, sender: sender, originServerTsMs: 100,
            contentJson: content, rawJson: "{}", encryptionInfo: nil)
    }

    @Test("A competing effective edit settles our accepted edit across relation pages and restart")
    func supersededEdit() async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        var mine = definition()
        mine.question = "My edit"
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .edit, definition: mine, sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        try await store.accept(sending, eventId: "$mine", now: 100)
        var remote = PollSnapshot.empty(definition())
        remote.definition.question = "Newer edit on another device"
        remote.isEdited = true
        remote.latestEditEventID = "$newer"
        try ingest(remote, in: db)
        #expect(try await store.polls(roomId: pollRoom).first?.snapshot.definition == mine)

        let accepted = try #require(try await store.awaitingConfirmation().first)
        try await store.reconcileConfirmationPage(accepted, serverTimestamp: nil,
            events: [editEvent("$older"), editEvent("$mine")], next: "after-mine", userId: pollUser)
        let reopened = PollStore(database: { db })
        try await reopened.invalidateStaleOperations(sessionId: "relogin")
        let resumed = try #require(try await reopened.awaitingConfirmation().first)
        #expect(resumed.confirmationSawOwnEvent)
        #expect(resumed.confirmationCursor == "after-mine")
        try await reopened.reconcileConfirmationPage(resumed, serverTimestamp: nil,
            events: [editEvent("$newer", sender: "@bob:example.org")], next: nil, userId: pollUser)
        #expect(try await reopened.awaitingConfirmation().count == 1)
        let tail = try #require(try await reopened.awaitingConfirmation().first)
        try await reopened.reconcileConfirmationPage(tail, serverTimestamp: nil,
            events: [editEvent("$newer")], next: nil, userId: pollUser)
        let confirmed = try #require(try await reopened.polls(roomId: pollRoom).first?.snapshot)
        #expect(confirmed.pending == nil)
        #expect(confirmed.definition == remote.definition)
        #expect(confirmed.allowsVote)
        // The edit no longer blocks subsequent actions.
        try await reopened.enqueue(roomId: pollRoom, eventId: "$poll", kind: .end, sessionId: "session")
    }

    @Test("An earlier edit and a repeated tail page cannot falsely confirm a pending edit")
    func olderEditDoesNotConfirm() async throws {
        let db = try database()
        var earlier = PollSnapshot.empty(definition())
        earlier.isEdited = true
        earlier.latestEditEventID = "$earlier"
        try ingest(earlier, in: db)
        let store = PollStore(database: { db })
        var mine = definition()
        mine.question = "My new question"
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .edit, definition: mine, sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        try await store.accept(sending, eventId: "$mine")
        for _ in 0..<2 {
            let accepted = try #require(try await store.awaitingConfirmation().first)
            try await store.reconcileConfirmationPage(accepted, serverTimestamp: nil,
                events: [editEvent("$earlier"), editEvent("$mine")], next: nil, userId: pollUser)
            #expect(try await store.awaitingConfirmation().count == 1)
        }
        #expect(try await store.polls(roomId: pollRoom).first?.snapshot.definition == mine)
    }

    @Test("An edit echo is recognized by event ID on either side of HTTP completion", arguments: [true, false])
    func editEchoIdentity(syncFirst: Bool) async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        var edited = definition()
        edited.question = "Edited"
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .edit, definition: edited, sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        var echo = PollSnapshot.empty(edited)
        echo.isEdited = true
        echo.latestEditEventID = "$edit"
        if syncFirst { try ingest(echo, in: db) }
        try await store.accept(sending, eventId: "$edit")
        if !syncFirst { try ingest(echo, in: db) }
        #expect(try await store.awaitingConfirmation().isEmpty)
        #expect(try await store.polls(roomId: pollRoom).first?.snapshot.pending == nil)
    }

    @Test("Confirmation waits for sync, persists its deadline and never restarts at the oldest page")
    func confirmationScheduling() async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        try await store.accept(sending, eventId: "$vote", now: 100)
        let accepted = try #require(try await store.awaitingConfirmation().first)
        #expect(accepted.confirmationAt == 115)
        try await store.reconcileConfirmationPage(accepted, serverTimestamp: 200,
            events: [], next: "tail", userId: pollUser, now: 115)
        let reopened = PollStore(database: { db })
        let tail = try #require(try await reopened.awaitingConfirmation().first)
        #expect(tail.confirmationCursor == "tail")
        #expect(tail.confirmationAt == 117)
        try await reopened.reconcileConfirmationPage(tail, serverTimestamp: 200,
            events: [], next: nil, userId: pollUser, now: 117)
        let waiting = try #require(try await reopened.awaitingConfirmation().first)
        #expect(waiting.confirmationCursor == "tail")
        #expect(waiting.confirmationAt == 147)
        try await reopened.deferConfirmation(waiting, now: 147)
        #expect(try await reopened.awaitingConfirmation().first?.confirmationAt == 177)
        // A stale completion must not overwrite a cursor that already advanced.
        try await reopened.reconcileConfirmationPage(accepted, serverTimestamp: 200,
            events: [], next: "stale", userId: pollUser, now: 180)
        #expect(try await reopened.awaitingConfirmation().first?.confirmationCursor == "tail")
    }

    @Test("A confirmed end cancels every operation state and late HTTP cannot resurrect it",
          arguments: ["queued", "sending", "retrying", "failed", "accepted"])
    func endCancelsOperations(state: String) async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        try await db.write { db in
            var operation = candidate
            operation.state = state
            operation.attemptCount = state == "queued" ? 0 : 1
            try operation.update(db)
        }
        var ended = PollSnapshot.empty(definition())
        ended.endTimestamp = 200
        try ingest(ended, in: db)
        #expect(try await store.begin(candidate) == nil)
        try await store.accept(candidate, eventId: "$late-vote")
        try await store.fail(candidate, retryAfter: 2)
        #expect(try await db.read { try PendingPollOperation.fetchCount($0) } == 0)
        #expect(try await store.polls(roomId: pollRoom).first?.snapshot.pending == nil)
    }

    @Test("Accepted actions survive relogin and settle by sync without resending",
          arguments: [PollOperationKind.response, .edit, .end])
    func staleAcceptedAction(kind: PollOperationKind) async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        var edited = definition()
        edited.question = "Edited question"
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: kind,
            definition: kind == .edit ? edited : nil, answers: kind == .response ? ["park"] : nil, sessionId: "old")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        try await store.accept(sending, eventId: "$accepted")
        try await store.invalidateStaleOperations(sessionId: "new")
        let pending = try #require(try await store.polls(roomId: pollRoom).first?.snapshot.pending)
        #expect(!pending.failed && pending.awaitingSync && pending.failureReason == nil)
        #expect(try await store.candidates().isEmpty)
        #expect(try await db.read { try PendingPollOperation.filter(Column("state") == "accepted").fetchCount($0) } == 1)
        var echo = PollSnapshot.empty(definition())
        switch kind {
        case .response: echo.selectedAnswerIDs = ["park"]
        case .edit:
            echo.definition = edited
            echo.isEdited = true
            echo.latestEditEventID = "$accepted"
        case .end: echo.endTimestamp = 200
        case .start: break
        }
        try ingest(echo, in: db)
        #expect(try await store.awaitingConfirmation().isEmpty)
        #expect(try await db.read { try PendingPollOperation.fetchCount($0) } == 0)
        #expect(try await store.polls(roomId: pollRoom).first?.snapshot.pending == nil)
    }

    @Test("Unaccepted stale actions are dismissible without a misleading Retry",
          arguments: ["queued", "sending", "retrying", "failed"])
    func staleUnacceptedAction(state: String) async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "old")
        let candidate = try #require(try await store.candidates().first)
        try await db.write { db in
            try db.execute(sql: "UPDATE pendingPollOperation SET state = ?, retryAt = 123 WHERE id = ?", arguments: [state, candidate.id])
        }
        // The defensive branch in the send loop uses the same invalidation path.
        try await store.invalidateStaleOperations(sessionId: "new", operationID: candidate.id)
        let failure = try #require(try await store.polls(roomId: pollRoom).first?.snapshot.pending)
        #expect(failure.failed && !failure.canRetry)
        #expect(failure.failureReason == .staleSession)
        await #expect(throws: PollError.self) { try await store.retry(id: failure.operationID, sessionId: "new") }
        try await store.dismissFailure(id: failure.operationID)
        #expect(try await store.polls(roomId: pollRoom).first?.snapshot.pending == nil)
    }

    @Test("A vote interrupted by logout settles when sync confirms its choice or withdrawal",
          arguments: [["park"], []], [true, false])
    func staleSendingResponse(answers: [String], syncBeforeRelogin: Bool) async throws {
        let db = try database()
        var initial = PollSnapshot.empty(definition())
        initial.selectedAnswerIDs = ["cafe"]
        try ingest(initial, in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: answers, sessionId: "old")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        #expect(sending.eventId == nil && sending.attemptCount == 1)

        var echo = initial
        echo.selectedAnswerIDs = answers
        if syncBeforeRelogin { try ingest(echo, in: db) }
        // No HTTP result reaches the outbox before the session changes.
        try await store.invalidateStaleOperations(sessionId: "new")
        if !syncBeforeRelogin {
            let failure = try #require(try await store.polls(roomId: pollRoom).first?.snapshot.pending)
            #expect(failure.failed && failure.failureReason == .staleSession && !failure.canRetry)
            try ingest(echo, in: db)
        }
        #expect(try await store.candidates().isEmpty)
        #expect(try await store.polls(roomId: pollRoom).first?.snapshot.pending == nil)
        try await db.read { (db: Database) throws -> Void in
            #expect(try PendingPollOperation.fetchCount(db) == 0)
            let json = try #require(try String.fetchOne(db, sql: "SELECT contentPollJSON FROM storedMessage"))
            let poll = try #require(PollCoding.decode(PollSnapshot.self, from: json))
            #expect(poll.pending == nil && poll.selectedAnswerIDs == answers)
        }
    }

    @Test("A different confirmed choice leaves an interrupted vote dismissible", arguments: [["cafe"], []])
    func staleSendingResponseMismatch(confirmedAnswers: [String]) async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "old")
        let candidate = try #require(try await store.candidates().first)
        _ = try #require(try await store.begin(candidate))
        try await store.invalidateStaleOperations(sessionId: "new")
        var echo = PollSnapshot.empty(definition())
        echo.selectedAnswerIDs = confirmedAnswers
        try ingest(echo, in: db)
        let poll = try #require(try await store.polls(roomId: pollRoom).first?.snapshot)
        let failure = try #require(poll.pending)
        #expect(poll.displayedSelection == confirmedAnswers)
        #expect(failure.failed && failure.failureReason == .staleSession && !failure.canRetry)
        #expect(try await store.candidates().isEmpty)
        #expect(try await db.read { try PendingPollOperation.fetchCount($0) } == 1)
    }

    @Test("Matching sync does not clear unsent stale actions or ordinary transport failures", arguments: [true, false])
    func matchingResponsePreservesOtherFailures(attempted: Bool) async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .response, answers: ["park"], sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        if attempted {
            let sending = try #require(try await store.begin(candidate))
            try await store.fail(sending, retryAfter: nil)
        } else {
            try await store.invalidateStaleOperations(sessionId: "new")
        }
        var echo = PollSnapshot.empty(definition())
        echo.selectedAnswerIDs = ["park"]
        try ingest(echo, in: db)
        let failure = try #require(try await store.polls(roomId: pollRoom).first?.snapshot.pending)
        #expect(failure.failed)
        #expect(failure.canRetry == attempted)
        #expect(failure.failureReason == (attempted ? nil : .staleSession))
        #expect(try await db.read { try PendingPollOperation.fetchCount($0) } == 1)
    }

    enum SendInterruption: CaseIterable {
        case none, cancellation, logout, relogin, syncStopped
    }

    @Test("A session change during preparation prevents transport and preserves durable intent",
          .timeLimit(.minutes(1)), arguments: SendInterruption.allCases)
    @MainActor
    func sessionChangeBeforeTransport(interruption: SendInterruption) async throws {
        let db = try database()
        let store = PollStore(database: { db })
        let id = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "old")
        let candidate = try #require(try await store.candidates().first)
        var currentSession: String? = "old"
        var syncing = true
        var requests = 0
        var resume: CheckedContinuation<Void, Never>?
        let suspended = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            defer { suspended.continuation.finish() }
            let started = try #require(try await store.begin(candidate))
            // Model the asynchronous preparation after the durable write.
            // Like UniFFI, this suspension does not throw on cancellation.
            await withCheckedContinuation { continuation in
                resume = continuation
                suspended.continuation.yield(())
            }
            let eventId = try await OutgoingPollOutboxService.sendIfCurrent(sessionId: "old",
                currentSessionId: { currentSession }, isSyncing: { syncing }) {
                    requests += 1
                    return "$created"
                }
            try await store.accept(started, eventId: eventId)
            return eventId
        }
        var iterator = suspended.stream.makeAsyncIterator()
        guard await iterator.next() != nil else {
            _ = try await task.value
            Issue.record("The send must reach the preparation suspension")
            return
        }
        switch interruption {
        case .none: break
        case .cancellation: task.cancel()
        case .logout: currentSession = nil
        case .relogin: currentSession = "new"
        case .syncStopped: syncing = false
        }
        resume?.resume()
        if interruption == .none {
            #expect(try await task.value == "$created")
            #expect(requests == 1)
        } else {
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(requests == 0)
        }
        let stored = try #require(try await db.read { try PendingPollOperation.fetchOne($0, key: id) })
        #expect(stored.state == (interruption == .none ? "accepted" : "sending"))
        #expect(stored.attemptCount == 1 && stored.transactionId == candidate.transactionId)
        #expect(stored.definitionJSON == candidate.definitionJSON && stored.sessionId == "old")
    }

    @Test("An accepted creation from an old login stays sent while waiting for its echo")
    func staleAcceptedCreation() async throws {
        let db = try database()
        let store = PollStore(database: { db })
        let id = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "old")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        try await store.accept(sending, eventId: "$created")
        try await store.invalidateStaleOperations(sessionId: "new")
        let envelope = try await db.read { db in
            let record = try #require(try OutgoingEnvelopeRecord.fetchOne(db, key: id))
            return OutgoingEnvelopeSnapshot(record: record, items: try OutgoingEnvelopeItemRecord.fetchAll(db))
        }
        let rendered = try #require(ChatViewModel.singleEnvelopePlanForTesting(envelope, messages: [], sessionId: "new").pending)
        #expect(rendered.effectiveSendStatus == "sent")
        #expect(!rendered.canRetryOutgoingEnvelope)
        #expect(try await store.candidates().isEmpty)
    }

    @Test("A redaction received before the poll start prevents resurrection even with unknown encrypted type",
          arguments: [true, false])
    func redactionBeforeStart(knownType: Bool) async throws {
        let db = try database()
        try await db.write { db in
            var record = StoredMessage(from: message(.empty(definition())), roomId: pollRoom)
            record.contentType = "redacted"
            record.contentBody = nil
            record.contentPollJSON = nil
            try PollStore.ingest(&record, isPollStart: knownType, in: db)
            #expect(try StoredRoomPoll.fetchCount(db) == (knownType ? 1 : 0))
            try db.execute(sql: "INSERT INTO storedMessage (id, roomId, eventId, contentType) VALUES (?, ?, ?, 'redacted')",
                arguments: [record.id, record.roomId, record.eventId])
        }
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        #expect(try await store.polls(roomId: pollRoom).isEmpty)
        try await db.read { (db: Database) throws -> Void in
            #expect(try StoredRoomPoll.fetchOne(db)?.snapshotJSON == "{}")
            #expect(try String.fetchOne(db, sql: "SELECT contentBody FROM storedMessage") == nil)
        }
    }

    @Test("Redaction also removes the creation payload on either side of HTTP completion",
          arguments: [true, false], [true, false])
    func redactedCreation(syncFirst: Bool, knownType: Bool) async throws {
        let db = try database()
        let store = PollStore(database: { db })
        _ = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "session")
        let candidate = try #require(try await store.candidates().first)
        let sending = try #require(try await store.begin(candidate))
        if !syncFirst { try await store.accept(sending, eventId: "$poll") }
        try await db.write { db in
            var record = StoredMessage(from: message(.empty(definition())), roomId: pollRoom)
            record.contentType = "redacted"
            record.contentBody = nil
            record.contentPollJSON = nil
            try PollStore.ingest(&record, isPollStart: knownType, in: db)
            try db.execute(sql: "INSERT INTO storedMessage (id, roomId, eventId, contentType) VALUES (?, ?, ?, 'redacted')",
                arguments: [record.id, record.roomId, record.eventId])
        }
        if syncFirst { try await store.accept(sending, eventId: "$poll") }
        try await db.read { (db: Database) throws -> Void in
            #expect(try OutgoingEnvelopeRecord.fetchCount(db) == 0)
            #expect(try OutgoingEnvelopeItemRecord.fetchCount(db) == 0)
            #expect(try PendingPollOperation.fetchCount(db) == 0)
        }
    }

    @Test("Unrelated redactions do not grow the poll catalog and repeated poll redactions do not write")
    func redactionScope() async throws {
        let db = try database()
        try await db.write { db in
            #expect(PollStore.isPollStartEvent(originalJSON: #"{"type":"org.matrix.msc3381.poll.start","content":{}}"#))
            for type in ["m.room.message", "m.room.encrypted", "org.matrix.msc3381.poll.response"] {
                #expect(!PollStore.isPollStartEvent(originalJSON: "{\"type\":\"\(type)\"}"))
            }
            var record = StoredMessage(from: message(.empty(definition())), roomId: pollRoom)
            record.contentType = "redacted"
            record.contentBody = nil
            record.contentPollJSON = nil
            try PollStore.ingest(&record, in: db)
            #expect(try StoredRoomPoll.fetchCount(db) == 0)
            try PollStore.ingest(&record, isPollStart: true, in: db)
            let changes = db.totalChangesCount
            try PollStore.ingest(&record, isPollStart: true, in: db)
            #expect(db.totalChangesCount == changes)
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM roomPoll WHERE roomId = ? AND isRedacted = 0 ORDER BY timestamp DESC, eventId DESC LIMIT 50", arguments: [pollRoom]).map { $0["detail"] as String }
            #expect(plan.joined().contains("roomPoll_active_room_date"))
            #expect(!plan.joined().contains("TEMP B-TREE"))
        }
    }

    @Test("An invalid edit reports invalid content without creating an operation")
    func invalidEdit() async throws {
        let db = try database()
        try ingest(.empty(definition()), in: db)
        let store = PollStore(database: { db })
        do {
            try await store.enqueue(roomId: pollRoom, eventId: "$poll", kind: .edit, definition: .draft, sessionId: "session")
            Issue.record("An invalid edit must be rejected")
        } catch PollError.invalidContent { }
        #expect(try await store.candidates().isEmpty)
    }

    @Test("The poll migration preserves existing messages and outgoing media and runs only once")
    func pollMigration() async throws {
        let raw = try rawDatabase(beforePolls: true)
        let db = AccountDatabase(raw)
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO storedMessage (id, roomId, eventId, contentType, contentBody)
                VALUES ('existing', '!poll:example.org', '$existing', 'text', 'Keep this message');
                INSERT INTO pendingMediaGroup (id, roomId, kind, state, payloadJSON)
                VALUES ('media', '!poll:example.org', 'media', 'queued', '{"existing":"payload"}');
                INSERT INTO pendingMediaGroupItem (id, groupId, transactionId, transportState)
                VALUES ('item', 'media', 'existing-transaction', 'pending');
                """)
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v29_polls", migrate: PollStore.migrate)
        try migrator.migrate(raw)
        let store = PollStore(database: { db })
        let id = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "session")
        try migrator.migrate(raw)
        try await db.read { db in
            #expect(try String.fetchOne(db, sql: "SELECT contentBody FROM storedMessage WHERE id = 'existing'") == "Keep this message")
            #expect(try String.fetchOne(db, sql: "SELECT contentPollJSON FROM storedMessage WHERE id = 'existing'") == nil)
            #expect(try String.fetchOne(db, sql: "SELECT payloadJSON FROM pendingMediaGroup WHERE id = 'media'") == #"{"existing":"payload"}"#)
            #expect(try String.fetchOne(db, sql: "SELECT state FROM pendingMediaGroup WHERE id = 'media'") == "queued")
            #expect(try String.fetchOne(db, sql: "SELECT transactionId FROM pendingMediaGroupItem WHERE id = 'item' AND groupId = 'media'") == "existing-transaction")
            #expect(try String.fetchOne(db, sql: "SELECT transportState FROM pendingMediaGroupItem WHERE id = 'item'") == "pending")
            #expect(try PendingPollOperation.fetchCount(db) == 1)
            let operation = try #require(try PendingPollOperation.fetchOne(db, key: id))
            #expect(operation.definition == definition())
            #expect(operation.state == "queued" && operation.attemptCount == 0)
            #expect(operation.confirmationAt == nil && !operation.confirmationSawOwnEvent)
            #expect(operation.confirmationEditEventID == nil && operation.failureReason == nil)
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") == ["v29_polls"])
        }
    }

    @Test("A damaged outgoing poll renders as unsupported with no fabricated answers or retry")
    func corruptedEnvelope() async throws {
        let db = try database()
        let store = PollStore(database: { db })
        let id = try await store.create(roomId: pollRoom, definition: definition(), sessionId: "session")
        let envelope = try await db.write { db in
            try db.execute(sql: "UPDATE pendingMediaGroup SET payloadJSON = 'broken', state = 'failed' WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE pendingMediaGroupItem SET transportState = 'failed' WHERE groupId = ?", arguments: [id])
            let record = try #require(try OutgoingEnvelopeRecord.fetchOne(db, key: id))
            return OutgoingEnvelopeSnapshot(record: record, items: try OutgoingEnvelopeItemRecord.fetchAll(db))
        }
        #expect(envelope.payload == .invalid)
        let rendered = try #require(ChatViewModel.singleEnvelopePlanForTesting(envelope, messages: [], sessionId: "session").pending)
        guard case .unsupported = rendered.content else {
            Issue.record("Corrupt content must not become an empty poll")
            return
        }
        #expect(!rendered.canRetryOutgoingEnvelope)
        #expect(rendered.effectiveSendStatus == "failed")
        #expect(OutgoingEnvelopePayload.decodeJSON(OutgoingEnvelopePayload.poll(.draft).encodeJSON()) == nil)
    }
}

@Suite("Poll rendering", .serialized)
@MainActor
struct PollRenderingTests {
    @Test("Reverting a multi-answer draft hides Vote, while withdrawing an existing vote remains possible")
    func revertedSelection() throws {
        var poll = PollSnapshot.empty(definition())
        poll.definition.maxSelections = 2
        let cell = PollMessageCellNode(message: message(poll))
        cell.updatePermissions(vote: true, edit: false, end: true)
        var submissions: [[String]] = []
        cell.onPollAction = { if case .vote(let answers) = $0 { submissions.append(answers) } }
        for _ in 0..<2 {
            let park = try #require(cell.pollAccessibilityActions().first { $0.name.hasSuffix("In the park") })
            #expect(park.actionHandler?(park) == true)
        }
        #expect(!cell.pollAccessibilityActions().contains { $0.name == String(localized: "Vote") })
        #expect(submissions.isEmpty)
        poll.selectedAnswerIDs = ["park"]
        cell.updatePoll(poll)
        let selectedPark = try #require(cell.pollAccessibilityActions().first { $0.name.hasSuffix("In the park") })
        #expect(selectedPark.actionHandler?(selectedPark) == true)
        let withdraw = try #require(cell.pollAccessibilityActions().first { $0.name == String(localized: "Vote") })
        #expect(withdraw.actionHandler?(withdraw) == true)
        #expect(submissions == [[]])
    }

    @Test("An action from an old session never advertises Retry")
    func staleActionFooter() {
        var poll = PollSnapshot.empty(definition())
        poll.pending = .init(operationID: "stale", kind: .response, answers: nil,
            failed: true, awaitingSync: false, failureReason: .staleSession)
        let cell = PollMessageCellNode(message: message(poll))
        cell.updatePermissions(vote: true, edit: false, end: true)
        #expect(!cell.pollAccessibilityActions().contains { $0.name == String(localized: "Couldn't send · Retry") })
        poll.pending?.failureReason = nil
        cell.updatePoll(poll)
        #expect(cell.pollAccessibilityActions().contains { $0.name == String(localized: "Couldn't send · Retry") })
    }

    @Test("A multi-answer draft survives sync and can replace a pending vote")
    func selectionDuringSync() throws {
        var poll = PollSnapshot.empty(definition())
        poll.definition.maxSelections = 2
        poll.pending = .init(operationID: "first", kind: .response, answers: ["park"], failed: false, awaitingSync: false)
        let cell = PollMessageCellNode(message: message(poll))
        cell.updatePermissions(vote: true, edit: false, end: true)
        var submissions: [[String]] = []
        cell.onPollAction = { if case .vote(let answers) = $0 { submissions.append(answers) } }
        let cafe = try #require(cell.pollAccessibilityActions().first { $0.name == "At the café" })
        #expect(cafe.actionHandler?(cafe) == true)
        #expect(submissions.isEmpty)
        poll.pending = nil
        poll.selectedAnswerIDs = ["park"]
        poll.totalVoters = 4
        poll.voteCounts = ["park": 3, "cafe": 1]
        cell.updatePoll(poll)
        let vote = try #require(cell.pollAccessibilityActions().first { $0.name == String(localized: "Vote") })
        #expect(vote.actionHandler?(vote) == true)
        #expect(submissions == [["park", "cafe"]])
        poll.pending = .init(operationID: "second", kind: .response, answers: ["park", "cafe"], failed: false, awaitingSync: false)
        cell.updatePoll(poll)
        #expect(!cell.pollAccessibilityActions().contains { $0.name == String(localized: "Vote") })
    }

    @Test("Generate poll UI preview images", .disabled("Manual visual inspection helper; not a regression test"))
    func previewArtifacts() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let root = UIViewController()
        root.view.backgroundColor = .appBG
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        var poll = PollSnapshot.empty(definition())
        poll.voteCounts = ["park": 12, "cafe": 8]
        poll.selectedAnswerIDs = ["park"]
        poll.totalVoters = 20
        poll.isEditable = false
        let cell = PollMessageCellNode(message: message(poll))
        cell.updatePermissions(vote: true, edit: false, end: true)
        let size = cell.layoutThatFits(ASSizeRange(min: CGSize(width: 390, height: 0), max: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))).size
        cell.frame = CGRect(origin: CGPoint(x: 0, y: 150), size: size)
        root.view.addSubview(cell.view)
        cell.layoutIfNeeded()
        cell.recursivelyEnsureDisplaySynchronously(true)
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
            root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        try image.pngData()?.write(to: directory.appendingPathComponent("poll-bubble.png"))

        let model = PollComposerModel(definition: definition()) { _ in }
        let controller = GlassHostingController(title: "New poll", rootView: PollComposerScreen(model: model), onBack: {})
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        controller.glassTopBar.recursivelyEnsureDisplaySynchronously(true)
        let form = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        try form.pngData()?.write(to: directory.appendingPathComponent("poll-form.png"))
    }

    @Test("Voting and ending preserve bubble dimensions at narrow and wide widths")
    func geometry() throws {
        for width: CGFloat in [320, 430] {
            let original = PollSnapshot.empty(definition())
            let cell = PollMessageCellNode(message: message(original))
            cell.updatePermissions(vote: true, edit: true, end: true)
            let sizeRange = ASSizeRange(min: CGSize(width: width, height: 0), max: CGSize(width: width, height: .greatestFiniteMagnitude))
            let before = cell.layoutThatFits(sizeRange).size
            cell.frame = CGRect(origin: .zero, size: before)
            _ = cell.view
            cell.layoutIfNeeded()
            var voted = original
            voted.voteCounts = ["park": 1234, "cafe": 89]
            voted.totalVoters = 1323
            voted.selectedAnswerIDs = ["park"]
            voted.isEditable = false
            cell.updatePoll(voted)
            cell.updatePermissions(vote: true, edit: false, end: true)
            #expect(cell.layoutThatFits(sizeRange).size == before)
            voted.endTimestamp = 200
            cell.updatePoll(voted)
            cell.updatePermissions(vote: false, edit: false, end: false)
            #expect(cell.layoutThatFits(sizeRange).size == before)
            #expect(before.width <= width && before.height > 100)
        }
    }
}
