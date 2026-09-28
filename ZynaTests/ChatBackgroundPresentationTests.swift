//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

@MainActor
extension ChatViewModel {
    func waitForPresentation() async throws {
        try await ChatBackgroundPresentationTests.wait { self.isPresentationIdleForTesting }
    }
}

@Suite("Background chat presentation", .serialized)
@MainActor
struct ChatBackgroundPresentationTests {
    private enum Failure: Error { case timeout }

    static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private final class Gate: @unchecked Sendable {
        let entered = Atomic(false)
        let semaphore = DispatchSemaphore(value: 0)
        func holdOnce() {
            guard entered.tryToSetFlag() else { return }
            #expect(!Thread.isMainThread)
            #expect(semaphore.wait(timeout: .now() + 5) == .success)
        }
        func release() { semaphore.signal() }
    }

    @Test("Initial load, pagination, refresh and local hide prepare off-main without synchronous DB calls")
    func backgroundPipeline() async throws {
        let (database, _, model) = try fixture(count: 240)
        defer { model.cleanup() }
        let lines = Atomic<[String]>([])
        let trace = try #require(HistoryPerformanceTrace.start(roomID: model.roomIdentifier, database: database,
            forceEnabled: true, interval: nil, output: { line in lines.modify { $0.append(line) } }))
        defer { trace.stop() }
        let preparations = Atomic(0)
        model.onRenderPreparedForTesting = {
            #expect(!Thread.isMainThread)
            preparations.modify { $0 += 1 }
        }
        model.onTableUpdate = { _, _ in #expect(Thread.isMainThread) }
        try await load(model)
        #expect(model.messages.count == 200)
        #expect(await page(model) == .applied)
        #expect(model.messages.count == 240)
        model.hideMessage("row-0")
        try await model.waitForPresentation()
        #expect(!model.messages.contains { $0.id == "row-0" })
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(!model.messages.contains { $0.id == "row-0" })
        trace.flush()
        #expect(preparations.wrappedValue >= 4)
        #expect(!lines.wrappedValue.contains { $0.contains("db.main=") })
    }

    @Test("A local deletion invalidates an older page and cannot be resurrected by its result")
    func hideWhilePagePrepared() async throws {
        let (_, _, model) = try fixture(count: 220)
        defer { model.cleanup() }
        try await load(model)
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        var result: ChatHistoryPageLoader.Result?
        model.loadHistoryPage(.older) { result = $0 }
        try await Self.wait { gate.entered.wrappedValue }
        model.hideMessage("row-219")
        gate.release()
        try await Self.wait { result != nil }
        #expect(result == .superseded)
        try await model.waitForPresentation()
        #expect(!model.messages.contains { $0.id == "row-219" })
        #expect(await page(model) == .applied)
        #expect(model.messages.count == 219)
        #expect(!model.messages.contains { $0.id == "row-219" })
    }

    @Test("History provenance arriving during preparation suppresses a remote deletion animation")
    func historyDuringLiveDeletion() async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        try await load(model)
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        model.onRedactedDetected = { _ in Issue.record("History was animated as a live deletion") }
        try await database.write { try $0.execute(sql: "UPDATE storedMessage SET contentType = 'redacted'") }
        model.refreshPresentationForTesting(.init(setCount: 1, redactedUpsertCount: 1))
        try await Self.wait { gate.entered.wrappedValue }
        model.refreshPresentationForTesting(.init(includesUnreportedHistory: true))
        gate.release()
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(model.messages.isEmpty)
    }

    @Test("A discarded preparation leaves a confirmed deletion available to the next presentation")
    func confirmationSurvivesDiscard() async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        try await load(model)
        model.registerPendingAnimatedRedactions(["row-0"])
        let roomID = model.roomIdentifier
        try await database.write { db in
            try PendingRedactionRecord(messageId: "row-0", roomId: roomID,
                itemIdentifier: .eventId("$event-0")).insert(db)
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted'")
        }
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        model.refreshPresentationForTesting(.init(setCount: 1, redactedUpsertCount: 1))
        try await Self.wait { gate.entered.wrappedValue }
        #expect(try await database.read { try PendingRedactionRecord.fetchCount($0) } == 1)
        // A view-owned animation state change invalidates the first snapshot.
        model.registerPartialReflowPreviews(["row-0": Data([1])])
        var animated = 0
        model.onRedactedDetected = { _ in animated += 1 }
        gate.release()
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(animated == 1)
        try await model.drainPresentationWorkerForTesting()
        #expect(try await database.read { try PendingRedactionRecord.fetchCount($0) } == 0)
    }

    @Test("Hiding another bubble cannot consume a confirmation absent from the accepted window")
    func localHidePreservesUnseenConfirmation() async throws {
        let (database, _, model) = try fixture(count: 2)
        defer { model.cleanup() }
        try await load(model)
        model.registerPendingAnimatedRedactions(["row-0"])
        let roomID = model.roomIdentifier
        try await database.write { db in
            try PendingRedactionRecord(messageId: "row-0", roomId: roomID,
                itemIdentifier: .eventId("$event-0")).insert(db)
        }
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted' WHERE id = 'row-0'")
        }
        // The SDK notification has not reached the UI yet. A presentation-
        // only rebuild still uses the previously accepted message window.
        model.hideMessage("row-1")
        try await model.waitForPresentation()
        try await model.drainPresentationWorkerForTesting()
        #expect(try await database.read { try PendingRedactionRecord.fetchCount($0) } == 1)
        #expect(model.messages.first?.content.textPreview == "Message 0")
        var animated = 0
        model.onRedactedDetected = { _ in animated += 1 }
        // Only the retained local intent permits an animation for history.
        model.refreshPresentationForTesting(.init(setCount: 1, includesUnreportedHistory: true))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        try await model.drainPresentationWorkerForTesting()
        #expect(animated == 1)
        #expect(try await database.read { try PendingRedactionRecord.fetchCount($0) } == 0)
    }

    @Test("Cleanup or account retirement rejects a prepared result", arguments: [false, true])
    func stopWhilePrepared(retire: Bool) async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        model.prepareHistoryReplacement(.newest) { _ in Issue.record("Retired presentation became ready") }
        try await Self.wait { gate.entered.wrappedValue }
        if retire { try await Task.detached { try database.close() }.value }
        else { model.cleanup() }
        gate.release()
        try await model.drainPresentationWorkerForTesting()
        #expect(model.messages.isEmpty)
    }

    @Test("Delayed acknowledgement preserves a newer deletion attempt")
    func acknowledgementCompare() async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        let roomID = model.roomIdentifier
        let snapshot = try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted'")
            try PendingRedactionRecord(messageId: "row-0", roomId: roomID,
                itemIdentifier: .eventId("$event-0")).insert(db)
            return try ChatTimelineLocalState.fetch(roomId: roomID, in: db)
        }
        try await database.write { try $0.execute(sql: "UPDATE pendingRedaction SET attemptCount = 2") }
        try await Task.detached {
            try snapshot.acknowledge(roomId: roomID, retiring: [], database: database, userId: "@alice:test")
        }.value
        #expect(try await database.read { try PendingRedactionRecord.fetchOne($0)?.attemptCount } == 2)
    }

    @Test("A newer reaction intent supersedes a prepared pending-removal overlay")
    func reactionIntentDuringPreparation() async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        let roomID = model.roomIdentifier
        try await database.write { db in
            let fetched = try StoredMessage.fetchOne(db)
            var record = try #require(fetched)
            record.reactionsJSON = StoredMessage.encodeReactions([
                .init(key: "👍", senders: [], isOwn: true, legacyCount: 1)
            ])
            try record.update(db)
        }
        try await load(model)
        try await database.write { db in
            try PendingReactionRecord(roomId: roomID, targetEventId: "$event-0", reactionKey: "👍",
                                      state: .removeQueued).insert(db)
        }
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await Self.wait { gate.entered.wrappedValue }
        try await database.write { try $0.execute(sql: "UPDATE pendingReaction SET state = 'failed'") }
        model.onTableUpdate = { [weak model] _, _ in
            #expect(model?.messages.first?.reactions.first?.isPendingRemoval == false)
        }
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        gate.release()
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(model.messages.first?.reactions.first?.isPendingRemoval == false)
    }

    @Test("An outgoing echo remains visible until hydration and is retired after UI acceptance")
    func outgoingHydration() async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        let roomID = model.roomIdentifier
        try await database.write { db in
            try Self.envelope(roomID: roomID).insert(db)
            try OutgoingEnvelopeItemRecord(id: "pending:0", groupId: "pending", itemIndex: 0,
                transactionId: "transaction", transportState: "sending").insert(db)
        }
        try await load(model)
        #expect(model.messages.count == 2)
        #expect(model.messages.contains { $0.content.textPreview == "Queued message" })
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET isOutgoing = 1, transactionId = 'transaction', contentBody = 'Queued message'")
            try db.execute(sql: "UPDATE pendingMediaGroupItem SET eventId = '$event-0', transportState = 'sent'")
        }
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        model.refreshPresentationForTesting(.init(setCount: 1, requiresPresentationRefresh: true))
        try await Self.wait { gate.entered.wrappedValue }
        #expect(try await database.read { try OutgoingEnvelopeRecord.fetchCount($0) } == 1)
        gate.release()
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        try await model.drainPresentationWorkerForTesting()
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.content.textPreview == "Queued message")
        #expect(try await database.read { try OutgoingEnvelopeRecord.fetchCount($0) } == 0)
    }

    @Test("Delayed retirement preserves an envelope whose transport changed after preparation")
    func envelopeAcknowledgementCompare() async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        let roomID = model.roomIdentifier
        let snapshot = try await database.write { db in
            try Self.envelope(roomID: roomID).insert(db)
            try OutgoingEnvelopeItemRecord(id: "pending:0", groupId: "pending", itemIndex: 0,
                                           transportState: "sent").insert(db)
            return try ChatTimelineLocalState.fetch(roomId: roomID, in: db)
        }
        try await database.write { try $0.execute(sql: "UPDATE pendingMediaGroupItem SET transportState = 'retrying'") }
        try await Task.detached {
            try snapshot.acknowledge(roomId: roomID, retiring: ["pending"], database: database, userId: "@alice:test")
        }.value
        #expect(try await database.read { try OutgoingEnvelopeRecord.fetchCount($0) } == 1)
    }

    nonisolated private static func envelope(roomID: String) -> OutgoingEnvelopeRecord {
        .init(id: "pending", roomId: roomID, caption: "Queued message", captionPlacement: "bottom",
              expectedItemCount: 1, createdAt: 300, kind: "text", state: "sending")
    }

    private func load(_ model: ChatViewModel) async throws {
        var applied = false
        model.prepareHistoryReplacement(.newest) { apply in apply(); applied = true }
        try await Self.wait { applied }
    }

    private func page(_ model: ChatViewModel) async -> ChatHistoryPageLoader.Result {
        await withCheckedContinuation { continuation in
            model.loadHistoryPage(.older) { continuation.resume(returning: $0) }
        }
    }

    private func fixture(count: Int) throws -> (AccountDatabase, MessageWindow, ChatViewModel) {
        let database = AccountDatabase(try DatabaseQueue())
        let roomID = "!background-\(UUID().uuidString):example.org"
        try database.write { db in
            func table<T>(_ name: String, sample: T, key: String) throws {
                let columns = Mirror(reflecting: sample).children.compactMap(\.label)
                let definitions = columns.map { $0 == key ? "\"\($0)\" TEXT PRIMARY KEY" : "\"\($0)\"" }
                try db.execute(sql: "CREATE TABLE \(name) (\(definitions.joined(separator: ",")))")
            }
            try table("storedMessage", sample: TimelineWriteFixture.message(0), key: "id")
            try table("pendingRedaction", sample: PendingRedactionRecord(messageId: "", roomId: "", itemIdentifier: nil), key: "messageId")
            try table("pendingReaction", sample: PendingReactionRecord(roomId: "", targetEventId: "", reactionKey: "", state: .removeQueued), key: "id")
            try table("pendingMediaGroup", sample: Self.envelope(roomID: roomID), key: "id")
            try table("pendingMediaGroupItem", sample: OutgoingEnvelopeItemRecord(id: "", groupId: "", itemIndex: 0), key: "id")
            try db.execute(sql: """
                CREATE TABLE pendingDirectImage (envelopeId TEXT);
                CREATE TABLE pendingDirectVideo (envelopeId TEXT);
                CREATE TABLE pendingDirectFile (envelopeId TEXT);
                """)
            for index in 0..<count {
                var record = TimelineWriteFixture.message(index)
                record.roomId = roomID
                try record.insert(db)
            }
        }
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        return (database, window, ChatViewModel(testingRoomId: roomID, dbQueue: database, window: window,
                                               includesLocalState: true))
    }
}
