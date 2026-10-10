//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import GRDB
import Testing
@testable import Zyna

enum RoomPollFixture {
    static let roomID = "!poll-list:example.org"
    static let userID = "@alice:example.org"

    static func database(path: String? = nil) throws -> AccountDatabase {
        let queue = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ignoredUser (userId TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE storedMessage (id TEXT PRIMARY KEY, roomId TEXT NOT NULL, eventId TEXT, contentType TEXT,
                    contentBody TEXT, isEdited BOOLEAN DEFAULT 0, latestEditEventId TEXT);
                CREATE TABLE pendingMediaGroup (
                    id TEXT PRIMARY KEY, roomId TEXT, kind TEXT, state TEXT);
                CREATE TABLE pendingMediaGroupItem (
                    id TEXT PRIMARY KEY, groupId TEXT REFERENCES pendingMediaGroup(id) ON DELETE CASCADE,
                    eventId TEXT, transportState TEXT);
                """)
            try PollStore.migrate(db)
        }
        return AccountDatabase(queue)
    }

    static func poll(_ id: String, time: Double = 100, ended: Bool = false) -> RoomPollHistoryRow {
        var poll = PollSnapshot.empty(PollDefinition(question: id, answers: [
            .init(id: "a", text: "A"), .init(id: "b", text: "B")], maxSelections: 1, kind: .disclosed))
        if ended { poll.endTimestamp = 200 }
        let message = ChatMessage(id: id, eventId: id, transactionId: nil, itemIdentifier: .eventId(id),
            senderId: userID, senderDisplayName: "Alice", senderAvatarUrl: nil, isOutgoing: true,
            timestamp: Date(timeIntervalSince1970: time), content: .poll(poll), reactions: [], replyInfo: nil,
            isEditable: true, isEdited: false, isEditPending: false, isEditFailed: false,
            latestEditEventId: nil, zynaAttributes: ZynaMessageAttributes(), sendStatus: "synced")
        return RoomPollHistoryRow(record: StoredMessage(from: message, roomId: roomID), isPollStart: true)
    }
}

@MainActor
private final class FakePollHistory: RoomPollHistorySource {
    var onChange: ((RoomPollHistoryState) -> Void)?
    let store: RoomPollHistoryStore
    var pages: [[RoomPollHistoryDiff]] = []
    var infinite = false
    var failNext = false
    var startGate: CheckedContinuation<Void, Never>?
    var holdStart = false
    var afterSynchronize: (() -> Void)?
    private(set) var starts = 0
    private(set) var calls = 0
    private(set) var stopped = false

    init(catalog: RoomPollCatalog) {
        store = RoomPollHistoryStore(catalog: catalog, userID: RoomPollFixture.userID)
        store.onChange = { [weak self] state in self?.onChange?(state) }
    }

    func start() async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startGate = $0 } }
    }
    func loadMore() async throws -> Bool {
        calls += 1
        try await Task.sleep(for: .milliseconds(10))
        if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
        if !pages.isEmpty { store.apply(pages.removeFirst()); return false }
        if infinite { store.apply([.pushFront(RoomPollHistoryRow())]); return false }
        return true
    }
    func synchronize() async throws {
        try await store.synchronize()
        afterSynchronize?()
    }
    func retryDecryption() {}
    func stop() { stopped = true; store.stop() }
}

@Suite("Poll attachments catalog and history")
@MainActor
struct RoomPollsTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test("Hidden polls suspend catalog observation and catch up without restarting SDK history")
    func hiddenObservation() async throws {
        let database = try RoomPollFixture.database()
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database)
        let source = FakePollHistory(catalog: catalog)
        source.pages = [[.append([RoomPollFixture.poll("$poll")])]]
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        defer { model.stop() }
        model.activate()
        try await wait { model.items.count == 1 && model.state == .exhausted }
        model.activate()
        try await database.write { try $0.execute(sql: "UPDATE roomPoll SET senderName = 'Profile'") }
        try await wait { model.items.first?.senderName == "Profile" }
        model.deactivate()
        try await database.write { try $0.execute(sql: "UPDATE roomPoll SET senderName = 'Hidden'") }
        #expect(model.items.first?.senderName == "Profile")
        model.activate()
        try await wait { model.items.first?.senderName == "Hidden" }
        #expect(source.starts == 1)
    }

    @Test("Retry after a real database observation error restarts live catalog updates")
    func observationRecovery() async throws {
        let database = try RoomPollFixture.database()
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database)
        let source = FakePollHistory(catalog: catalog)
        source.pages = [[.append([RoomPollFixture.poll("$poll")])]]
        try await database.write { try $0.execute(sql: "ALTER TABLE ignoredUser RENAME COLUMN userId TO unavailable") }
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        defer { model.stop() }
        model.activate()
        try await wait { if case .failed = model.state { return true }; return false }
        try await database.write { try $0.execute(sql: "ALTER TABLE ignoredUser RENAME COLUMN unavailable TO userId") }
        model.loadMore()
        try await wait { model.items.count == 1 && model.state == .exhausted }
        try await database.write { try $0.execute(sql: "UPDATE roomPoll SET senderName = 'After retry'") }
        try await wait { model.items.first?.senderName == "After retry" }
    }

    @Test("Leaving Polls or changing accounts cannot open a late navigation result", arguments: [0, 1, 2])
    func cancelledNavigation(action: Int) async throws {
        let database = try RoomPollFixture.database()
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database)
        var current = true
        let model = RoomPollsViewModel(catalog: catalog, source: FakePollHistory(catalog: catalog),
                                      settleQuiet: 0, isCurrentSession: { current })
        defer { model.stop() }
        model.activate()
        var gate: CheckedContinuation<PreparedPollNavigation, Never>?
        model.openPoll("$poll", prepare: { _ in await withCheckedContinuation { gate = $0 } })
        try await wait { gate != nil }
        #expect(model.openingEventId == "$poll")
        if action == 0 { model.cancelOpening() }
        if action == 1 { model.deactivate() }
        if action == 2 { current = false }
        gate?.resume(returning: PreparedPollNavigation { Issue.record("Late navigation committed"); return true })
        try await wait { model.openingEventId == nil }
        #expect(model.failedOpeningEventId == nil)
    }

    @Test("Failed poll navigation stays retryable; only a prepared result commits")
    func retryNavigation() async throws {
        let database = try RoomPollFixture.database()
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database)
        let model = RoomPollsViewModel(catalog: catalog, source: FakePollHistory(catalog: catalog), settleQuiet: 0)
        defer { model.stop() }
        model.activate()
        model.openPoll("$poll", prepare: { _ in throw PollNavigationError.loadingFailed })
        try await wait { model.failedOpeningEventId == "$poll" }
        #expect(model.openingEventId == nil)
        var opened = false
        model.openPoll("$poll", prepare: { _ in PreparedPollNavigation { opened = true; return true } })
        try await wait { opened }
        #expect(model.openingEventId == nil)
        #expect(model.failedOpeningEventId == nil)
    }

    @Test("Discovery survives window trims and updates existing bubbles without inserting partial chat rows")
    func durableDiscovery() async throws {
        let database = try RoomPollFixture.database()
        var notifications: [String] = []
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database,
                                      onRoomChange: { notifications.append($0) })
        let store = RoomPollHistoryStore(catalog: catalog, userID: RoomPollFixture.userID)
        store.apply([.append([RoomPollFixture.poll("$one"), RoomPollFixture.poll("$two")])])
        store.apply([.remove(1), .clear, .reset([])])
        #expect(try await catalog.page(limit: 10).map(\.eventId) == ["$two", "$one"])
        #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM storedMessage") } == 0)
        #expect(notifications.isEmpty)
        try await database.write { db in
            try db.execute(sql: "INSERT INTO storedMessage (id, roomId, eventId, contentType) VALUES ('chat-id', ?, '$one', 'poll')",
                           arguments: [RoomPollFixture.roomID])
        }
        store.apply([.reset([RoomPollFixture.poll("$one", ended: true)])])
        #expect(notifications == [RoomPollFixture.roomID])
        store.apply([.reset([RoomPollFixture.poll("$one", ended: true)])])
        #expect(notifications.count == 1)
        let json = try await database.read { try String.fetchOne($0, sql: "SELECT contentPollJSON FROM storedMessage WHERE id = 'chat-id'") }
        #expect(PollCoding.decode(PollSnapshot.self, from: json)?.hasEnded == true)
        var deleted = RoomPollFixture.poll("$one")
        deleted.record?.contentType = "redacted"
        store.apply([.set(0, deleted), .reset([RoomPollFixture.poll("$one")])])
        #expect(try await catalog.page(limit: 10).map(\.eventId) == ["$two"])
        #expect(try await database.read { try String.fetchOne($0, sql: "SELECT contentType FROM storedMessage WHERE id = 'chat-id'") } == "redacted")
        #expect(notifications.count == 2)
        store.stop()
    }

    @Test("Active and ended polls reappear from a reopened database before the SDK starts")
    func cacheSurvivesDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("poll-cache.sqlite").path
        let database = try await Task.detached { try RoomPollFixture.database(path: path) }.value
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database)
        let source = FakePollHistory(catalog: catalog)
        source.pages = [[.append([RoomPollFixture.poll("$active", time: 200),
                                  RoomPollFixture.poll("$ended", ended: true)])]]
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        model.activate()
        try await wait { model.state == .exhausted && model.items.count == 2 }
        let saved = model.items
        model.stop()
        try await Task.detached { try database.close() }.value

        let reopened = try await Task.detached { AccountDatabase(try DatabaseQueue(path: path)) }.value
        let restoredCatalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: reopened)
        let delayedSource = FakePollHistory(catalog: restoredCatalog)
        delayedSource.holdStart = true
        let restored = RoomPollsViewModel(catalog: restoredCatalog, source: delayedSource, settleQuiet: 0)
        defer {
            restored.stop()
            delayedSource.startGate?.resume()
            delayedSource.startGate = nil
        }
        restored.activate()
        try await wait { delayedSource.startGate != nil }
        #expect(restored.items == saved)
        #expect(restored.items.map(\.snapshot.hasEnded) == [false, true])
        #expect(restored.state == .loading)
        #expect(delayedSource.calls == 0)
    }

    @Test("Unavailable profiles preserve names while loaded profiles can rename or remove them")
    func senderProfiles() async throws {
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: try RoomPollFixture.database())
        let store = RoomPollHistoryStore(catalog: catalog, userID: RoomPollFixture.userID)
        store.apply([.append([RoomPollFixture.poll("$poll")])])
        var row = RoomPollFixture.poll("$poll")
        row.record?.senderDisplayName = nil
        store.apply([.set(0, row)])
        #expect(try await catalog.page(limit: 1).first?.senderName == "Alice")
        row.senderProfile = .ready(name: "Alicia")
        store.apply([.set(0, row)])
        #expect(try await catalog.page(limit: 1).first?.senderName == "Alicia")
        row.senderProfile = .ready(name: nil)
        store.apply([.set(0, row)])
        #expect(try await catalog.page(limit: 1).first?.senderName == nil)
        store.stop()
    }

    @Test("Catalog commits refresh the open chat without an SDK timeline notification")
    func refreshesOpenChat() async throws {
        let roomId = "!catalog-chat-\(UUID().uuidString):example.org"
        var updates: [PollStore.RoomUpdate] = []
        let subscription = PollStore.shared.roomDidUpdate
            .filter { $0.roomId == roomId }
            .receive(on: DispatchQueue.main)
            .sink { updates.append($0) }
        defer { subscription.cancel() }
        let database = try RoomPollFixture.database()
        var row = RoomPollFixture.poll("$poll")
        row.record?.roomId = roomId
        let original = try #require(row.record)
        let columns = Mirror(reflecting: original).children.compactMap(\.label)
        try await database.write { db in
            let definitions = columns.map { column in
                switch column {
                case "id": return "\"id\" TEXT PRIMARY KEY"
                case "timestamp": return "\"timestamp\" REAL"
                default: return "\"\(column)\""
                }
            }
            try db.execute(sql: "DROP TABLE storedMessage")
            try db.execute(sql: "CREATE TABLE storedMessage (\(definitions.joined(separator: ",")))")
            var record = original
            try PollStore.ingest(&record, in: db)
            try record.insert(db)
        }
        let window = MessageWindow(roomId: roomId, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomId, dbQueue: database, window: window)
        defer { model.cleanup() }
        window.loadInitial()
        try await model.waitForPresentation()
        #expect(model.messages.map(\.id) == [original.id])
        let store = RoomPollHistoryStore(catalog: RoomPollCatalog(roomId: roomId, database: database),
                                         userID: RoomPollFixture.userID)
        row = RoomPollFixture.poll("$poll", ended: true)
        row.record?.roomId = roomId
        store.apply([.append([row])])
        try await wait {
            if case .poll(let snapshot) = model.messages.first?.content { return snapshot.hasEnded }
            return false
        }
        row.record?.contentType = "redacted"
        store.apply([.set(0, row)])
        try await wait { model.messages.isEmpty && model.rows.isEmpty && updates.count == 2 }
        #expect(updates == Array(repeating: .init(roomId: roomId, origin: .catalog), count: 2))
        store.stop()
    }

    @Test("Reconciled outgoing actions notify even when the poll has no cached chat row")
    func outgoingChangeNotifies() async throws {
        let database = try RoomPollFixture.database()
        var notifications = 0
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database,
                                      onRoomChange: { _ in notifications += 1 })
        let store = RoomPollHistoryStore(catalog: catalog, userID: RoomPollFixture.userID)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO pendingPollOperation (id, sequence, roomId, pollStartEventId, sessionId,
                    kind, transactionId, state) VALUES ('operation', 1, ?, '$poll', 'session', 'end', 'txn', 'accepted')
                """, arguments: [RoomPollFixture.roomID])
        }
        store.apply([.append([RoomPollFixture.poll("$poll", ended: true)])])
        #expect(notifications == 1)
        #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pendingPollOperation") } == 0)
        store.stop()
    }

    @Test("A rolled-back catalog event cannot notify the chat")
    func rollbackDoesNotNotify() async throws {
        let database = try RoomPollFixture.database()
        var notifications = 0
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database,
                                      onRoomChange: { _ in notifications += 1 })
        let store = RoomPollHistoryStore(catalog: catalog, userID: RoomPollFixture.userID)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO storedMessage (id, roomId, eventId, contentType) VALUES ('chat-id', ?, '$one', 'poll');
                CREATE TRIGGER reject_poll BEFORE UPDATE OF contentPollJSON ON storedMessage WHEN NEW.eventId = '$one'
                BEGIN SELECT RAISE(ABORT, 'test write failure'); END;
                """, arguments: [RoomPollFixture.roomID])
        }
        store.apply([.append([RoomPollFixture.poll("$one")])])
        #expect(notifications == 0)
        #expect(try await catalog.page(limit: 10).isEmpty)
        try await database.write { try $0.execute(sql: "DROP TRIGGER reject_poll") }
        try await store.synchronize()
        #expect(notifications == 1)
        #expect(try await catalog.page(limit: 10).count == 1)
        store.stop()
    }

    @Test("A write failure arriving after synchronization survives fill completion and catalog observations")
    func lateWriteFailure() async throws {
        let database = try RoomPollFixture.database()
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database)
        let source = FakePollHistory(catalog: catalog)
        source.pages = [[.append([RoomPollFixture.poll("$poll")])]]
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_poll BEFORE UPDATE ON roomPoll WHEN NEW.snapshotJSON != OLD.snapshotJSON
                BEGIN SELECT RAISE(ABORT, 'test write failure'); END;
                """)
        }
        source.afterSynchronize = {
            source.afterSynchronize = nil
            source.store.apply([.set(0, RoomPollFixture.poll("$poll", ended: true))])
        }
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        model.activate()
        try await wait { if case .failed = model.state { return true }; return false }
        #expect(model.items.first?.snapshot.hasEnded == false)
        try await database.write { try $0.execute(sql: "UPDATE roomPoll SET senderName = 'Alicia'") }
        try await wait { model.items.first?.senderName == "Alicia" }
        if case .failed = model.state {} else { Issue.record("Observation erased a pending write error") }
        try await database.write { try $0.execute(sql: "DROP TRIGGER reject_poll") }
        try await source.synchronize()
        try await wait { model.items.first?.snapshot.hasEnded == true && model.state == .exhausted }
        model.stop()
    }

    @Test("Returning to Polls at a retained bottom loads its next cached page")
    func retainedPollBottom() async throws {
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: try RoomPollFixture.database())
        let source = FakePollHistory(catalog: catalog)
        source.store.apply([.append((0..<5).map { RoomPollFixture.poll("$\($0)", time: Double($0)) })])
        let model = RoomPollsViewModel(catalog: catalog, source: source, pageSize: 2, settleQuiet: 0)
        model.activate()
        try await wait { model.state == .more && model.items.count == 2 }
        model.deactivate()
        model.reachedBottom()
        #expect(model.items.count == 2)
        model.activate()
        try await wait { model.state == .more && model.items.count == 4 }
        model.leftBottom()
        model.deactivate()
        model.activate()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.items.count == 4)
        model.stop()
    }

    @Test("Opening the tab discovers history without a chat timeline and observes edits and deletion")
    func discoverAndObserve() async throws {
        let database = try RoomPollFixture.database()
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database)
        let source = FakePollHistory(catalog: catalog)
        source.pages = [[.append([RoomPollFixture.poll("$poll")])]]
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        #expect(source.starts == 0)
        model.activate()
        try await wait { model.state == .exhausted }
        #expect(model.items.map(\.eventId) == ["$poll"])
        #expect(source.calls == 3)
        source.store.apply([.set(0, RoomPollFixture.poll("$poll", ended: true))])
        try await wait { model.items.first?.snapshot.hasEnded == true }
        var deleted = RoomPollFixture.poll("$poll")
        deleted.record?.contentType = "redacted"
        source.store.apply([.set(0, deleted)])
        try await wait { model.items.isEmpty }
        model.stop()
    }

    @Test("Late decryption replaces a pending row, while positional eviction keeps discovered polls")
    func lateDecryption() async throws {
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: try RoomPollFixture.database())
        let source = FakePollHistory(catalog: catalog)
        let pending = PendingDecryption(uniqueId: "utd", eventId: "$poll", sessionId: "session",
                                        timestampMs: 100_000, cause: "missing-key")
        source.pages = [[.append([RoomPollHistoryRow(pending: pending)])]]
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        model.activate()
        try await wait { model.state == .exhausted && model.pendingDecryptionCount == 1 }
        #expect(model.items.isEmpty)
        source.store.apply([.set(0, RoomPollFixture.poll("$poll"))])
        try await wait { model.items.count == 1 && model.pendingDecryptionCount == 0 }
        source.store.apply([.popFront, .reset([])])
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.items.map(\.eventId) == ["$poll"])
        model.stop()
    }

    @Test("Sparse history respects a budget; snapshots and tab revisits cannot pump history")
    func boundedLoading() async throws {
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: try RoomPollFixture.database())
        let source = FakePollHistory(catalog: catalog)
        source.infinite = true
        let model = RoomPollsViewModel(catalog: catalog, source: source, fillBudget: 0.03, settleQuiet: 0)
        model.activate()
        try await wait { model.state == .more }
        let calls = source.calls
        source.store.apply([.pushBack(RoomPollFixture.poll("$late"))])
        model.deactivate()
        model.activate()
        model.reachedBottom()
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.calls == calls)
        #expect(source.starts == 1)
        #expect(model.items.map(\.eventId) == ["$late"])
        model.loadMore()
        try await wait { source.calls > calls && model.state == .more }
        model.stop()
    }

    @Test("A warm catalog pages beyond 100, preserves ordering, and remains available on network error")
    func cachedPagesAndRetry() async throws {
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: try RoomPollFixture.database())
        let source = FakePollHistory(catalog: catalog)
        source.store.apply([.append((0..<125).map { RoomPollFixture.poll("$\($0)", time: Double($0)) })])
        source.failNext = true
        let model = RoomPollsViewModel(catalog: catalog, source: source, pageSize: 50, settleQuiet: 0)
        model.activate()
        try await wait { if case .failed = model.state { return true }; return false }
        #expect(model.items.count == 50)
        model.loadMore()
        try await wait { model.state == .more }
        #expect(model.items.count == 50)
        model.loadMore()
        try await wait { model.state == .more && model.items.count == 100 }
        model.loadMore()
        try await wait { model.state == .exhausted }
        #expect(model.items.count == 125)
        #expect(model.items.first?.eventId == "$124")
        #expect(model.items.last?.eventId == "$0")
        model.stop()
    }

    @Test("Closing the screen or changing accounts during SDK startup prevents subsequent pagination",
          arguments: [true, false])
    func stopDuringStart(closeScreen: Bool) async throws {
        let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: try RoomPollFixture.database())
        let source = FakePollHistory(catalog: catalog)
        source.holdStart = true
        var currentSession = true
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0,
                                      isCurrentSession: { currentSession })
        model.activate()
        try await wait { source.startGate != nil }
        if closeScreen { model.stop() } else { currentSession = false }
        source.startGate?.resume()
        source.startGate = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.calls == 0)
        if closeScreen { #expect(source.stopped) }
        model.stop()
    }
}
