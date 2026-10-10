//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Retired account database access")
struct AccountDatabaseTests {
    @Test("Delayed non-cancellable window reads and timeline writes cannot follow a new account",
          arguments: [false, true])
    @MainActor
    func delayedWork(sameAccount: Bool) async throws {
        let service = makeService()
        try await service.activate(userId: "alice")
        let old = service.dbQueue
        let room = TimelineWriteFixture.roomID
        let record = TimelineWriteFixture.message(0)
        try await old.write { try record.insert($0) }
        let window = MessageWindow(roomId: room, dbQueue: old)
        let request = window.refreshRequest()
        let gate = Gate()
        defer { gate.release() }
        let worker = Task.detached {
            try gate.hold()
            #expect(!Task.isCancelled)
            #expect(throws: AccountDatabase.AccessError.self) { try request.fetch() }
            #expect(throws: AccountDatabase.AccessError.self) {
                try TimelineDiffBatcher.writeMappedEvents([TimelineWriteFixture.event(record)],
                    roomId: room, database: old, currentUserId: "alice",
                    summary: .init(setCount: 1), historyRevision: TimelineHistoryRevision()) { _ in
                        Issue.record("Retired timeline published a flush")
                    }
            }
        }
        try await gate.waitUntilHeld()
        try await service.resetToNoSession(removingLocalData: {})
        try await service.activate(userId: sameAccount ? "alice" : "bob")
        gate.release()
        try await worker.value
        #expect(old.isClosed)
        #expect(service.dbQueue !== old)
        let sqlEntered = Atomic(false)
        do {
            try await old.read { _ in sqlEntered.wrappedValue = true }
            Issue.record("Retired asynchronous read succeeded")
        } catch AccountDatabase.AccessError.retired { }
        do {
            try await old.write { _ in sqlEntered.wrappedValue = true }
            Issue.record("Retired asynchronous write succeeded")
        } catch AccountDatabase.AccessError.retired { }
        #expect(!sqlEntered.wrappedValue)
        #expect(try await service.dbQueue.read { try StoredMessage.fetchCount($0) } == 0)
    }

    @Test("Closing waits for admitted reads and writes without blocking main or admitting new SQL",
          arguments: [false, true], [false, true])
    @MainActor
    func drainsAdmittedAccess(write: Bool, asynchronous: Bool) async throws {
        let service = makeService()
        try await service.activate(userId: "alice")
        let old = service.dbQueue
        let gate = Gate()
        defer { gate.release() }
        let worker = Task.detached {
            let work: @Sendable (Database) throws -> Int = { db in
                #expect(!Thread.isMainThread)
                try gate.hold()
                if write { try TimelineWriteFixture.message(0).insert(db) }
                return try StoredMessage.fetchCount(db)
            }
            if asynchronous {
                return try await (write ? old.write(work) : old.read(work))
            } else {
                return try Self.synchronousAccess(old, write: write, work: work)
            }
        }
        try await gate.waitUntilHeld()
        let cleaned = Atomic(false)
        let reset = Task {
            try await service.resetToNoSession {
                #expect(old.isClosed)
                cleaned.wrappedValue = true
            }
        }
        try await waitUntil { !old.isActive }
        // Accessing the service on main must not wait for this held SQL.
        #expect(service.dbQueue === old)
        #expect(!old.isClosed)
        #expect(!cleaned.wrappedValue)
        #expect(throws: AccountDatabase.AccessError.self) {
            try old.read { _ in Issue.record("New access entered while retiring") }
        }
        gate.release()
        #expect(try await worker.value == (write ? 1 : 0))
        try await reset.value
        #expect(cleaned.wrappedValue)
        #expect(old.isClosed)
        #expect(try await service.dbQueue.read { try StoredMessage.fetchCount($0) } == 0)
    }

    @Test("A running timeline flush commits its current chunk and abandons its suffix on retirement")
    func retiresBetweenChunks() async throws {
        let service = makeService()
        try await service.activate(userId: "alice")
        let old = service.dbQueue
        let gate = Gate()
        defer { gate.release() }
        try await old.write { db in
            db.add(function: DatabaseFunction("hold_insert", argumentCount: 0) { _ in
                try gate.hold()
                return 0
            })
            try db.execute(sql: """
                CREATE TRIGGER hold_first BEFORE INSERT ON storedMessage WHEN NEW.id = 'row-0'
                BEGIN SELECT hold_insert(); END;
                """)
        }
        let revision = TimelineHistoryRevision()
        let writer = Task.detached {
            var committed: [TimelineFlushSummary] = []
            #expect(throws: AccountDatabase.AccessError.self) {
                try TimelineDiffBatcher.writeMappedEvents(
                    (0..<3).map { TimelineWriteFixture.event(TimelineWriteFixture.message($0)) },
                    roomId: TimelineWriteFixture.roomID, database: old, currentUserId: "alice",
                    summary: .init(resetCount: 1), historyRevision: revision,
                    limits: .init(maximumCount: 1, maximumDuration: 60)) { committed.append($0) }
            }
            return committed
        }
        try await gate.waitUntilHeld()
        let switching = Task { try await service.activate(userId: "bob") }
        try await waitUntil { !old.isActive }
        gate.release()
        let committed = await writer.value
        try await switching.value
        #expect(committed.count == 1)
        #expect(committed.first?.upsertCount == 1)
        #expect(revision.current == 1)
        #expect(old.isClosed)
        #expect(try await service.dbQueue.read { try StoredMessage.fetchCount($0) } == 0)
    }

    @Test("Prepared pages cannot update a window after its account has retired")
    @MainActor
    func rejectsLatePublication() async throws {
        let service = makeService()
        try await service.activate(userId: "alice")
        let old = service.dbQueue
        try await old.write { db in
            for i in 0..<210 { try TimelineWriteFixture.message(i).insert(db) }
        }
        let window = MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: old)
        let initial = window.refreshRequest()
        let initialPage = try await Task.detached { try initial.fetch() }.value
        #expect(window.applyRefresh(initialPage, summary: .init()))
        let request = try #require(window.pageRequest(.older))
        let refresh = window.refreshRequest()
        let page = try await Task.detached { try request.fetch() }.value
        let refreshed = try await Task.detached { try refresh.fetch() }.value
        window.onChange = { _, _, _ in Issue.record("Retired window published a page") }
        try await service.activate(userId: "bob")
        #expect(!window.canApply(page))
        #expect(!window.applyPage(page))
        #expect(!window.canApply(refreshed))
        #expect(!window.applyRefresh(refreshed, summary: .init(requiresPresentationRefresh: true)))
        #expect(window.currentStoredMessages().count == 200)
    }

    @Test("Retirement cancels an observer whose initial fetch is already queued")
    func cancelsQueuedObservation() async throws {
        let service = makeService()
        try await service.activate(userId: "alice")
        let old = service.dbQueue
        let gate = Gate()
        defer { gate.release() }
        let writer = Task.detached { try await old.write { _ in try gate.hold() } }
        try await gate.waitUntilHeld()
        let delivery = DispatchQueue(label: "test.database.observation")
        let token = old.observe(ValueObservation.tracking { db in
            try StoredMessage.fetchCount(db)
        }, on: delivery, onError: { _ in Issue.record("Cancelled observer delivered an error") },
           onChange: { _ in Issue.record("Retired observer delivered data") })
        defer { token.cancel() }
        let switching = Task { try await service.activate(userId: "bob") }
        try await waitUntil { !old.isActive }
        gate.release()
        try await writer.value
        try await switching.value
        token.cancel() // Safe and idempotent after physical close.
        await withCheckedContinuation { continuation in delivery.async { continuation.resume() } }
        #expect(old.isClosed)

        let error = Atomic(false)
        let late = old.observe(ValueObservation.tracking { _ in
            Issue.record("Observer registered on a closed connection")
            return 0
        }, on: delivery, onError: { failure in
            #expect(failure is AccountDatabase.AccessError)
            error.wrappedValue = true
        }, onChange: { _ in Issue.record("Closed connection emitted a value") })
        defer { late.cancel() }
        await withCheckedContinuation { continuation in delivery.async { continuation.resume() } }
        #expect(error.wrappedValue)

        // Cancellation also suppresses an error queued by late registration.
        delivery.suspend()
        let cancelled = old.observe(ValueObservation.tracking { _ in 0 }, on: delivery,
            onError: { _ in Issue.record("Cancelled late observer delivered an error") },
            onChange: { _ in Issue.record("Cancelled late observer delivered data") })
        cancelled.cancel()
        delivery.resume()
        await withCheckedContinuation { continuation in delivery.async { continuation.resume() } }
    }

    private func makeService() -> DatabaseService {
        DatabaseService(openAccount: { _ in
            let queue = try DatabaseQueue()
            try DatabaseService.migrator.migrate(queue)
            return queue
        }, prepareLocalFiles: {})
    }

    private static func synchronousAccess(
        _ database: AccountDatabase, write: Bool, work: (Database) throws -> Int
    ) throws -> Int {
        try write ? database.write(work) : database.read(work)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct Timeout: Error { }

    private final class Gate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)

        func hold() throws {
            entered.signal()
            guard released.wait(timeout: .now() + 5) == .success else { throw Timeout() }
        }

        func release() { released.signal() }

        func waitUntilHeld() async throws {
            let success = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
                }
            }
            guard success else { throw Timeout() }
        }
    }
}
