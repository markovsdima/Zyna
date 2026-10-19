// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import Foundation
import GRDB
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private final class PinnedTestPowerLevels: RoomPowerLevels, @unchecked Sendable {
    let allowed: Bool
    init(_ allowed: Bool) { self.allowed = allowed; super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func canOwnUserPinUnpin() -> Bool { allowed }
}

private final class PinnedSDKTestRoom: Room, @unchecked Sendable {
    let info = Atomic(RoomInfo(id: TimelineWriteFixture.roomID, encryptionState: .encrypted, creators: nil,
        displayName: "Group", rawName: "Group", topic: nil, avatarUrl: nil,
        isDirect: false, isDm: false, isPublic: false, isSpace: false, successorRoom: nil,
        isFavourite: false, isLowPriority: false, canonicalAlias: nil, alternativeAliases: [],
        membership: .joined, inviter: nil, heroes: [], activeMembersCount: 3,
        invitedMembersCount: 0, joinedMembersCount: 3, activeServiceMembersCount: 0,
        serviceMembers: [], highlightCount: 0, notificationCount: 0,
        cachedUserDefinedNotificationMode: nil, hasRoomCall: false, activeRoomCallParticipants: [],
        activeRoomCallConsensusIntent: .none, isMarkedUnread: false, numUnreadMessages: 0,
        numUnreadNotifications: 0, numUnreadMentions: 0, pinnedEventIds: ["$event-0"], joinRule: .invite,
        historyVisibility: .shared, powerLevels: nil, roomVersion: "10", privilegedCreatorsRole: false))
    let powerReads = Atomic(0)
    let fallbackPermission = Atomic<Bool?>(true)
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func roomInfo() async throws -> RoomInfo {
        #expect(!Thread.isMainThread)
        return info.wrappedValue
    }
    override func getPowerLevels() async throws -> RoomPowerLevels {
        #expect(!Thread.isMainThread)
        powerReads.modify { $0 += 1 }
        guard let allowed = fallbackPermission.wrappedValue else { throw URLError(.resourceUnavailable) }
        return PinnedTestPowerLevels(allowed)
    }
}

final class PinnedTestSource: RoomPinnedSource, @unchecked Sendable {
    struct State {
        var snapshot = RoomPinnedSnapshot(eventIDs: ["$event-0", "$event-1", "$missing"], canUnpin: true)
        var read: ProfileTestRequest<RoomPinnedSnapshot>?
        var write: ProfileTestRequest<Void>?
        var failRead = false
        var failWrite = false
        var writes: [String] = []
    }
    let state = Atomic(State())
    let callback = Atomic<(@Sendable (RoomPinnedSnapshot) -> Void)?>(nil)
    func load() async throws -> RoomPinnedSnapshot {
        let value = state.wrappedValue
        if value.failRead { throw URLError(.notConnectedToInternet) }
        if let read = value.read { return try await read.wait() }
        return value.snapshot
    }
    func unpin(_ eventID: String) async throws {
        state.modify { $0.writes.append(eventID) }
        if let write = state.wrappedValue.write { try await write.wait() }
        if state.wrappedValue.failWrite { throw URLError(.notConnectedToInternet) }
        state.modify { $0.snapshot.eventIDs.removeAll { $0 == eventID } }
    }
    func observe(_ update: @escaping @Sendable (RoomPinnedSnapshot) -> Void) -> RoomProfileObservation {
        callback.wrappedValue = update
        return RoomProfileObservation { [weak self] in self?.callback.wrappedValue = nil }
    }
    func send(_ value: RoomPinnedSnapshot) {
        state.modify { $0.snapshot = value }
        callback.wrappedValue?(value)
    }
}

@Suite("Pinned profile messages", .serialized)
@MainActor
struct RoomPinnedMessagesTests {
    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition(), sourceLocation: sourceLocation)
    }

    private func database() async throws -> AccountDatabase {
        try await Task.detached {
            let queue = try DatabaseQueue()
            try DatabaseService.migrator.migrate(queue)
            try queue.write { db in
                for index in 0..<2 { try TimelineWriteFixture.message(index).insert(db) }
            }
            return AccountDatabase(queue)
        }.value
    }

    @Test("The SDK retries missing permissions once off-main, without replacing known rights")
    func sdkPermissionFallback() async throws {
        let room = PinnedSDKTestRoom()
        let source = SDKRoomPinnedSource(room: room, removePin: { _ in })
        let recovered = try await source.load()
        #expect(recovered.canUnpin == true && recovered.eventIDs == ["$event-0"])
        #expect(room.powerReads.wrappedValue == 1)
        room.info.modify { $0.powerLevels = PinnedTestPowerLevels(false) }
        #expect(try await source.load().canUnpin == false)
        #expect(room.powerReads.wrappedValue == 1)
        room.info.modify { $0.powerLevels = nil; $0.membership = .left }
        #expect(try await source.load().canUnpin == false)
        #expect(room.powerReads.wrappedValue == 1)
        room.info.modify { $0.membership = .joined }
        room.fallbackPermission.wrappedValue = nil
        #expect(try await source.load().canUnpin == nil)
        #expect(room.powerReads.wrappedValue == 2)
    }

    @Test("A late initial read fills unknown rights without undoing newer pins or live revocation",
          arguments: [false, true], [false, true])
    func initialPermissionRead(revoked: Bool, changedPins: Bool) async throws {
        let db = try await database(), source = PinnedTestSource(), gate = ProfileTestRequest<RoomPinnedSnapshot>()
        source.state.modify { $0.read = gate }
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        try await wait { await gate.isPending }
        let currentIDs = changedPins ? ["$event-1"] : ["$event-0"]
        source.send(.init(eventIDs: currentIDs, canUnpin: revoked ? false : nil))
        try await wait { model.items.count == 1 }
        await gate.finish(.init(eventIDs: ["$event-0"], canUnpin: true))
        await model.waitForOperationsForTesting()
        #expect(model.items.first?.canUnpin == !revoked)
        #expect(model.snapshot?.eventIDs == currentIDs && model.items.map(\.eventId) == currentIDs)
    }

    @Test("Pins deduplicate, observe edits and redactions, and restore after unblock")
    func liveContent() async throws {
        let db = try await database(), source = PinnedTestSource()
        source.state.modify { $0.snapshot = .init(eventIDs: ["", "$event-0", "$event-0", "local", "$event-1", "$missing"], canUnpin: true) }
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        try await wait { !model.isLoading && model.items.count == 3 }
        #expect(model.items.map(\.eventId) == ["$event-0", "$event-1", "$missing"])
        #expect(model.items.last?.subtitle == String(localized: "Message not loaded yet") && model.items.last?.canOpen == true)
        let sender = TimelineWriteFixture.message(0).senderId
        try await db.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted' WHERE eventId = ?", arguments: ["$event-0"])
        }
        try await wait { model.items.first?.canOpen == false }
        #expect(model.items.first?.canUnpin == true)
        try await db.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'unableToDecrypt' WHERE eventId = ?", arguments: ["$event-1"])
        }
        try await wait { model.items[1].canOpen == false }
        try await db.write { db in
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'text' WHERE eventId = ?", arguments: ["$event-1"])
        }
        try await wait { model.items[1].canOpen }
        _ = try await db.write { try IgnoredContentStore.replace([sender], in: $0) }
        try await wait { model.items.map(\.eventId) == ["$missing"] }
        _ = try await db.write { try IgnoredContentStore.replace([], in: $0) }
        try await wait { model.items.count == 3 }
        var message = TimelineWriteFixture.message(2)
        message.eventId = "$missing"
        let stored = message
        try await db.write { try stored.insert($0) }
        try await wait { model.items.last?.subtitle != String(localized: "Message not loaded yet") }
    }

    @Test("An initial read cannot overwrite newer pins or revoked permissions")
    func staleRead() async throws {
        let db = try await database(), source = PinnedTestSource(), gate = ProfileTestRequest<RoomPinnedSnapshot>()
        source.state.modify { $0.read = gate }
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        try await wait { await gate.isPending }
        source.send(.init(eventIDs: ["$event-1"], canUnpin: false))
        try await wait { model.items.count == 1 }
        await gate.finish(.init(eventIDs: ["$event-0"], canUnpin: true))
        await model.waitForOperationsForTesting()
        #expect(model.items.map(\.eventId) == ["$event-1"])
        #expect(model.items.first?.canUnpin == false)
    }

    @Test("Unpin checks current permissions and rejects double taps; failures can retry")
    func unpinRetry() async throws {
        let db = try await database(), source = PinnedTestSource()
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        try await wait { model.items.count == 3 }
        source.state.modify { $0.failWrite = true }
        model.unpin("$event-0"); model.unpin("$event-0")
        await model.waitForOperationsForTesting()
        #expect(source.state.wrappedValue.writes == ["$event-0"])
        #expect(model.items.count == 3 && model.actionError != nil)
        #expect(model.items.first?.unpinError == model.actionError)
        source.state.modify { $0.failWrite = false }
        model.unpin("$event-0")
        await model.waitForOperationsForTesting()
        try await wait { model.items.count == 2 }
        #expect(model.actionError == nil)
        source.state.modify { $0.snapshot.canUnpin = false }
        model.unpin("$event-1")
        await model.waitForOperationsForTesting()
        #expect(source.state.wrappedValue.writes == ["$event-0", "$event-0"])
        #expect(model.items.allSatisfy { !$0.canUnpin })
    }

    @Test("Live permission revocation wins over the action's older permission read")
    func revokedDuringConfirmation() async throws {
        let db = try await database(), source = PinnedTestSource()
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        try await wait { model.items.count == 3 }
        let gate = ProfileTestRequest<RoomPinnedSnapshot>()
        source.state.modify { $0.read = gate }
        model.unpin("$event-0")
        try await wait { await gate.isPending }
        source.send(.init(eventIDs: ["$event-0", "$event-1"], canUnpin: false))
        try await wait { model.snapshot?.canUnpin == false }
        await gate.finish(.init(eventIDs: ["$event-0", "$event-1"], canUnpin: true))
        await model.waitForOperationsForTesting()
        #expect(source.state.wrappedValue.writes.isEmpty)
        #expect(model.actionError != nil)
    }

    @Test("Stopping or switching accounts discards late reads and prevents writes", arguments: [false, true])
    func staleSession(stopping: Bool) async throws {
        let db = try await database(), source = PinnedTestSource(), gate = ProfileTestRequest<RoomPinnedSnapshot>()
        var active = true
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { active })
        model.start(); defer { model.stop() }
        try await wait { model.items.count == 3 }
        source.state.modify { $0.read = gate }
        model.unpin("$event-0")
        try await wait { await gate.isPending }
        if stopping { model.stop() } else { active = false }
        await gate.finish(.init(eventIDs: ["$event-0"], canUnpin: true))
        await model.waitForOperationsForTesting()
        #expect(source.state.wrappedValue.writes.isEmpty)
        #expect(model.items.count == 3)
    }

    @Test("Loading failures stay retryable instead of appearing as an empty list")
    func loadRetry() async throws {
        let db = try await database(), source = PinnedTestSource()
        source.state.modify { $0.failRead = true }
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        #expect(model.loadError != nil && !model.isLoading && model.snapshot == nil)
        source.state.modify { $0.failRead = false }
        model.reload()
        try await wait { model.loadError == nil && model.items.count == 3 }
        source.send(.init(eventIDs: [], canUnpin: true))
        try await wait { model.items.isEmpty && !model.isLoading }
    }

    @Test("Missing permissions preserve the last known grant, but never invent one")
    func missingPermissions() async throws {
        let db = try await database(), source = PinnedTestSource()
        source.state.modify { $0.snapshot.canUnpin = nil }
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        try await wait { model.items.count == 3 }
        #expect(model.items.allSatisfy { !$0.canUnpin })
        source.send(.init(eventIDs: ["$event-0", "$event-1"], canUnpin: true))
        try await wait { model.items.count == 2 && model.items.allSatisfy(\.canUnpin) }
        source.send(.init(eventIDs: ["$event-1", "$event-0"], canUnpin: nil))
        try await wait { model.items.first?.eventId == "$event-1" }
        #expect(model.items.allSatisfy { $0.canUnpin })
        model.unpin("$event-1")
        await model.waitForOperationsForTesting()
        try await wait { model.items.count == 1 }
        #expect(source.state.wrappedValue.writes == ["$event-1"] && model.actionError == nil)
        source.send(.init(eventIDs: ["$event-0"], canUnpin: false))
        try await wait { model.items.first?.canUnpin == false }
    }

    @Test("Database retry survives identical and newer room updates during its room-info read", arguments: [false, true])
    func observationRetry(newerPins: Bool) async throws {
        let db = try await database(), source = PinnedTestSource()
        // Make the real GRDB observation fail, rather than replacing its
        // lifecycle with a mock. Restore the schema before the explicit retry.
        try await db.write { try $0.execute(sql: "ALTER TABLE ignoredUser RENAME COLUMN userId TO unavailable") }
        let model = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        try await wait { model.loadError != nil && model.snapshot != nil }
        try await db.write { try $0.execute(sql: "ALTER TABLE ignoredUser RENAME COLUMN unavailable TO userId") }
        let gate = ProfileTestRequest<RoomPinnedSnapshot>()
        let original = source.state.wrappedValue.snapshot
        source.state.modify { $0.read = gate }
        model.reload()
        try await wait { await gate.isPending }
        let updated = newerPins ? RoomPinnedSnapshot(eventIDs: ["$event-1"], canUnpin: true) : original
        source.send(updated)
        await gate.finish(original)
        await model.waitForOperationsForTesting()
        try await wait { model.loadError == nil && model.items.map(\.eventId) == updated.eventIDs }
        try await db.write { try $0.execute(sql: "UPDATE storedMessage SET contentBody = 'After retry' WHERE eventId = '$event-1'") }
        try await wait { model.items.contains { $0.eventId == "$event-1" && $0.title == "After retry" } }
    }

    @Test("Pin records use bounded batch queries and preserve state-event order", arguments: [50, 1001])
    func batchReads(count: Int) async throws {
        let db = try await database()
        let reads = Atomic(0)
        let ids = (0..<count).reversed().map { "$event-\($0)" }
        try await db.write { db in
            for index in 2..<count { try TimelineWriteFixture.message(index).insert(db) }
            var other = TimelineWriteFixture.message(count)
            other.roomId = "!other:example.org"; other.eventId = "$event-0"
            try other.insert(db)
            db.trace { event in
                if case let .statement(statement) = event,
                   statement.sql.hasPrefix("SELECT"), statement.sql.contains("FROM \"storedMessage\"") {
                    reads.modify { $0 += 1 }
                }
            }
        }
        let records = try await db.read { try RoomPinnedRecords.read(eventIDs: ids, roomID: TimelineWriteFixture.roomID, db: $0) }
        #expect(reads.wrappedValue == (count + 499) / 500)
        #expect(records.records.compactMap { $0?.eventId } == ids)
        #expect(records.records.allSatisfy { $0?.roomId == TimelineWriteFixture.roomID })
    }

    @Test("The banner's list button and VoiceOver action open all pins without advancing the current pin")
    func bannerAction() throws {
        let banner = PinnedMessagesBannerView(frame: CGRect(x: 0, y: 0, width: 330, height: 36))
        var opens = 0
        banner.onShowAll = { opens += 1 }
        banner.configure(index: 0, count: 3, preview: "Example", mode: .expanded)
        banner.layoutIfNeeded()
        let button = try #require(banner.subviews.compactMap { $0 as? UIButton }.first)
        #expect(!button.isHidden && button.bounds.width == 44)
        #expect(banner.hitTest(button.center, with: nil) === button)
        button.sendActions(for: .touchUpInside)
        #expect(opens == 1)
        let action = try #require(banner.accessibilityCustomActions?.first)
        #expect(action.actionHandler?(action) == true && opens == 2)
        banner.configure(index: 0, count: 3, preview: "Example", mode: .collapsed)
        #expect(button.isHidden)
    }
}
