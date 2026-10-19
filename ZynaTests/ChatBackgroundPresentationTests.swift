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
    static func wait(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            try #require(Date() < deadline, "Timed out waiting for presentation", sourceLocation: sourceLocation)
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

    @Test("Confirming a deletion after its waiting placeholder cannot bring the old bubble back",
          arguments: [false, true])
    func confirmationAfterPlaceholder(renamed: Bool) async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        try await load(model)
        model.registerPendingAnimatedRedactions(["row-0"])
        let roomID = model.roomIdentifier
        try await database.write { db in
            try PendingRedactionRecord(messageId: "row-0", roomId: roomID,
                itemIdentifier: .eventId("$event-0"), createdAt: Date().timeIntervalSince1970 - 3).insert(db)
        }
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(model.messages.map(\.id) == ["pending-redaction:row-0"])
        var confirmations = 0
        model.onRedactedDetected = { _ in
            confirmations += 1
            // Observe before the view finishes the deletion. Restoring the
            // original even for this one presentation is the regression.
            #expect(model.messages.isEmpty)
        }
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted', contentBody = NULL")
            if renamed { try db.execute(sql: "UPDATE storedMessage SET id = 'zz-renamed'") }
        }
        model.refreshPresentationForTesting(.init(setCount: 1, redactedUpsertCount: 1))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(confirmations == 1)
        #expect(model.messages.isEmpty)
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
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
            return try ChatTimelineLocalState.fetch(roomId: roomID, window: [], in: db)
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
            return try ChatTimelineLocalState.fetch(roomId: roomID, window: [], in: db)
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

    @Test("A large sent outbox loads previews only for its current history window")
    func sentOutboxWindow() async throws {
        let (database, window, model) = try fixture(count: 2_000)
        defer { model.cleanup() }
        let roomID = model.roomIdentifier
        let preview = Data(repeating: 1, count: 16_384)
        try await database.write { db in
            for index in 0..<2_000 {
                var message = TimelineWriteFixture.message(index)
                message.roomId = roomID
                message.isOutgoing = true
                message.contentType = "image"
                message.contentMediaJSON = #"{"url":"mxc://example.org/photo"}"#
                try message.update(db)
                var envelope = Self.envelope(roomID: roomID)
                envelope.id = "sent-\(index)"
                envelope.kind = "image"
                envelope.state = "sent"
                envelope.createdAt = Double(index)
                envelope.payloadJSON = OutgoingEnvelopePayload.image(.init(caption: nil, width: 100, height: 100)).encodeJSON()
                try envelope.insert(db)
                try OutgoingEnvelopeItemRecord(id: "\(envelope.id):0", groupId: envelope.id, itemIndex: 0,
                    eventId: message.eventId, previewImageData: preview, transportState: "sent").insert(db)
            }
        }
        let request = window.replacementRequest(.newest)
        let page = try #require(try await Task.detached { try request.fetch(includingLocalState: true) }.value)
        #expect(page.localState.envelopeRecords.count == 200)
        #expect(page.localState.envelopeItems.count == 200)
        let previewBytes = page.localState.envelopeItems.reduce(0) { $0 + ($1.previewImageData?.count ?? 0) }
        #expect(previewBytes == 200 * preview.count)
        // Filtering does not acknowledge records or discard their previews.
        #expect(try await database.read { try OutgoingEnvelopeRecord.fetchCount($0) } == 2_000)
        try await load(model)
        try await model.drainPresentationWorkerForTesting()
        #expect(model.messages.count == 200)
        #expect(model.messages.first?.id == "row-1999")
        #expect(try await database.read { try OutgoingEnvelopeRecord.fetchCount($0) } == 1_800)
        var applied = false
        model.prepareHistoryReplacement(.oldest) { apply in apply(); applied = true }
        try await Self.wait { applied }
        try await model.drainPresentationWorkerForTesting()
        #expect(model.messages.count == 200)
        #expect(model.messages.last?.id == "row-0")
        #expect(try await database.read { try OutgoingEnvelopeRecord.fetchCount($0) } == 1_600)
    }

    @Test("Window scoping preserves unfinished sends and requires a remote echo in the same room",
          arguments: ["sent", "transaction", "unobserved", "localEcho", "foreignRoom", "incoming", "retrying", "itemRetry", "missingItem"])
    func outboxScopeConfirmation(scenario: String) async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        let roomID = model.roomIdentifier
        let snapshot = try await database.write { db in
            var message = TimelineWriteFixture.message(0)
            message.roomId = scenario == "foreignRoom" ? "!other:example.org" : roomID
            message.isOutgoing = scenario != "incoming"
            message.transactionId = "transaction"
            if scenario == "localEcho" { message.eventId = nil }
            try message.update(db)
            var envelope = Self.envelope(roomID: roomID)
            envelope.state = scenario == "retrying" ? "retrying" : "sent"
            try envelope.insert(db)
            if scenario != "missingItem" {
                try OutgoingEnvelopeItemRecord(id: "pending:0", groupId: "pending", itemIndex: 0,
                    transactionId: scenario == "unobserved" ? "unknown" : "transaction",
                    eventId: scenario == "transaction" ? nil : "$event-0",
                    previewImageData: Data([1, 2, 3]),
                    transportState: scenario == "itemRetry" ? "retrying" : "sent").insert(db)
            }
            if scenario == "unobserved" { try message.delete(db) }
            return try ChatTimelineLocalState.fetch(roomId: roomID, window: [], in: db)
        }
        #expect(snapshot.envelopeRecords.isEmpty == ["sent", "transaction"].contains(scenario))
        #expect(try await database.read { try OutgoingEnvelopeRecord.fetchCount($0) } == 1)
    }

    @Test("A sent album remains whole if any bound event belongs to the window", arguments: [false, true])
    func outboxScopeAlbum(intersectsWindow: Bool) async throws {
        let (database, _, model) = try fixture(count: 2)
        defer { model.cleanup() }
        let roomID = model.roomIdentifier
        let snapshot = try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET isOutgoing = 1")
            var envelope = Self.envelope(roomID: roomID)
            envelope.kind = "mediaBatch"
            envelope.state = "sent"
            envelope.expectedItemCount = 2
            try envelope.insert(db)
            for index in 0..<2 {
                try OutgoingEnvelopeItemRecord(id: "pending:\(index)", groupId: "pending", itemIndex: index,
                    eventId: "$event-\(index)", previewImageData: Data([1]), transportState: "sent").insert(db)
            }
            let window = intersectsWindow ? try StoredMessage.filter(Column("id") == "row-1").fetchAll(db) : []
            return try ChatTimelineLocalState.fetch(roomId: roomID, window: window, in: db)
        }
        #expect(snapshot.envelopeRecords.count == (intersectsWindow ? 1 : 0))
        #expect(snapshot.envelopeItems.count == (intersectsWindow ? 2 : 0))
        #expect(try await database.read { try OutgoingEnvelopeRecord.fetchCount($0) } == 1)
    }

    @Test("An ignored-list change refreshes a live chat and its search without an SDK message diff")
    func ignoredListRefresh() async throws {
        let (database, _, model) = try fixture(count: 2)
        defer { model.cleanup() }
        try await load(model)
        #expect(model.messages.count == 2)
        let sender = try #require(model.messages.first?.senderId)
        model.activateSearch()
        model.updateSearchQuery("Message")
        try await Self.wait { model.searchState?.results.count == 2 }
        try await database.write { db in
            try db.execute(sql: "INSERT INTO ignoredUser VALUES (?)", arguments: [sender])
        }
        NotificationCenter.default.post(name: IgnoredContentStore.didChange, object: database)
        try await Self.wait { model.messages.isEmpty && model.searchState?.results.isEmpty == true }
        try await database.write { try $0.execute(sql: "DELETE FROM ignoredUser") }
        NotificationCenter.default.post(name: IgnoredContentStore.didChange, object: database)
        try await Self.wait { model.messages.count == 2 && model.searchState?.results.count == 2 }
    }

    @Test("Pinned previews respect blocking while a hidden chat retains its old message window")
    func hiddenPinnedPreview() async throws {
        let (database, _, model) = try fixture(count: 1)
        defer { model.cleanup() }
        try await load(model)
        let message = try #require(model.messages.first)
        let eventID = try #require(message.eventId)
        #expect(await model.pinnedPreview(eventId: eventID) == message.content.textPreview)
        model.setNavigationPresentationActive(false)
        var invalidations = 0
        model.onPinnedVisibilityChanged = { invalidations += 1 }
        try await database.write { db in
            try db.execute(sql: "INSERT INTO ignoredUser VALUES (?)", arguments: [message.senderId])
        }
        NotificationCenter.default.post(name: IgnoredContentStore.didChange, object: database)
        try await Self.wait { invalidations == 1 }
        #expect(model.messages.count == 1)
        #expect(await model.pinnedPreview(eventId: eventID) == String(localized: "Pinned message"))
        try await database.write { try $0.execute(sql: "DELETE FROM ignoredUser") }
        NotificationCenter.default.post(name: IgnoredContentStore.didChange, object: database)
        try await Self.wait { invalidations == 2 }
        #expect(await model.pinnedPreview(eventId: eventID) == message.content.textPreview)
    }

    private func load(_ model: ChatViewModel) async throws {
        var applied = false
        model.prepareHistoryReplacement(.newest) { apply in apply(); applied = true }
        try await Self.wait { applied }
    }

    @Test("A covered chat applies edits and deletions without retaining incoming history or animating on return")
    func coveredChatPreparation() async throws {
        let (database, _, model) = try fixture(count: 2)
        defer { model.cleanup() }
        try await load(model)
        let roomID = model.roomIdentifier
        model.onRedactedDetected = { _ in Issue.record("A hidden deletion should not animate") }
        model.setNavigationPresentationActive(false, prepareWhileHidden: true)
        try await database.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Edited while covered' WHERE id = 'row-1'")
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted' WHERE id = 'row-0'")
            for index in 2..<1002 {
                var message = TimelineWriteFixture.message(index)
                message.roomId = roomID
                try message.insert(db)
            }
        }
        model.refreshPresentationForTesting(.init(pushBackCount: 1000, setCount: 2, redactedUpsertCount: 1))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.content.textPreview == "Edited while covered")
        #expect(model.retainedHistoryMessageCount == 2)
        // Navigation freezes both screens during a pop. Catch-up must survive
        // that intermediate pause, even when the hidden queue already drained.
        model.setNavigationPresentationActive(false)
        model.setNavigationPresentationActive(true)
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(model.messages.count == 1001)
        #expect(!model.messages.contains { $0.id == "row-0" })
    }

    @Test("Covering the chat rejects an already prepared expanding live snapshot")
    func coverDuringPreparation() async throws {
        let (database, _, model) = try fixture(count: 2)
        defer { model.cleanup() }
        try await load(model)
        let roomID = model.roomIdentifier
        try await database.write { db in
            var message = TimelineWriteFixture.message(2)
            message.roomId = roomID
            try message.insert(db)
        }
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        model.refreshPresentationForTesting(.init(pushBackCount: 1))
        try await Self.wait { gate.entered.wrappedValue }
        model.setNavigationPresentationActive(false, prepareWhileHidden: true)
        gate.release()
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(model.retainedHistoryMessageCount == 2)
    }

    @Test("A covered refresh initializes an unread window with one bounded page")
    func coveredBeforeInitialLoad() async throws {
        let (_, window, model) = try fixture(count: 240)
        defer { model.cleanup() }
        #expect(window.generation == 0)
        model.setNavigationPresentationActive(false, prepareWhileHidden: true)
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(window.generation > 0)
        #expect(model.messages.count == MessageWindow.windowSize)
        #expect(model.messages.first?.id == "row-239")
        #expect(window.hasOlderInDB)
    }

    @Test("An initialized empty covered window does not admit incoming history until visible")
    func coveredEmptyWindow() async throws {
        let (database, _, model) = try fixture(count: 0)
        defer { model.cleanup() }
        try await load(model)
        model.setNavigationPresentationActive(false, prepareWhileHidden: true)
        let roomID = model.roomIdentifier
        try await database.write { db in
            var message = TimelineWriteFixture.message(0)
            message.roomId = roomID
            try message.insert(db)
        }
        model.refreshPresentationForTesting(.init(pushBackCount: 1))
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(model.messages.isEmpty)
        model.setNavigationPresentationActive(true)
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
        #expect(model.messages.map(\.id) == ["row-0"])
    }

    @Test("A jump to live does not wait for a stream of background refreshes to end")
    func jumpDuringRefreshStream() async throws {
        let (_, window, model) = try fixture(count: 600)
        defer { model.cleanup() }
        var loaded = false
        model.prepareHistoryReplacement(.oldest) { apply in apply(); loaded = true }
        try await Self.wait { loaded }
        #expect(!window.isAtLiveEdge)
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        var jumped = false
        var refreshesBeforeJump = 0
        model.onTableUpdate = { _, origin in
            guard case .timelineFlush = origin, !jumped else { return }
            refreshesBeforeJump += 1
            // Keep the stream finite so a starvation regression fails an
            // assertion rather than leaving background work running forever.
            if refreshesBeforeJump < 8 {
                model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
            }
        }
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await Self.wait { gate.entered.wrappedValue }
        model.prepareHistoryReplacement(.live) { apply in apply(); jumped = true }
        gate.release()
        try await Self.wait { jumped }
        #expect(refreshesBeforeJump <= 1)
        #expect(window.isAtLiveEdge)
        #expect(model.messages.first?.id == "row-599")
        try await Self.wait { model.isTimelineRefreshIdleForTesting }
    }

    @Test("Retention rejects a moved viewport, a hidden screen and an intervening mutation", arguments: [0, 1, 2])
    func retentionRaces(scenario: Int) async throws {
        let (_, _, model) = try fixture(count: 240)
        defer { model.cleanup() }
        try await load(model)
        #expect(await page(model) == .applied)
        let policy = ChatHistoryRetentionPolicy(maximumCount: 220, retainedCount: 100)
        let protected = Set(model.rows.filter { $0.message?.id == "row-20" }.map(\.listIdentifier))
        let far = Set(model.rows.filter { $0.message?.id == "row-239" }.map(\.listIdentifier))
        let gate = Gate()
        defer { gate.release() }
        model.onRenderPreparedForTesting = { gate.holdOnce() }
        var current: Set<String>? = protected
        var result: ChatHistoryPageLoader.Result?
        model.retainHistoryWindow(policy: policy, protectedRowIDs: protected,
            currentProtectedRowIDs: { current }) { result = $0 }
        try await Self.wait { gate.entered.wrappedValue }
        switch scenario {
        case 0: current = far
        case 1: model.setNavigationPresentationActive(false)
        default: model.hideMessage("row-10")
        }
        gate.release()
        try await Self.wait { result != nil }
        #expect(result == .superseded)
        #expect(model.retainedHistoryMessageCount == 240)
    }

    @Test("Retention commits a bounded presentation and remains ordinary history browsing")
    func retentionPresentation() async throws {
        let (database, window, model) = try fixture(count: 240)
        defer { model.cleanup() }
        try await load(model)
        #expect(await page(model) == .applied)
        let protected = Set(model.rows.filter { $0.message?.id == "row-20" }.map(\.listIdentifier))
        let generation = window.generation
        var origin: MessageWindowChangeOrigin?
        model.onTableUpdate = { _, value in origin = value }
        model.onRedactedDetected = { _ in Issue.record("Retention must not animate a deletion") }
        let result = await withCheckedContinuation { continuation in
            model.retainHistoryWindow(policy: .init(maximumCount: 220, retainedCount: 100),
                protectedRowIDs: protected, currentProtectedRowIDs: { protected }) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result == .applied)
        #expect(model.messages.count == 100)
        #expect(model.retainedHistoryMessageCount == 100)
        #expect(protected.isSubset(of: Set(model.rows.map(\.listIdentifier))))
        #expect(origin == .databasePagination)
        #expect(window.generation == generation)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 240)
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
                CREATE TABLE ignoredUser (userId TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE pendingDirectImage (envelopeId TEXT);
                CREATE TABLE pendingDirectVideo (envelopeId TEXT);
                CREATE TABLE pendingDirectFile (envelopeId TEXT);
                CREATE INDEX outboxRoom ON pendingMediaGroup(roomId, createdAt);
                CREATE UNIQUE INDEX outboxItem ON pendingMediaGroupItem(groupId, itemIndex);
                CREATE INDEX messageEvent ON storedMessage(roomId, eventId) WHERE eventId IS NOT NULL;
                CREATE INDEX messageTransaction ON storedMessage(transactionId) WHERE transactionId IS NOT NULL;
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
