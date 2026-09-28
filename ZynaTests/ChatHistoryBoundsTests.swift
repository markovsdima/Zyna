//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Bounds-only history cleanup", .serialized)
@MainActor
struct ChatHistoryBoundsTests {
    @Test("Removing the last unadmitted neighbor updates paging without reading or publishing messages",
          arguments: [false, true])
    func removedNeighbor(newer: Bool) async throws {
        let hiddenIndex = newer ? 200 : 0
        let records = (0...200).map { index in
            var row = TimelineWriteFixture.message(index)
            if index == hiddenIndex { row.contentType = "unableToDecrypt"; row.contentBody = "unavailable" }
            return row
        }
        let database = try TimelineWriteFixture.database(legacyMessages: records)
        let window = MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database)
        if newer { window.jumpToOldest() } else { window.loadInitial() }
        let before = window.currentStoredMessages()
        #expect(before.count == 200)
        #expect(newer ? window.hasNewerInDB : window.hasOlderInDB)
        window.onChange = { _, _, _ in Issue.record("Bounds cleanup published a message snapshot") }
        _ = try await database.write { try StoredMessage.deleteOne($0, key: "row-\(hiddenIndex)") }
        let sql = Atomic<[String]>([])
        try await database.write { db in db.trace { event in
            #expect(!Thread.isMainThread)
            sql.modify { $0.append(event.description) }
        } }
        let request = window.refreshRequest()
        #expect(request.canRefreshBoundsOnly)
        let page = try await Task.detached { try request.fetchBounds() }.value
        #expect(window.applyBounds(page))
        #expect(!(newer ? window.hasNewerInDB : window.hasOlderInDB))
        #expect(window.currentStoredMessages() == before)
        let selects = sql.wrappedValue.filter { $0.uppercased().hasPrefix("SELECT") }
        #expect(!selects.isEmpty && selects.count <= 2)
        #expect(selects.allSatisfy { $0.contains("SELECT \"id\"") && $0.contains("LIMIT 1") })
        try await database.write { $0.trace(nil) }
    }

    @Test("An old bounds result cannot change a jumped window or a retired account", arguments: [false, true])
    func staleBounds(retire: Bool) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<250).map(TimelineWriteFixture.message))
        let window = MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database)
        #expect(!window.refreshRequest().canRefreshBoundsOnly)
        window.loadInitial()
        let request = window.refreshRequest()
        let page = try await Task.detached { try request.fetchBounds() }.value
        if retire { try await Task.detached { try database.close() }.value }
        else { window.jumpToOldest() }
        #expect(!window.applyBounds(page))
    }

    @Test("Cleanup avoids render preparation; a live update during its read falls back to a full snapshot",
          arguments: [false, true])
    func modelPipeline(liveDuringRead: Bool) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: [TimelineWriteFixture.message(0)])
        let window = MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: TimelineWriteFixture.roomID, dbQueue: database, window: window)
        defer { model.cleanup() }
        window.loadInitial()
        try await model.waitForPresentation()
        let initial = model.messages.map(\.id)
        let preparations = Atomic(0)
        model.onRenderPreparedForTesting = { preparations.modify { $0 += 1 } }
        model.onRedactedDetected = { _ in Issue.record("Cleanup merged with a live redaction animated") }
        if liveDuringRead {
            try await database.write { try $0.execute(sql: "UPDATE storedMessage SET contentType = 'redacted'") }
        }
        let entered = Atomic(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        try await database.write { db in db.trace { event in
            if event.description.contains("SELECT \"id\""), entered.tryToSetFlag() {
                #expect(!Thread.isMainThread)
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
        } }
        model.refreshPresentationForTesting(.init(includesUnreportedHistory: true, onlyUnadmittedChanges: true))
        try await ChatBackgroundPresentationTests.wait { entered.wrappedValue }
        if liveDuringRead { model.refreshPresentationForTesting(.init(setCount: 1, redactedUpsertCount: 1)) }
        release.signal()
        try await ChatBackgroundPresentationTests.wait { model.isTimelineRefreshIdleForTesting }
        try await database.write { $0.trace(nil) }
        if liveDuringRead {
            #expect(model.messages.isEmpty)
            #expect(preparations.wrappedValue > 0)
        } else {
            #expect(model.messages.map(\.id) == initial)
            #expect(preparations.wrappedValue == 0)
        }
    }
}
