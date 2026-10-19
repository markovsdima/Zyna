//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Account database lifecycle")
struct DatabaseLifecycleTests {
    @Test("Opening releases main and simultaneous requests prepare an account once")
    @MainActor
    func concurrentStartup() async throws {
        let opened = Atomic<[String]>([])
        let prepared = Atomic(0)
        let mainProgressed = Atomic(false)
        let service = DatabaseService(openAccount: { userId in
            #expect(!Thread.isMainThread)
            let gate = DispatchSemaphore(value: 0)
            Task { @MainActor in
                mainProgressed.wrappedValue = true
                gate.signal()
            }
            guard gate.wait(timeout: .now() + 5) == .success else { throw ProbeError.timeout }
            opened.modify { $0.append(userId ?? "anonymous") }
            return try DatabaseQueue()
        }, prepareLocalFiles: {
            #expect(!Thread.isMainThread)
            prepared.modify { $0 += 1 }
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await service.activate(userId: "alice") } }
            try await group.waitForAll()
        }
        #expect(mainProgressed.wrappedValue)
        #expect(opened.wrappedValue == ["alice"])
        #expect(prepared.wrappedValue == 1)
        let database = service.dbQueue
        try await service.activate(userId: "alice")
        #expect(service.dbQueue === database)
    }

    @Test("Account replacement exposes a retired handle without blocking main", arguments: [false, true])
    @MainActor
    func accountSwitch(holdDuringCachePreparation: Bool) async throws {
        let began = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let service = DatabaseService(openAccount: { userId in
            if userId == "bob", !holdDuringCachePreparation {
                began.signal()
                guard gate.wait(timeout: .now() + 5) == .success else { throw ProbeError.timeout }
            }
            let database = try DatabaseQueue()
            try database.write { db in
                try db.execute(sql: "CREATE TABLE identity (name TEXT)")
                try db.execute(sql: "INSERT INTO identity VALUES (?)", arguments: [userId])
            }
            return database
        }, prepareLocalFiles: {})
        try await service.activate(userId: "alice")
        let alice = service.dbQueue
        let switching = Task {
            try await service.activate(userId: "bob") {
                #expect(!Thread.isMainThread)
                guard holdDuringCachePreparation else { return }
                began.signal()
                #expect(gate.wait(timeout: .now() + 5) == .success)
            }
        }
        let didBegin = await Self.waitForSignal(began)
        #expect(didBegin)
        // This getter runs on main while opening/preparation is held. Old
        // accesses fail, rather than waiting for or following the new account.
        #expect(service.dbQueue === alice)
        #expect(!alice.isActive)
        #expect(alice.isClosed)
        #expect(throws: AccountDatabase.AccessError.self) {
            try alice.read { _ in Issue.record("Retired access reached SQL") }
        }
        gate.signal()
        try await switching.value
        #expect(service.dbQueue !== alice)
        #expect(try await service.dbQueue.read { try String.fetchOne($0, sql: "SELECT name FROM identity") } == "bob")
    }

    @Test("Removal finishes before any queued activation opens its database")
    func removalSerializesWithActivation() async throws {
        let events = Atomic<[String]>([])
        let began = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let service = DatabaseService(openAccount: { userId in
            events.modify { $0.append("open:\(userId ?? "anonymous")") }
            return try DatabaseQueue()
        }, prepareLocalFiles: {})
        try await service.activate(userId: "alice")
        let alice = service.dbQueue
        let reset = Task {
            try await service.resetToNoSession {
                #expect(!Thread.isMainThread)
                #expect(alice.isClosed)
                events.modify { $0.append("remove-begin") }
                began.signal()
                guard gate.wait(timeout: .now() + 5) == .success else { throw ProbeError.timeout }
                events.modify { $0.append("remove-end") }
            }
        }
        let didBegin = await Self.waitForSignal(began)
        #expect(didBegin)
        let activation = Task {
            try await service.activate(userId: "bob") {
                events.modify { $0.append("prepare:bob") }
            }
        }
        gate.signal()
        try await reset.value
        try await activation.value
        #expect(events.wrappedValue == ["open:alice", "remove-begin", "remove-end", "open:anonymous", "open:bob", "prepare:bob"])
    }

    @Test("A failed account open publishes no partially prepared connection and can be retried")
    func failedOpen() async throws {
        let fail = Atomic(true)
        let service = DatabaseService(openAccount: { userId in
            if userId == "bob", fail.wrappedValue { throw ProbeError.injected }
            return try DatabaseQueue()
        }, prepareLocalFiles: {})
        try await service.activate(userId: "alice")
        let alice = service.dbQueue
        do {
            try await service.activate(userId: "bob")
            Issue.record("Expected an injected opening failure")
        } catch ProbeError.injected { }
        #expect(alice.isClosed)
        fail.wrappedValue = false
        try await service.activate(userId: "bob")
        #expect(service.dbQueue !== alice)
        #expect(try await service.dbQueue.read { try Int.fetchOne($0, sql: "SELECT 1") } == 1)
    }

    @Test("Fresh and upgraded encrypted databases preserve cache and outbox on subsequent starts", arguments: [false, true])
    func encryptedMigrations(upgrade: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("account.db").path
        let opened = Atomic(0)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            opened.modify { $0 += 1 }
            try db.usePassphrase(Data(repeating: 0x47, count: 32))
        }
        let config = configuration
        let database = try await Task.detached {
            let database = try DatabaseQueue(path: path, configuration: config)
            if upgrade {
                try DatabaseService.migrator.migrate(database, upTo: "v28_composerFormatting")
            } else {
                try DatabaseService.migrator.migrate(database)
            }
            return database
        }.value
        #expect(opened.wrappedValue == 1)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO storedMessage (id, roomId, eventId, senderId, isOutgoing, timestamp,
                    contentType, contentBody, reactionsJSON)
                VALUES ('cached', '!room:example.org', '$event', '@me:example.org', 1, 1, 'text', 'Keep me', '[]');
                INSERT INTO pendingMediaGroup (id, roomId, captionPlacement, expectedItemCount, createdAt, kind, state)
                VALUES ('queued', '!room:example.org', 'bottom', 1, 1, 'voice', 'queued');
                INSERT INTO pendingMediaGroupItem (id, groupId, itemIndex, transactionId, transportState)
                VALUES ('queued:0', 'queued', 0, 'stable-transaction', 'queued');
                """)
        }
        try await Task.detached { try DatabaseService.migrator.migrate(database) }.value
        let definition = PollDefinition(question: "Keep pending poll", answers: [
            .init(id: "a", text: "A"), .init(id: "b", text: "B")], maxSelections: 1, kind: .disclosed)
        let account = AccountDatabase(database)
        let operationID = try await PollStore(database: { account }).create(
            roomId: "!room:example.org", definition: definition, sessionId: "session")
        try await account.write { db in
            // Drift used to trigger automatic erasure of the whole account.
            try db.execute(sql: "CREATE TABLE retainedLocalExtension (value TEXT)")
        }
        try await Task.detached { try account.close() }.value
        let service = DatabaseService(openAccount: { _ in
            let reopened = try DatabaseQueue(path: path, configuration: config)
            try DatabaseService.migrator.migrate(reopened)
            return reopened
        }, prepareLocalFiles: {})
        try await service.activate(userId: "alice")
        #expect(opened.wrappedValue == 2) // No temporary schema-comparison DB.
        let reopened = service.dbQueue
        try await reopened.read { db throws -> Void in
            #expect(try String.fetchOne(db, sql: "PRAGMA cipher_version")?.isEmpty == false)
            #expect(try String.fetchOne(db, sql: "SELECT contentBody FROM storedMessage WHERE id = 'cached'") == "Keep me")
            #expect(try String.fetchOne(db, sql: "SELECT transactionId FROM pendingMediaGroupItem WHERE id = 'queued:0'") == "stable-transaction")
            #expect(try PendingPollOperation.fetchOne(db, key: operationID)?.state == "queued")
            #expect(try db.tableExists("retainedLocalExtension"))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") == 31)
        }
        try await Task.detached { try reopened.close() }.value
    }

    private static func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    private enum ProbeError: Error { case timeout, injected }
}
