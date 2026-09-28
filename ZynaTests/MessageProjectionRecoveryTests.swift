//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK
import Testing
@testable import Zyna

@Suite("SDK projection recovery")
struct MessageProjectionRecoveryTests {
    @Test("Persisted visible proofs retry after timeline loading without waiting for inspection backoff")
    @MainActor
    func lateTimeline() async throws {
        let database = try Self.database(count: 2)
        let available = Atomic(false)
        let retries = Atomic<[[String]]>([])
        let sdk = MessageProjectionRecovery.SDK(session: { _, _ in
            #expect(!Thread.isMainThread)
            return available.wrappedValue ? "same-session" : nil
        }, retry: { value in retries.modify { $0.append(value) } })
        var recovery = MessageProjectionRecovery()
        try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { 0 })
        #expect(retries.wrappedValue.isEmpty)
        available.wrappedValue = true
        try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { 5 })
        #expect(retries.wrappedValue == [["same-session"]])
        #expect(try await database.read {
            try MessageDecryptionRepairStore.candidates(in: $0, roomID: TimelineWriteFixture.roomID, now: 100).isEmpty
        })
        #expect(try await database.read {
            try StoredMessage.fetchAll($0).allSatisfy { $0.decryptionFailure != nil }
        })
        // Only ordinary aggregated SDK projections admit the messages and
        // clear the durable queue. A retry request alone never claims success.
        try await Task.detached {
            try TimelineDiffBatcher.writeMappedEvents((0..<2).map {
                TimelineWriteFixture.event(TimelineWriteFixture.message($0))
            }, roomId: TimelineWriteFixture.roomID, database: database, currentUserId: "",
                summary: .init(setCount: 2), historyRevision: TimelineHistoryRevision()) { _ in }
        }.value
        #expect(try await database.read { try ChatHistoryRecovery.Snapshot.fetch(in: $0, roomID: TimelineWriteFixture.roomID).isEmpty })
        try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { 30 })
        #expect(retries.wrappedValue.count == 1)
    }

    @Test("Room retries back off and repeated manual requests preserve a minimum interval")
    func pacing() async throws {
        let database = try Self.database(count: 1)
        let calls = Atomic(0)
        let sdk = MessageProjectionRecovery.SDK(session: { _, _ in "session" }, retry: { _ in calls.modify { $0 += 1 } })
        var recovery = MessageProjectionRecovery()
        for now in [0.0, 1, 5, 14] {
            try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { now })
        }
        #expect(calls.wrappedValue == 1)
        for now in [15.0, 20, 44] {
            try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { now })
        }
        #expect(calls.wrappedValue == 2)
        try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { 45 })
        #expect(calls.wrappedValue == 3)
        for now in [46.0, 50, 59] {
            recovery.retryManually()
            try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { now })
        }
        #expect(calls.wrappedValue == 3)
        try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { 60 })
        #expect(calls.wrappedValue == 4)
    }

    @Test("Bounded keyset pages cross equal timestamps and missing-key rows without starvation")
    func pages() async throws {
        let database = try Self.database(count: 40)
        try await database.write {
            try $0.execute(sql: "UPDATE messageDecryptionRepair SET priorityTimestamp = 1, lastOutcome = 'keys'")
            try $0.execute(sql: "UPDATE messageDecryptionRepair SET lastOutcome = 'projection' WHERE eventId = '$event-0'")
        }
        var cursor: MessageDecryptionRepairStore.ProjectionCursor?
        var ids = Set<String>()
        for expected in [16, 16, 8] {
            let after = cursor
            let page = try await database.read {
                try MessageDecryptionRepairStore.projectionPage(in: $0, roomID: TimelineWriteFixture.roomID, after: after)
            }
            #expect(page.count == expected)
            for row in page { #expect(ids.insert(row.eventID).inserted) }
            cursor = page.last?.cursor
        }
        #expect(ids.count == 40)
        let lookups = Atomic<[String]>([])
        let retries = Atomic(0)
        let sdk = MessageProjectionRecovery.SDK(session: { id, _ in
            lookups.modify { $0.append(id) }
            return "old-session"
        }, retry: { _ in retries.modify { $0 += 1 } })
        var recovery = MessageProjectionRecovery()
        for now in [0.0, 5, 10] {
            try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { now })
        }
        #expect(lookups.wrappedValue == ["$event-0"])
        #expect(retries.wrappedValue == 1)
    }

    @Test("Retirement or cancellation during a live lookup prevents the retry", arguments: [false, true])
    func lateLookup(retire: Bool) async throws {
        let database = try Self.database(count: 1)
        let gate = ProjectionLookupGate()
        let sdk = MessageProjectionRecovery.SDK(session: { _, _ in
            await gate.hold()
            return "old-account-session"
        }, retry: { _ in Issue.record("An inactive worker requested SDK work") })
        let task = Task.detached {
            var recovery = MessageProjectionRecovery()
            try await recovery.run(roomID: TimelineWriteFixture.roomID, database: database, sdk: sdk, clock: { 0 })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.isHeld), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.isHeld)
        if retire { try await Task.detached { try database.close() }.value }
        else { task.cancel() }
        await gate.release()
        do { try await task.value } catch is CancellationError { #expect(!retire) }
    }

    private static func database(count: Int) throws -> AccountDatabase {
        let messages = (0..<count).map { index in
            var value = TimelineWriteFixture.message(index)
            value.contentType = "unableToDecrypt"
            value.contentBody = "unavailable"
            return value
        }
        let database = try TimelineWriteFixture.database(legacyMessages: messages)
        try database.write {
            try $0.execute(sql: "UPDATE messageDecryptionRepair SET lastOutcome = 'projection', nextAttemptAt = 999999999999")
        }
        return database
    }
}

private actor ProjectionLookupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    func hold() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
