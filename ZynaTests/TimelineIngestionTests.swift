//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK
import Testing
@testable import Zyna

/// Fake only the FFI object handles. Diffs use the production mapper,
/// positional bookkeeping, admission limits, queues and SQLite writer.
private final class IngestionItem: TimelineItem, @unchecked Sendable {
    private let event: EventTimelineItem
    private let identifier: String

    init(_ index: Int, body: String? = nil, redacted: Bool = false, own: Bool = false) {
        identifier = "item-\(index)"
        let body = body ?? "Message \(index)"
        let kind: MsgLikeKind = redacted ? .redacted : .message(content: .init(
            msgType: .text(content: .init(body: body, formatted: nil)), body: body,
            isEdited: false, mentions: nil))
        event = .init(isRemote: true, eventOrTransactionId: .eventId(eventId: "$event-\(index)"),
            sender: "@alice:example.org", senderProfile: .pending, forwarder: nil, forwarderProfile: nil,
            isOwn: own, isEditable: false,
            content: .msgLike(content: .init(kind: kind, reactions: [], inReplyTo: nil,
                threadRoot: nil, threadSummary: nil)), eventTypeRaw: "m.room.message",
            timestamp: UInt64(max(0, index)) * 1000, localSendState: nil, localCreatedAt: nil,
            readReceipts: [:], origin: nil, canBeRepliedTo: true, lazyProvider: IngestionLazyProvider())
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle: UInt64) { fatalError("Test objects never cross FFI") }
    override func asEvent() -> EventTimelineItem? { event }
    override func uniqueId() -> TimelineUniqueId { .init(id: identifier) }
}

private final class IngestionLazyProvider: LazyTimelineItemProvider, @unchecked Sendable {
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle: UInt64) { fatalError("Test objects never cross FFI") }
    override func debugInfo() -> EventTimelineItemDebugInfo {
        .init(model: "", originalJson: nil, latestEditJson: nil)
    }
}

@Suite("Bounded timeline ingestion", .timeLimit(.minutes(1)))
struct TimelineIngestionTests {
    private final class Gate: @unchecked Sendable {
        let entered = Atomic(false)
        private let signal = DispatchSemaphore(value: 0)
        func hold() throws {
            entered.wrappedValue = true
            guard signal.wait(timeout: .now() + 15) == .success else { throw Failure.timeout }
        }
        func release() { signal.signal() }
    }

    private enum Failure: Error { case timeout }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func installGate(_ gate: Gate, in database: AccountDatabase) async throws {
        try await database.write { db in
            db.add(function: DatabaseFunction("hold_ingestion", argumentCount: 0) { _ in
                try gate.hold()
                return 0
            })
            try db.execute(sql: """
                CREATE TRIGGER hold_ingestion BEFORE INSERT ON storedMessage
                WHEN NEW.eventId = '$event-0' BEGIN SELECT hold_ingestion(); END;
                """)
        }
    }

