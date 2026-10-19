//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Controlled database handoff diagnostic", .serialized)
struct DatabaseHandoffProbeTests {
    @Test("A real catalog page survives teardown and is intercepted before accessing its closed connection",
          arguments: [false, true], [false, true])
    @MainActor
    func retainedPage(sameAccount: Bool, cancelTask: Bool) async throws {
        let probe = DatabaseHandoffProbe.shared
        defer { probe.cancel() }
        let service = makeService()
        try await service.activate(userId: "@alice:example.org")
        let old = service.dbQueue
        #expect(probe.arm(database: old, accountID: "@alice:example.org"))
        let catalog = RoomPollCatalog(roomId: "!room:example.org", database: old, onRoomChange: { _ in })
        let page = Task { try await catalog.page(limit: 1) }
        defer { page.cancel() }
        try await waitFor(.held)

        // No worker or SQLite transaction is held. Main can continue, the
        // same queue is usable, and other pages are not captured by the probe.
        #expect(try await old.read { try Int.fetchOne($0, sql: "SELECT 1") } == 1)
        #expect(try await catalog.page(limit: 1).isEmpty)
        #expect(!probe.arm(database: old, accountID: "@alice:example.org"))
        if cancelTask { page.cancel() }
        #expect(probe.snapshot.phase == .held)

        try await service.resetToNoSession {
            #expect(!Thread.isMainThread)
        }
        #expect(probe.snapshot.phase == .waitingForSignIn)
        #expect(probe.snapshot.result == nil)
        #expect(try await service.dbQueue.read { try Int.fetchOne($0, sql: "SELECT 1") } == 1)

        try await service.activate(userId: sameAccount ? "@alice:example.org" : "@bob:example.org")
        do {
            _ = try await page.value
            Issue.record("The selected old page must never reach SQL")
        } catch DatabaseHandoffProbe.ProbeError.interceptedStaleRead { }

        let snapshot = probe.snapshot
        let result = try #require(snapshot.result)
        #expect(snapshot.phase == .finished)
        #expect(result.oldConnectionClosed)
        #expect(result.newConnectionDistinct)
        #expect(result.sameAccount == sameAccount)
        #expect(result.taskCancelled == cancelTask)
        #expect(snapshot.report.contains("sqlAttempted=false"))
        #expect(!snapshot.report.contains("@alice"))
        #expect(!snapshot.report.contains("@bob"))
        #expect(service.dbQueue !== old)
        #expect(try await service.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM roomPoll") } == 0)
        #expect(try await RoomPollCatalog(roomId: "!room:example.org", database: service.dbQueue,
                                         onRoomChange: { _ in }).page(limit: 1).isEmpty)
    }

    @Test("Cancel Test releases a held page without resuming SQL", arguments: [false, true])
    func cancelHeldPage(afterClose: Bool) async throws {
        let probe = DatabaseHandoffProbe.shared
        defer { probe.cancel() }
        let service = makeService()
        try await service.activate(userId: "alice")
        let database = service.dbQueue
        #expect(probe.arm(database: database, accountID: "alice"))
        let page = Task {
            try await RoomPollCatalog(roomId: "room", database: database, onRoomChange: { _ in }).page(limit: 1)
        }
        defer { page.cancel() }
        try await waitFor(.held)
        if afterClose { try await service.resetToNoSession(removingLocalData: {}) }
        probe.cancel()
        probe.cancel() // Idempotent; the continuation is resumed once.
        do {
            _ = try await page.value
            Issue.record("Expected diagnostic cancellation")
        } catch is CancellationError { }
        #expect(probe.snapshot.phase == .finished)
        #expect(probe.snapshot.result == nil)
        #expect(probe.snapshot.report.contains("handoff-cancelled"))
        try await service.activate(userId: "bob")
        #expect(probe.snapshot.result == nil)
    }

    @Test("Closing without opening Polls reports not captured and does not affect the next account")
    func closeBeforeCapture() async throws {
        let probe = DatabaseHandoffProbe.shared
        defer { probe.cancel() }
        let service = makeService()
        try await service.activate(userId: "alice")
        #expect(probe.arm(database: service.dbQueue, accountID: "alice"))
        try await service.resetToNoSession(removingLocalData: {})
        #expect(probe.snapshot.phase == .finished)
        #expect(probe.snapshot.report.contains("handoff-not-captured"))
        try await service.activate(userId: "bob")
        #expect(try await RoomPollCatalog(roomId: "room", database: service.dbQueue,
                                         onRoomChange: { _ in }).page(limit: 1).isEmpty)
        #expect(probe.snapshot.result == nil)
        #expect(probe.arm(database: service.dbQueue, accountID: "bob"))
    }

    @Test("A different queue cannot capture or release the armed operation")
    func queueIdentity() async throws {
        let probe = DatabaseHandoffProbe.shared
        defer { probe.cancel() }
        let owner = makeService()
        let other = makeService()
        try await owner.activate(userId: "alice")
        try await other.activate(userId: "alice")
        #expect(owner.dbQueue.path == other.dbQueue.path) // Both in-memory.
        #expect(probe.arm(database: owner.dbQueue, accountID: "alice"))
        #expect(try await RoomPollCatalog(roomId: "room", database: other.dbQueue,
                                         onRoomChange: { _ in }).page(limit: 1).isEmpty)
        try await other.activate(userId: "bob")
        #expect(probe.snapshot.phase == .armed)
        #expect(probe.snapshot.result == nil)
    }

    private func makeService() -> DatabaseService {
        DatabaseService(openAccount: { _ in
            let database = try DatabaseQueue()
            try DatabaseService.migrator.migrate(database)
            return database
        }, prepareLocalFiles: {})
    }

    private func waitFor(_ phase: DatabaseHandoffProbe.Phase) async throws {
        for _ in 0..<500 {
            if DatabaseHandoffProbe.shared.snapshot.phase == phase { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Timeout()
    }

    private struct Timeout: Error {}
}
#endif
