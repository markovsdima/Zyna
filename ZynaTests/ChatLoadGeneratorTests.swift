// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG || CHAT_LIST_PLAYGROUND
import Foundation
import GRDB
import Testing
@testable import Zyna

@MainActor
@Suite("Chat load generator")
struct ChatLoadGeneratorTests {
    @Test("An enqueue error resumes the same transaction, checking persistence before retrying",
          arguments: [false, true])
    func enqueueFailure(persisted: Bool) async throws {
        let database = try makeDatabase()
        let envelopes = OutgoingEnvelopeService(database: database)
        var attempts: [ChatLoadGenerator.Item] = []
        let generator = ChatLoadGenerator(validate: {}, enqueue: { item in
            attempts.append(item)
            if persisted || attempts.count > 1 { Self.enqueue(item, using: envelopes) }
            if attempts.count == 1 { throw ChatLoadGenerator.Failure("Enqueue interrupted") }
            try await Self.acceptAndRetire(item, database: database)
        }, delivery: { id in
            try await database.read { try ChatLoadGeneratorDelivery.read(envelopeID: id, roomID: Self.roomID, in: $0) }
        }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        defer { generator.pause() }
        try generator.start(.init(count: 1, photoEvery: 0, interval: 0.1))
        try await eventually { generator.state == .failed }
        let item = try #require(generator.pending)
        if persisted { try await Self.acceptAndRetire(item, database: database) }
        try generator.resume()
        try await eventually { generator.state == .finished }
        #expect(generator.sent == 1)
        #expect(attempts.count == (persisted ? 1 : 2))
        #expect(attempts.allSatisfy { $0.envelopeID == item.envelopeID })
    }

    @Test("A failed persistence check does not blindly enqueue another message")
    func uncertainPersistence() async throws {
        var attempts = 0, storageFailure = true
        let generator = ChatLoadGenerator(validate: {}, enqueue: { _ in
            attempts += 1
            if attempts == 1 { throw ChatLoadGenerator.Failure("Enqueue interrupted") }
        }, delivery: { _ in
            if storageFailure { throw ChatLoadGenerator.Failure("Storage unavailable") }
            return attempts == 1 ? .missing : .sent
        })
        try generator.start(.init(count: 1, photoEvery: 0, interval: 0.1))
        try await eventually { generator.state == .failed }
        let id = generator.pending?.envelopeID
        try generator.resume()
        try await eventually { generator.state == .failed }
        #expect(attempts == 1 && generator.pending?.envelopeID == id)
        storageFailure = false
        try generator.resume()
        try await eventually { generator.state == .finished }
        #expect(attempts == 2 && generator.sent == 1)
    }

    @Test("Pause wins over a delayed delivery result and session invalidation", arguments: [false, true])
    func pauseDuringDelivery(failure: Bool) async throws {
        var release: CheckedContinuation<ChatLoadGenerator.Delivery, Error>?
        var allowed = true, hold = true, sends = 0
        let generator = ChatLoadGenerator(validate: {
            if !allowed { throw ChatLoadGenerator.Failure("Session closed") }
        }, enqueue: { _ in sends += 1 }, delivery: { _ in
            if hold { return try await withCheckedThrowingContinuation { release = $0 } }
            return .sent
        })
        try generator.start(.init(count: 1, photoEvery: 0, interval: 0.1))
        try await eventually { release != nil }
        generator.pause()
        allowed = false
        let pausedDetail = generator.detail
        if failure { release?.resume(throwing: ChatLoadGenerator.Failure("Delivery failed")) }
        else { release?.resume(returning: .sent) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(generator.state == .paused && generator.detail == pausedDetail)
        #expect(generator.sent == 0)
        allowed = true; hold = false
        try generator.resume()
        try await eventually { generator.state == .finished }
        #expect(generator.sent == 1 && sends == 1)
    }

    @Test("A discarded envelope after a successful enqueue is never recreated by resume")
    func discardedAfterEnqueue() async throws {
        var attempts = 0
        let generator = ChatLoadGenerator(validate: {}, enqueue: { _ in attempts += 1 }, delivery: { _ in .missing })
        try generator.start(.init(count: 1, photoEvery: 0, interval: 0.1))
        try await eventually { generator.state == .failed }
        try generator.resume()
        try await eventually { generator.state == .failed }
        #expect(attempts == 1 && generator.sent == 0)
    }

    @Test("Large runs wait for server acceptance and resume the same envelope")
    func boundedQueueAndResume() async throws {
        let transport = Transport()
        let generator = transport.make()
        defer { generator.pause() }
        try generator.start(.init(count: 50_000, photoEvery: 100, interval: 0.1))
        try await eventually { transport.items.count == 1 && transport.polls > 2 }
        #expect(generator.sent == 0)
        generator.pause()
        let first = try #require(transport.items.first)
        try generator.resume()
        try await eventually { transport.polls > 5 }
        #expect(transport.items.count == 1)
        transport.accepted.insert(first.envelopeID)
        try await eventually { transport.items.count == 2 }
        #expect(generator.sent == 1)
        #expect(transport.items[1].number == 2)
    }

    @Test("Media replaces each Nth message; all counts require acceptance")
    func mixtureAndCompletion() async throws {
        let transport = Transport()
        transport.acceptImmediately = true
        let generator = transport.make()
        try generator.start(.init(count: 7, photoEvery: 3, interval: 0.1))
        try await eventually { generator.state == .finished }
        #expect(generator.sent == 7)
        #expect(transport.items.filter(\.isPhoto).map(\.number) == [3, 6])
        #expect(Set(transport.items.map(\.envelopeID)).count == 7)
        #expect(transport.items.allSatisfy { $0.body.contains(generator.runID) })
    }

    @Test("Pause during enqueue never creates another message or loses its identity")
    func pauseDuringEnqueue() async throws {
        let transport = Transport()
        var release: CheckedContinuation<Void, Never>?
        transport.enqueueGate = { await withCheckedContinuation { release = $0 } }
        let generator = transport.make()
        defer { generator.pause() }
        try generator.start(.init(count: 10, photoEvery: 0, interval: 0.1))
        try await eventually { release != nil }
        generator.pause()
        release?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.items.count == 1)
        #expect(generator.pending?.envelopeID == transport.items[0].envelopeID)
        transport.enqueueGate = nil
        try generator.resume()
        try await eventually { transport.polls > 2 }
        #expect(transport.items.count == 1)
    }

    @Test("Account invalidation and terminal delivery failures stop new sends",
          arguments: [true, false])
    func stopOnFailure(accountChange: Bool) async throws {
        let transport = Transport()
        let generator = transport.make()
        try generator.start(.init(count: 100, photoEvery: 0, interval: 0.1))
        try await eventually { transport.items.count == 1 }
        if accountChange { transport.allowed = false } else { transport.fail = true }
        try await eventually { generator.state == .failed }
        #expect(transport.items.count == 1)
        #expect(generator.sent == 0)
        #expect(!generator.detail.isEmpty)
    }

    @Test("Invalid or unbounded settings cannot start a run")
    func invalidConfiguration() {
        for (count, every, interval) in [(0, 0, 1.0), (100_001, 100, 1.0),
                                        (10, -1, 1.0), (10, 0, 0.0),
                                        (10, 0, Double.nan), (10, 0, Double.infinity)] {
            #expect(throws: ChatLoadGenerator.Failure.self) {
                try ChatLoadGenerator.Configuration(count: count, photoEvery: every, interval: interval)
            }
        }
    }