    @Test("A large reset maps at most a writing portion and a prepared portion while SQLite is blocked")
    func boundedReset() async throws {
        let database = try TimelineWriteFixture.database()
        let gate = Gate()
        defer { gate.release() }
        try await installGate(gate, in: database)
        let batcher = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
            ingestionLimits: .init(maximumEvents: 8, maximumEstimatedBytes: 1024 * 1024, maximumDelay: 60))
        batcher.receive(diffs: [.reset(values: (0..<1024).map { IngestionItem($0) })])
        try await waitFor { gate.entered.wrappedValue && batcher.ingestionMetrics.snapshot.mappedEvents == 16 }
        // The listener can enqueue another callback even while our mapper is
        // waiting for the writer. Its retained SDK items must be counted too.
        batcher.receive(diffs: [.pushBack(value: IngestionItem(1024))])
        let held = batcher.ingestionMetrics.snapshot
        #expect(held.rawBatches == 2)
        #expect(held.rawItems == 1025)
        #expect(held.peakMappedEvents == 16)
        #expect(held.mappedTotal == 16)
        let barrierFinished = Atomic(false)
        let barrier = Task { await batcher.synchronize(); barrierFinished.wrappedValue = true }
        #expect(!barrierFinished.wrappedValue)
        gate.release()
        await barrier.value
        let finished = batcher.ingestionMetrics.snapshot
        #expect(finished.rawBatches == 0)
        #expect(finished.rawItems == 0)
        #expect(finished.mappedEvents == 0)
        #expect(finished.mappedBytes == 0)
        #expect(finished.peakMappedEvents <= 16)
        #expect(finished.mappedTotal == 1025)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 1025)
    }

    @Test("Byte limits split large text payloads before the event-count limit")
    func byteLimit() async throws {
        let database = try TimelineWriteFixture.database()
        let gate = Gate()
        defer { gate.release() }
        try await installGate(gate, in: database)
        let limit = 12 * 1024
        let batcher = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
            ingestionLimits: .init(maximumEvents: 256, maximumEstimatedBytes: limit, maximumDelay: 60))
        batcher.receive(diffs: [.reset(values: (0..<40).map { IngestionItem($0, body: String(repeating: "я", count: 2000)) })])
        try await waitFor { gate.entered.wrappedValue && batcher.ingestionMetrics.snapshot.mappedEvents >= 4 }
        #expect(batcher.ingestionMetrics.snapshot.mappedTotal < 40)
        gate.release()
        await batcher.synchronize()
        #expect(batcher.ingestionMetrics.snapshot.peakMappedBytes <= 2 * limit)
        #expect(batcher.ingestionMetrics.snapshot.completedBatches > 1)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 40)
    }

    @Test("An oversized indivisible event makes progress and does not drop its following event")
    func oversizedEvent() async throws {
        let database = try TimelineWriteFixture.database()
        let body = String(repeating: "large", count: 4000)
        let batcher = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
            ingestionLimits: .init(maximumEvents: 256, maximumEstimatedBytes: 1024, maximumDelay: 60))
        batcher.receive(diffs: [.reset(values: [IngestionItem(0, body: body), IngestionItem(1)])])
        await batcher.synchronize()
        let rows = try await database.read { try StoredMessage.order(Column("timestamp")).fetchAll($0) }
        #expect(rows.count == 2)
        #expect(rows.first?.contentBody == body)
        #expect(batcher.ingestionMetrics.snapshot.mappedEvents == 0)
        #expect(batcher.ingestionMetrics.snapshot.completedBatches == 2)
    }

    @Test("Portions preserve positional diffs, durable removals and monotonic redactions")
    func positionalOrdering() async throws {
        let database = try TimelineWriteFixture.database()
        let batcher = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
            ingestionLimits: .init(maximumEvents: 1, maximumEstimatedBytes: 1024 * 1024, maximumDelay: 60))
        batcher.receive(diffs: [.reset(values: (0..<3).map { IngestionItem($0) }),
            .remove(index: 0), .set(index: 0, value: IngestionItem(1, body: "updated")),
            .pushFront(value: IngestionItem(3)), .truncate(length: 2),
            .set(index: 1, value: IngestionItem(1, redacted: true)),
            .set(index: 1, value: IngestionItem(1, body: "stale")),
            .clear, .append(values: [IngestionItem(4)])])
        await batcher.synchronize()
        let rows = try await database.read { try StoredMessage.fetchAll($0) }
        #expect(rows.count == 5)
        #expect(rows.first { $0.eventId == "$event-1" }?.contentType == "redacted")
        #expect(rows.first { $0.eventId == "$event-0" }?.contentBody == "Message 0")
        #expect(batcher.ingestionMetrics.snapshot.mappedEvents == 0)
    }

    @Test("Every reset portion preserves history provenance and live arrivals are counted once")
    func provenanceAndIncoming() async throws {
        let database = try TimelineWriteFixture.database()
        let summaries = Atomic<[TimelineFlushSummary]>([])
        let batcher = await MainActor.run {
            let value = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
                ingestionLimits: .init(maximumEvents: 2, maximumEstimatedBytes: 1024 * 1024, maximumDelay: 60))
            value.onFlush = { summary in summaries.modify { $0.append(summary) } }
            return value
        }
        batcher.receive(diffs: [.reset(values: (0..<7).map { IngestionItem($0) }),
            .set(index: 0, value: IngestionItem(0, redacted: true))])
        await batcher.synchronize()
        await MainActor.run {
            let values = summaries.wrappedValue
            #expect(values.count == 4)
            #expect(values.allSatisfy { $0.hasHistoryOrResetShape && !$0.allowsRemoteRedactionAnimation })
            #expect(values.reduce(0) { $0 + $1.incomingMessageCount } == 0)
        }
        batcher.receive(diffs: [.append(values: (7..<12).map { IngestionItem($0) })])
        await batcher.synchronize()
        batcher.receive(diffs: [.reset(values: (0..<12).map { IngestionItem($0) })])
        await batcher.synchronize()
        await MainActor.run {
            #expect(summaries.wrappedValue.reduce(0) { $0 + $1.incomingMessageCount } == 5)
        }
    }

    @Test("A writer error releases the permit and the next callback can persist")
    func failedWriterReleasesPermit() async throws {
        let database = try TimelineWriteFixture.database()
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_ingestion BEFORE INSERT ON storedMessage
                WHEN NEW.eventId = '$event-0' BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
                """)
        }
        let batcher = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
            ingestionLimits: .init(maximumEvents: 1, maximumEstimatedBytes: 1024 * 1024, maximumDelay: 60))
        batcher.receive(diffs: [.reset(values: [IngestionItem(0)])])
        batcher.receive(diffs: [.pushBack(value: IngestionItem(1))])
        await batcher.synchronize()
        let rows = try await database.read { try StoredMessage.fetchAll($0) }
        #expect(rows.map(\.eventId) == ["$event-1"])
        #expect(batcher.ingestionMetrics.snapshot.failedBatches == 1)
        #expect(batcher.ingestionMetrics.snapshot.mappedEvents == 0)
    }

    @Test("Continuous small callbacks flush before the input stream becomes idle")
    func fixedDeadline() async throws {
        let database = try TimelineWriteFixture.database()
        let gate = Gate()
        defer { gate.release() }
        try await installGate(gate, in: database)
        let batcher = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
            ingestionLimits: .init(maximumEvents: 10000, maximumEstimatedBytes: 100 * 1024 * 1024,
                maximumDelay: 0.05))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var sent = 0
        while !gate.entered.wrappedValue, ContinuousClock.now < deadline {
            batcher.receive(diffs: [.pushBack(value: IngestionItem(sent))])
            sent += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.entered.wrappedValue)
        gate.release()
        await batcher.synchronize()
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == sent)
    }

    @Test("An empty reset cannot leave stale history provenance on a later live update")
    func emptyReset() async throws {
        let database = try TimelineWriteFixture.database()
        let summaries = Atomic<[TimelineFlushSummary]>([])
        let batcher = await MainActor.run {
            let value = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database)
            value.onFlush = { summary in summaries.modify { $0.append(summary) } }
            return value
        }
        batcher.receive(diffs: [.reset(values: [])])
        await batcher.synchronize()
        batcher.receive(diffs: [.pushBack(value: IngestionItem(0))])
        await batcher.synchronize()
        await MainActor.run {
            #expect(summaries.wrappedValue.count == 1)
            #expect(summaries.wrappedValue.first?.resetCount == 0)
        }
    }

    @Test("Read receipts apply after all earlier portions, including a receipt-only tail")
    func receiptOrdering() async throws {
        let database = try TimelineWriteFixture.database()
        let batcher = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
            ingestionLimits: .init(maximumEvents: 4, maximumEstimatedBytes: 1024 * 1024, maximumDelay: 60))
        batcher.receive(diffs: [.reset(values: (0..<21).map { IngestionItem($0, own: true) })])
        batcher.updateReadCursor(timestamp: 10)
        await batcher.synchronize()
        let rows = try await database.read { try StoredMessage.fetchAll($0) }
        #expect(rows.filter { $0.sendStatus == "read" }.count == 11)
        batcher.updateReadCursor(timestamp: 30)
        await batcher.synchronize()
        #expect(try await database.read { try StoredMessage.filter(Column("sendStatus") == "read").fetchCount($0) } == 21)
    }

    @Test("Account retirement and a cancelled barrier release both portions without new database access")
    func retirement() async throws {
        let database = try TimelineWriteFixture.database()
        let gate = Gate()
        defer { gate.release() }
        try await installGate(gate, in: database)
        let batcher = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database,
            ingestionLimits: .init(maximumEvents: 4, maximumEstimatedBytes: 1024 * 1024, maximumDelay: 60))
        batcher.receive(diffs: [.reset(values: (0..<100).map { IngestionItem($0) })])
        try await waitFor { gate.entered.wrappedValue && batcher.ingestionMetrics.snapshot.mappedEvents == 8 }
        let barrier = Task { await batcher.synchronize() }
        barrier.cancel()
        let closing = Task.detached { try database.close() }
        try await waitFor { !database.isActive }
        gate.release()
        await barrier.value
        try await closing.value
        #expect(database.isClosed)
        #expect(batcher.ingestionMetrics.snapshot.rawItems == 0)
        #expect(batcher.ingestionMetrics.snapshot.mappedEvents == 0)
        #expect(batcher.ingestionMetrics.snapshot.mappedBytes == 0)
    }

    @Test("Accepted tail work survives releasing the screen's batcher reference and then deallocates")
    func releasedOwnerDrains() async throws {
        let database = try TimelineWriteFixture.database()
        var batcher: TimelineDiffBatcher? = TimelineDiffBatcher(roomId: TimelineWriteFixture.roomID, dbQueue: database)
        let wasReleased = { [weak batcher] in batcher == nil }
        let metrics = try #require(batcher).ingestionMetrics
        batcher?.receive(diffs: [.reset(values: [IngestionItem(0)])])
        batcher = nil
        try await waitFor { wasReleased() && metrics.snapshot.rawBatches == 0 && metrics.snapshot.mappedEvents == 0 }
        #expect(metrics.snapshot.mappedTotal == 1)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 1)
    }
}
