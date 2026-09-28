//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK
import Testing
@testable import Zyna

@Suite("Retained decryption placeholder repair")
struct MessageDecryptionRepairTests {
    @Test("Migration only enqueues typed failures and both historical labels")
    func migration() async throws {
        var english = TimelineWriteFixture.message(0)
        english.contentBody = "Unable to decrypt message"
        var russian = TimelineWriteFixture.message(1)
        russian.contentBody = "Не удалось расшифровать сообщение"
        let messages = [english, russian, Self.placeholder(2), TimelineWriteFixture.message(3)]
        let queue = try DatabaseQueue()
        try await Task.detached {
            try DatabaseService.migrator.migrate(queue, upTo: "v29_polls")
            try queue.write { db in
                for message in messages {
                    try message.insert(db)
                }
            }
            try DatabaseService.migrator.migrate(queue)
            try queue.read { db in
                let candidates = try MessageDecryptionRepairStore.candidates(in: db,
                    roomID: TimelineWriteFixture.roomID, now: 1000)
                #expect(Set(candidates.map(\.message.id)) == ["row-0", "row-1", "row-2"])
                #expect(try StoredMessage.fetchCount(db) == 4)
            }
        }.value
    }

    @Test("Only confirmed hidden events are deleted; every uncertain result backs off",
          arguments: [RoomTimelineEventDisposition.visible, .hidden, .unableToDecrypt, .indeterminate])
    func dispositions(_ disposition: RoomTimelineEventDisposition) async throws {
        let database = try TimelineWriteFixture.database()
        let message = Self.placeholder(0)
        try await Self.project(message, database: database)
        let candidate = try await Self.candidate(database)
        let result = Self.inspection(message, disposition: disposition)
        let changed = try await database.write { try MessageDecryptionRepairStore.apply(result,
            to: candidate, in: $0, now: 1000) }
        #expect(changed == (disposition == .hidden))
        let stored = try await database.read { try StoredMessage.fetchOne($0, key: message.id) }
        #expect((stored == nil) == (disposition == .hidden))
        #expect(try await database.read {
            try MessageDecryptionRepairStore.candidates(in: $0, roomID: message.roomId, now: 1000).isEmpty
        })
        if disposition != .hidden {
            #expect(try await Self.candidate(database, now: 1015).attemptCount == 1)
        }
    }

    @Test("SDK and app exclusion proofs survive reopening; a real projection can supersede them", arguments: [false, true])
    func persistedProof(appExcluded: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try TimelineWriteFixture.database(path: path)
        let message = Self.placeholder(0)
        try await Self.project(message, database: database)
        let candidate = try await Self.candidate(database)
        let result = appExcluded ? try Self.appInspection(message, exclusion: .zynaCallSignal)
            : Self.inspection(message, disposition: .hidden)
        try await database.write { db throws -> Void in
            #expect(try MessageDecryptionRepairStore.apply(result,
                                                          to: candidate, in: db, now: 1000))
        }
        try await Task.detached { try database.close() }.value
        let reopened = AccountDatabase(try DatabaseQueue(path: path))
        defer { try? reopened.close() }
        var replay = message
        replay.id = "new-sdk-id"
        try await Self.project(replay, database: reopened)
        #expect(try await reopened.read { try StoredMessage.fetchCount($0) } == 0)
        var visible = message
        visible.contentType = "text"
        visible.contentBody = "Decrypted"
        let visibleID = visible.id
        try await Self.project(visible, database: reopened)
        #expect(try await reopened.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messageDecryptionRepair") } == 0)
        try await Self.project(replay, database: reopened)
        #expect(try await reopened.read { try StoredMessage.fetchOne($0, key: visibleID)?.contentBody } == "Decrypted")
    }

    @Test("Explicit app exclusions resolve typed and legacy placeholders without leaving recovery pending",
          arguments: [ChatEventVisibility.Exclusion.zynaCallSignal, .legacyCallInvite, .emptyText, .callReaction], [false, true])
    func appExclusions(_ exclusion: ChatEventVisibility.Exclusion, legacy: Bool) async throws {
        var message = Self.placeholder(0)
        if legacy {
            message.contentType = "text"
            message.contentBody = "Не удалось расшифровать сообщение"
        }
        let database = try TimelineWriteFixture.database(legacyMessages: [message])
        let candidate = try await Self.candidate(database)
        let result = try Self.appInspection(message, exclusion: exclusion)
        let original = message
        try await database.write { db throws -> Void in
            #expect(try MessageDecryptionRepairStore.applyWithImpact(result, to: candidate, in: db, now: 1000) == .unadmittedRows)
            #expect(try StoredMessage.fetchOne(db, key: original.id) == nil)
            #expect(try ChatHistoryRecovery.Snapshot.fetch(in: db, roomID: original.roomId).isEmpty)
            #expect(try String.fetchOne(db, sql: "SELECT lastOutcome FROM messageDecryptionRepair") == exclusion.rawValue)
            #expect(try MessageDecryptionRepairStore.candidates(in: db, roomID: original.roomId, now: 9999).isEmpty)
        }
    }

    @Test("Unknown and undecryptable app-shaped events never authorize deletion",
          arguments: [RoomTimelineEventDisposition.indeterminate, .unableToDecrypt])
    func uncertainAppEvent(_ disposition: RoomTimelineEventDisposition) async throws {
        let message = Self.placeholder(0)
        let database = try TimelineWriteFixture.database(legacyMessages: [message])
        let candidate = try await Self.candidate(database)
        var result = try Self.appInspection(message, exclusion: .zynaCallSignal)
        result.disposition = disposition
        let uncertain = result
        try await database.write { db throws -> Void in
            #expect(try !MessageDecryptionRepairStore.apply(uncertain, to: candidate, in: db, now: 1000))
            #expect(try StoredMessage.fetchOne(db, key: message.id) == message)
            #expect(try !MessageDecryptionRepairStore.suppresses(message, in: db))
        }
    }

    @Test("A real error-label text stays text, including after a stale missing-key replay")
    func literalText() async throws {
        var message = TimelineWriteFixture.message(0)
        message.contentBody = "Не удалось расшифровать сообщение"
        let database = try TimelineWriteFixture.database(legacyMessages: [message])
        let candidate = try await Self.candidate(database)
        var result = Self.inspection(message, disposition: .visible)
        result.event.eventType = "m.room.message"
        result.event.contentJson = "{\"msgtype\":\"m.text\",\"body\":\"Не удалось расшифровать сообщение\"}"
        let finalResult = result
        let originalID = message.id
        try await database.write { db throws -> Void in
            #expect(try MessageDecryptionRepairStore.applyWithImpact(finalResult, to: candidate, in: db, now: 1000) == .presentation)
        }
        try await Self.project(Self.placeholder(0), database: database)
        #expect(try await database.read { try StoredMessage.fetchOne($0, key: originalID) } == message)
        #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messageDecryptionRepair") } == 0)
        // A newly mapped SDK text is also never enqueued by its label alone.
        message.id = "another-row"
        message.eventId = "$another"
        try await Self.project(message, database: database)
        #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messageDecryptionRepair") } == 0)
    }

    @Test("Old inspection cannot remove newer plaintext, or a recreated identical placeholder", arguments: [false, true])
    func staleResult(appExcluded: Bool) async throws {
        let database = try TimelineWriteFixture.database()
        let message = Self.placeholder(0)
        try await Self.project(message, database: database)
        let candidate = try await Self.candidate(database)
        let result = appExcluded ? try Self.appInspection(message, exclusion: .zynaCallSignal)
            : Self.inspection(message, disposition: .hidden)
        var visible = TimelineWriteFixture.message(0)
        visible.contentBody = "Resolved"
        try await Self.project(visible, database: database)
        try await database.write { db throws -> Void in
            #expect(try !MessageDecryptionRepairStore.apply(result,
                                                           to: candidate, in: db, now: 1000))
        }
        // Delete/recreate the same row; equality alone would miss this race.
        _ = try await database.write { try StoredMessage.deleteOne($0, key: message.id) }
        try await Self.project(message, database: database)
        #expect(try await Self.candidate(database).generation != candidate.generation)
        try await database.write { db throws -> Void in
            #expect(try !MessageDecryptionRepairStore.apply(result,
                                                           to: candidate, in: db, now: 1000))
            #expect(try StoredMessage.fetchOne(db, key: message.id) == message)
        }
    }

    @Test("Lookup failures and mismatched identities retain the message", arguments: [false, true], [false, true])
    func invalidResult(mismatched: Bool, appExcluded: Bool) async throws {
        let database = try TimelineWriteFixture.database()
        let message = Self.placeholder(0)
        try await Self.project(message, database: database)
        let candidate = try await Self.candidate(database)
        var wrong = appExcluded ? try Self.appInspection(message, exclusion: .zynaCallSignal)
            : Self.inspection(message, disposition: .hidden)
        wrong.event.roomId = "!other:example.org"
        let result = mismatched ? wrong : nil
        try await database.write { db throws -> Void in
            #expect(try !MessageDecryptionRepairStore.apply(result, to: candidate, in: db, now: 1000))
            #expect(try StoredMessage.fetchOne(db, key: message.id) == message)
        }
    }

    @Test("SDK removal retries a deferred UTD without deleting it by position")
    func retryHint() async throws {
        let database = try TimelineWriteFixture.database()
        let message = Self.placeholder(0)
        try await Self.project(message, database: database)
        let candidate = try await Self.candidate(database)
        _ = try await database.write { try MessageDecryptionRepairStore.apply(nil, to: candidate, in: $0, now: 1000) }
        try await Task.detached {
            try TimelineDiffBatcher.writeMappedEvents([[.inspectDecryption(eventId: message.eventId!)]],
                roomId: message.roomId, database: database, currentUserId: "", summary: .init(removeCount: 1),
                historyRevision: TimelineHistoryRevision()) { _ in }
        }.value
        #expect(try await Self.candidate(database).message == message)
    }

    @Test("Inspection is serial and off-main; local repair advances history provenance")
    @MainActor
    func worker() async throws {
        let database = try TimelineWriteFixture.database()
        for index in 0..<12 { try await Self.project(Self.placeholder(index), database: database) }
        let revision = TimelineHistoryRevision()
        let activeCalls = Atomic(0)
        let changes = Atomic(0)
        let repair = MessageDecryptionRepair(roomID: TimelineWriteFixture.roomID, database: database,
            historyRevision: revision, inspect: { id in
                Self.expectBackgroundThread()
                #expect(activeCalls.withValue { $0 += 1; return $0 } == 1)
                defer { activeCalls.modify { $0 -= 1 } }
                try await Task.sleep(for: .milliseconds(5))
                let index = Int(id.dropFirst("$event-".count))!
                return Self.inspection(Self.placeholder(index), disposition: .hidden)
            }, didChange: { summary in
                #expect(Thread.isMainThread)
                #expect(!summary.allowsRemoteRedactionAnimation)
                #expect(summary.canRefreshBoundsOnly)
                #expect(summary.recoveredEventIDs.isEmpty)
                changes.modify { $0 += 1 }
            })
        defer { repair.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while changes.wrappedValue < 12, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(changes.wrappedValue == 12)
        #expect(revision.current == 12)
        #expect(!TimelineFlushSummary(setCount: 1).coveringSnapshot(historyRevision: revision.current).allowsRemoteRedactionAnimation)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 0)
        repair.stop()
        await repair.waitUntilStopped()
    }

    @Test("Stopping or retiring during inspection discards a late success", arguments: [false, true])
    func accountHandoff(retire: Bool) async throws {
        let database = try TimelineWriteFixture.database()
        let nextAccount = try TimelineWriteFixture.database()
        let message = Self.placeholder(0)
        try await Self.project(message, database: database)
        try await Self.project(message, database: nextAccount)
        let gate = HeldInspection()
        let revision = TimelineHistoryRevision()
        let repair = MessageDecryptionRepair(roomID: message.roomId, database: database,
            historyRevision: revision, inspect: { _ in
                await gate.hold()
                return Self.inspection(message, disposition: .hidden)
            }, didChange: { _ in Issue.record("A cancelled account refreshed its chat") })
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.isHeld), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.isHeld)
        if retire { try await Task.detached { try database.close() }.value }
        else { repair.stop() }
        await gate.release()
        await repair.waitUntilStopped()
        #expect(revision.current == 0)
        #expect(try await nextAccount.read { try StoredMessage.fetchOne($0, key: message.id) } == message)
        if !retire { #expect(try await database.read { try StoredMessage.fetchOne($0, key: message.id) } == message) }
    }

    @Test("A completed SDK result queued behind a busy writer is discarded after stop")
    func cancelledQueuedWrite() async throws {
        let database = try TimelineWriteFixture.database()
        let message = Self.placeholder(0)
        try await Self.project(message, database: database)
        let writeQueue = DispatchQueue(label: "test.held-decryption-writer")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        writeQueue.async { _ = release.wait(timeout: .now() + 10) }
        let inspected = Atomic(false)
        let repair = MessageDecryptionRepair(roomID: message.roomId, database: database,
            historyRevision: TimelineHistoryRevision(), writeQueue: writeQueue, inspect: { _ in
                inspected.wrappedValue = true
                return Self.inspection(message, disposition: .hidden)
            }, didChange: { _ in Issue.record("Cancelled queued write notified the chat") })
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !inspected.wrappedValue, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(inspected.wrappedValue)
        repair.stop()
        release.signal()
        await repair.waitUntilStopped()
        #expect(try await database.read { try StoredMessage.fetchOne($0, key: message.id) } == message)
    }

    private static func placeholder(_ index: Int) -> StoredMessage {
        var message = TimelineWriteFixture.message(index)
        message.contentType = "unableToDecrypt"
        message.contentBody = "unavailable"
        return message
    }

    private static func expectBackgroundThread() { #expect(!Thread.isMainThread) }

    private static func appInspection(_ message: StoredMessage,
                                      exclusion: ChatEventVisibility.Exclusion) throws -> RoomTimelineEventInspection {
        var result = Self.inspection(message, disposition: .visible)
        result.event.eventType = exclusion == .legacyCallInvite ? "m.call.invite" : "m.room.message"
        let content: [String: Any]
        switch exclusion {
        case .zynaCallSignal:
            content = ["msgtype": "m.text", "body": "Call signal", "formatted_body": ZynaHTMLCodec.encode(
                userHTML: "Call signal", attributes: .init(callSignal: .init(type: "m.call.candidates", payload: "{}")))]
        case .legacyCallInvite:
            content = ["call_id": "call", "offer": ["type": "offer", "sdp": "sdp"], "lifetime": 60000, "version": 0]
        case .emptyText:
            content = ["msgtype": "m.text", "body": "\u{200B} \n"]
        case .callReaction:
            result.disposition = .indeterminate
            result.event.eventType = "io.element.call.reaction"
            result.event.rawJson = #"{"type":"io.element.call.reaction"}"#
            content = ["emoji": "👏", "name": "clapping",
                       "m.relates_to": ["rel_type": "m.reference", "event_id": "$membership"]]
        }
        result.event.contentJson = String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
        return result
    }

    private static func inspection(_ message: StoredMessage, disposition: RoomTimelineEventDisposition) -> RoomTimelineEventInspection {
        .init(event: .init(roomId: message.roomId, eventType: "org.matrix.msc3381.poll.response",
            eventId: message.eventId, sender: message.senderId, originServerTsMs: UInt64(message.timestamp * 1000),
            contentJson: "{}", rawJson: "{}", encryptionInfo: nil), disposition: disposition,
            decryptionFailure: disposition == .unableToDecrypt ? .unknown : nil)
    }

    private static func candidate(_ database: AccountDatabase, now: TimeInterval = 1000) async throws -> MessageDecryptionRepairStore.Candidate {
        try #require(try await database.read {
            try MessageDecryptionRepairStore.candidates(in: $0, roomID: TimelineWriteFixture.roomID, now: now).first
        })
    }

    private static func project(_ message: StoredMessage, database: AccountDatabase) async throws {
        try await Task.detached {
            try TimelineDiffBatcher.writeMappedEvents([TimelineWriteFixture.event(message)], roomId: message.roomId,
                database: database, currentUserId: "", summary: .init(setCount: 1),
                historyRevision: TimelineHistoryRevision()) { _ in }
        }.value
    }
}

private actor HeldInspection {
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    func hold() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