    @Test("Retrying a failed outbox item continues without resending it")
    func resumeAfterOutboxRetry() async throws {
        let transport = Transport()
        transport.fail = true
        let generator = transport.make()
        defer { generator.pause() }
        try generator.start(.init(count: 10, photoEvery: 0, interval: 0.1))
        try await eventually { generator.state == .failed }
        let first = try #require(transport.items.first)
        transport.fail = false
        try generator.resume()
        try await eventually { transport.polls > 2 }
        #expect(transport.items.count == 1)
        transport.accepted.insert(first.envelopeID)
        try await eventually { transport.items.count == 2 }
        #expect(generator.sent == 1)
        #expect(transport.items[1].number == 2)
    }

    @Test("Text and photo server echoes survive outbox retirement before the first poll",
          arguments: [false, true])
    func retiredBeforeFirstPoll(photo: Bool) async throws {
        let database = try makeDatabase()
        let envelopes = OutgoingEnvelopeService(database: database)
        let generator = ChatLoadGenerator(validate: {}, enqueue: { item in
            Self.enqueue(item, using: envelopes)
            try await Self.acceptAndRetire(item, database: database)
        }, delivery: { id in
            try await database.read { try ChatLoadGeneratorDelivery.read(envelopeID: id, roomID: Self.roomID, in: $0) }
        }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        try generator.start(.init(count: 3, photoEvery: photo ? 1 : 0, interval: 0.1))
        try await eventually { generator.state == .finished || generator.state == .failed }
        #expect(generator.state == .finished)
        #expect(generator.sent == 3)
        #expect(try await database.read { try OutgoingEnvelopeItemRecord.fetchCount($0) } == 0)
    }

    @Test("A message retired while paused is counted exactly once after resuming")
    func retiredWhilePaused() async throws {
        let database = try makeDatabase()
        let envelopes = OutgoingEnvelopeService(database: database)
        var queued: ChatLoadGenerator.Item?
        var polls = 0
        let generator = ChatLoadGenerator(validate: {}, enqueue: { item in
            #expect(queued == nil)
            queued = item
            Self.enqueue(item, using: envelopes)
        }, delivery: { id in
            polls += 1
            return try await database.read { try ChatLoadGeneratorDelivery.read(envelopeID: id, roomID: Self.roomID, in: $0) }
        }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        defer { generator.pause() }
        try generator.start(.init(count: 1, photoEvery: 0, interval: 0.1))
        try await eventually { polls > 2 }
        generator.pause()
        try await Self.acceptAndRetire(#require(queued), database: database)
        try generator.resume()
        try await eventually { generator.state == .finished || generator.state == .failed }
        #expect(generator.state == .finished)
        #expect(generator.sent == 1)
    }

    @Test("Discarded envelopes, local echoes and unrelated server messages are not confirmations")
    func missingDoesNotMeanSent() async throws {
        let database = try makeDatabase()
        let id = "discarded"
        OutgoingEnvelopeService(database: database).createOutgoingText(
            roomId: Self.roomID, envelopeId: id, body: "Discard me", replyInfo: nil, transactionId: id)
        try await database.write { db in
            #expect(try OutgoingEnvelopeRecord.deleteOne(db, key: id))
            var row = TimelineWriteFixture.message(1)
            row.roomId = Self.roomID
            row.isOutgoing = true
            row.eventId = nil
            row.transactionId = id
            try row.insert(db)
            #expect(try ChatLoadGeneratorDelivery.read(envelopeID: id, roomID: Self.roomID, in: db) == .missing)
            row.eventId = "$server"
            row.roomId = "!other:test"
            try row.update(db)
            #expect(try ChatLoadGeneratorDelivery.read(envelopeID: id, roomID: Self.roomID, in: db) == .missing)
            row.roomId = Self.roomID
            row.isOutgoing = false
            try row.update(db)
            #expect(try ChatLoadGeneratorDelivery.read(envelopeID: id, roomID: Self.roomID, in: db) == .missing)
        }
    }

    @Test("A replacement envelope is tracked by transaction until server acceptance")
    func replacementEnvelope() async throws {
        let database = try makeDatabase()
        let envelopes = OutgoingEnvelopeService(database: database)
        envelopes.createOutgoingText(roomId: Self.roomID, envelopeId: "replacement", body: "Retry",
                                     replyInfo: nil, transactionId: "original")
        #expect(try await database.read {
            try ChatLoadGeneratorDelivery.read(envelopeID: "original", roomID: Self.roomID, in: $0)
        } == .waiting)
        #expect(envelopes.markDispatchFailed(envelopeId: "replacement", itemIndex: 0))
        #expect(try await database.read {
            try ChatLoadGeneratorDelivery.read(envelopeID: "original", roomID: Self.roomID, in: $0)
        } == .failed)
        #expect(envelopes.bindEvent(transactionId: "original", eventId: "$accepted"))
        #expect(try await database.read {
            try ChatLoadGeneratorDelivery.read(envelopeID: "original", roomID: Self.roomID, in: $0)
        } == .sent)
    }

    nonisolated private static let roomID = "!load-generator:test"

    private func makeDatabase() throws -> AccountDatabase {
        let queue = try DatabaseQueue()
        try DatabaseService.migrator.migrate(queue)
        return AccountDatabase(queue)
    }

    private static func enqueue(_ item: ChatLoadGenerator.Item, using envelopes: OutgoingEnvelopeService) {
        if item.isPhoto {
            envelopes.createOutgoingImage(roomId: roomID, envelopeId: item.envelopeID, caption: item.body,
                width: 100, height: 100, previewImageData: nil, replyInfo: nil, transactionId: item.envelopeID)
        } else {
            envelopes.createOutgoingText(roomId: roomID, envelopeId: item.envelopeID, body: item.body,
                replyInfo: nil, transactionId: item.envelopeID)
        }
    }

    private static func acceptAndRetire(_ item: ChatLoadGenerator.Item, database: AccountDatabase) async throws {
        let snapshot = try await database.write { db in
            var row = TimelineWriteFixture.message(item.number)
            row.roomId = Self.roomID
            row.isOutgoing = true
            row.transactionId = item.envelopeID
            row.contentType = item.isPhoto ? "image" : "text"
            row.contentBody = item.body
            try row.insert(db)
            try db.execute(sql: "UPDATE pendingMediaGroupItem SET eventId = ?, transportState = 'sent' WHERE groupId = ?",
                           arguments: [row.eventId, item.envelopeID])
            return try ChatTimelineLocalState.fetch(roomId: Self.roomID, in: db)
        }
        try await Task.detached {
            try snapshot.acknowledge(roomId: Self.roomID, retiring: [item.envelopeID], database: database, userId: nil)
        }.value
        #expect(try await database.read { try OutgoingEnvelopeItemRecord.fetchCount($0) } == 0)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate(), "Generator did not reach expected state")
        throw ChatLoadGenerator.Failure("Timed out")
    }

    @MainActor
    private final class Transport {
        var items: [ChatLoadGenerator.Item] = []
        var polls = 0
        var accepted: Set<String> = []
        var acceptImmediately = false
        var allowed = true
        var fail = false
        var enqueueGate: (() async -> Void)?

        func make() -> ChatLoadGenerator {
            ChatLoadGenerator(validate: { [self] in
                if !allowed { throw ChatLoadGenerator.Failure("Session ended") }
            }, enqueue: { [self] item in
                items.append(item)
                await enqueueGate?()
            }, delivery: { [self] id in
                polls += 1
                if fail { return .failed }
                return acceptImmediately || accepted.contains(id) ? .sent : .waiting
            }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        }
    }
}
#endif
