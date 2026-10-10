// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import GRDB
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private let blockedPerson = "@alice:example.org"
private let blockingOwnID = "@me:example.org"

private func blockingRoomInfo() -> RoomInfo {
    RoomInfo(id: "!blocking:example.org", encryptionState: .notEncrypted, creators: nil,
        displayName: "Renamed room", rawName: "Renamed room", topic: nil, avatarUrl: nil,
        isDirect: true, isDm: true, isPublic: false, isSpace: false, successorRoom: nil,
        isFavourite: false, isLowPriority: false, canonicalAlias: nil, alternativeAliases: [],
        membership: .joined, inviter: nil,
        heroes: [.init(userId: blockedPerson, displayName: "Alice", avatarUrl: nil)],
        activeMembersCount: 2, invitedMembersCount: 0, joinedMembersCount: 2,
        activeServiceMembersCount: 0, serviceMembers: [], highlightCount: 0, notificationCount: 0,
        cachedUserDefinedNotificationMode: nil, hasRoomCall: false, activeRoomCallParticipants: [],
        activeRoomCallConsensusIntent: .none, isMarkedUnread: false, numUnreadMessages: 0,
        numUnreadNotifications: 0, numUnreadMentions: 0, pinnedEventIds: [], joinRule: .invite,
        historyVisibility: .shared, powerLevels: nil, roomVersion: "10", privilegedCreatorsRole: false)
}

private final class BlockingTestRoom: Room, @unchecked Sendable {
    let info: RoomInfo
    let gate: ProfileTestRequest<Void>?
    init(info: RoomInfo = blockingRoomInfo(), gate: ProfileTestRequest<Void>? = nil) {
        self.info = info; self.gate = gate
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func encryptionState() -> EncryptionState { info.encryptionState }
    override func roomInfo() async throws -> RoomInfo {
        #expect(!Thread.isMainThread)
        if let gate { try await gate.wait() }
        return info
    }
}

@Suite("Blocked direct conversations", .serialized)
@MainActor
struct DirectChatBlockingTests {
    private func database() async throws -> AccountDatabase {
        try await Task.detached {
            let queue = try DatabaseQueue()
            try DatabaseService.migrator.migrate(queue)
            return AccountDatabase(queue)
        }.value
    }

    private func wait(_ predicate: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate(), sourceLocation: sourceLocation)
    }

    @Test("Persisted blocks apply at startup, and account changes restore the composer without a network read")
    func persistedStateAndChanges() async throws {
        let db = try await database()
        try await db.write { try IgnoredContentStore.replace([blockedPerson], in: $0) }
        let blocking = DirectChatBlockingModel(database: db, ownID: blockingOwnID,
            isCurrentSession: { true }, unignore: { _ in Issue.record("Unexpected unignore") })
        let chat = ChatViewModel(testingRoomId: "!blocking:example.org", dbQueue: db,
            window: MessageWindow(roomId: "!blocking:example.org", dbQueue: db), mode: .normal,
            blocking: blocking, liveRoom: BlockingTestRoom())
        defer { chat.cleanup() }
        blocking.update(blockingRoomInfo())
        try await wait { chat.composerSendRestrictionReason == .recipientBlocked }
        #expect(chat.isComposerSendBlocked)
        #expect(!chat.canSubmitComposer())
        #expect(!chat.canCreatePoll)
        #expect(blocking.recipientName == "Alice")
        try await db.write { try IgnoredContentStore.replace([], in: $0) }
        NotificationCenter.default.post(name: IgnoredContentStore.didChange, object: db)
        try await wait { blocking.state == .allowed && chat.composerSendRestrictionReason == nil }
        #expect(!chat.isComposerSendBlocked)
        #expect(chat.canSubmitComposer())
        try await db.write { try IgnoredContentStore.replace([blockedPerson], in: $0) }
        NotificationCenter.default.post(name: IgnoredContentStore.didChange, object: db)
        try await wait { chat.composerSendRestrictionReason == .recipientBlocked }
    }

    @Test("A blocked member never locks a group or an ambiguous direct room")
    func groupsRemainWritable() async throws {
        let db = try await database()
        try await db.write { try IgnoredContentStore.replace([blockedPerson], in: $0) }
        let model = DirectChatBlockingModel(database: db, ownID: blockingOwnID,
            isCurrentSession: { true }, unignore: { _ in })
        model.start(); defer { model.stop() }
        for (direct, members, heroes) in [(false, UInt64(2), [blockedPerson]),
                                          (true, 3, [blockedPerson]),
                                          (true, 2, [blockedPerson, "@bob:example.org"])] {
            var info = blockingRoomInfo()
            info.isDirect = direct; info.activeMembersCount = members
            info.heroes = heroes.map { .init(userId: $0, displayName: nil, avatarUrl: nil) }
            model.update(info)
            await model.refresh()?.value
            #expect(model.state == .allowed)
            try await DirectChatBlockingPolicy.requireUnblocked(room: BlockingTestRoom(info: info),
                database: db, ownID: blockingOwnID, isCurrentSession: { true })
        }
    }

    @Test("Unblock waits for confirmation, deduplicates taps and retains blocking on failure")
    func unblockConfirmation() async throws {
        let db = try await database(), gate = ProfileTestRequest<Void>()
        try await db.write { try IgnoredContentStore.replace([blockedPerson], in: $0) }
        let calls = Atomic(0), failing = Atomic(true)
        let model = DirectChatBlockingModel(database: db, ownID: blockingOwnID,
            isCurrentSession: { true }, unignore: { id in
                #expect(id == blockedPerson)
                calls.modify { $0 += 1 }
                if failing.wrappedValue { throw URLError(.notConnectedToInternet) }
                try await gate.wait()
                try await db.write { try IgnoredContentStore.replace([], in: $0) }
            })
        model.update(blockingRoomInfo()); model.start(); defer { model.stop() }
        try await wait { model.state == .blocked(blockedPerson) }
        model.unblock()
        try await wait { model.error != nil && !model.isUnblocking }
        #expect(model.state == .blocked(blockedPerson))
        failing.wrappedValue = false
        model.retryLastFailure(); model.unblock()
        try await wait { await gate.isPending }
        #expect(calls.wrappedValue == 2)
        #expect(model.isUnblocking && model.state == .blocked(blockedPerson))
        await gate.finish(())
        try await wait { model.state == .allowed && !model.isUnblocking }
        #expect(model.error == nil)
    }

    @Test("Late reads cannot undo a newer snapshot or cross an account boundary")
    func staleReads() async throws {
        let db = try await database()
        let gate = ProfileTestRequest<Set<String>>()
        let delayed = Atomic(false), active = Atomic(true)
        let model = DirectChatBlockingModel(database: db, ownID: blockingOwnID,
            isCurrentSession: { active.wrappedValue }, unignore: { _ in },
            readIgnoredIDs: { delayed.wrappedValue ? try await gate.wait() : [] })
        model.update(blockingRoomInfo()); model.start(); defer { model.stop() }
        try await wait { model.state == .allowed }
        delayed.wrappedValue = true
        let old = model.refresh()
        try await wait { await gate.isPending }
        delayed.wrappedValue = false
        await model.refresh()?.value
        await gate.finish([blockedPerson])
        await old?.value
        #expect(model.state == .allowed)
        delayed.wrappedValue = true
        let inactive = model.refresh()
        try await wait { await gate.isPending }
        active.wrappedValue = false
        await gate.finish([blockedPerson])
        await inactive?.value
        #expect(model.state == .allowed)
    }

    @Test("A queued dispatch rechecks blocking, and blocked failures never retry automatically")
    func dispatchGuard() async throws {
        #expect(!DirectRawTextSender.isRetryableTransportError(DirectChatBlockingError.blocked("@network:example.org")))
        let db = try await database(), room = BlockingTestRoom()
        try await DirectChatBlockingPolicy.requireUnblocked(room: room, database: db,
            ownID: blockingOwnID, isCurrentSession: { true })
        try await db.write { try IgnoredContentStore.replace([blockedPerson], in: $0) }
        do {
            try await DirectChatBlockingPolicy.requireUnblocked(room: room, database: db,
                ownID: blockingOwnID, isCurrentSession: { true })
            Issue.record("Dispatch admitted a blocked recipient")
        } catch {
            let context = try #require(OutgoingSendFailureContext.fromError(error))
            #expect(context.reason == .recipientBlocked && context.affectedUserIds == [blockedPerson])
            #expect(!DirectRawTextSender.isRetryableTransportError(error))
        }
        try await db.write { try IgnoredContentStore.replace([], in: $0) }
        try await DirectChatBlockingPolicy.requireUnblocked(room: room, database: db,
            ownID: blockingOwnID, isCurrentSession: { true })
    }

    @Test("A temporarily missing or replaced client keeps queued text, media and polls retryable")
    func retryAfterSessionChange() {
        let error = DirectChatBlockingError.staleSession
        #expect(OutgoingSendFailureContext.fromError(error) == nil)
        #expect(DirectRawTextSender.isRetryableTransportError(error))
        let receipt = DirectRawMediaSender.rejectedReceipt(for: error)
        #expect(!receipt.acceptedByTransport && receipt.retryableTransportFailure)
    }

    @Test("A failed first read allows composing, keeps dispatch guarded and can be retried")
    func recoverInitialReadFailure() async throws {
        let db = try await database(), failing = Atomic(true)
        try await db.write { try IgnoredContentStore.replace([blockedPerson], in: $0) }
        let blocking = DirectChatBlockingModel(database: db, ownID: blockingOwnID,
            isCurrentSession: { true }, unignore: { _ in Issue.record("A read retry must not unblock") },
            readIgnoredIDs: {
                if failing.wrappedValue { throw DatabaseError(resultCode: .SQLITE_BUSY) }
                return try await db.read { try IgnoredContentStore.userIDs(in: $0) }
            })
        let chat = ChatViewModel(testingRoomId: "!blocking:example.org", dbQueue: db,
            window: MessageWindow(roomId: "!blocking:example.org", dbQueue: db), mode: .normal,
            blocking: blocking, liveRoom: BlockingTestRoom())
        defer { chat.cleanup() }
        try await wait { blocking.error != nil && !chat.isComposerSendBlocked }
        // A later RoomInfo snapshot must not put the composer back in loading.
        blocking.update(blockingRoomInfo())
        #expect(blocking.state == .allowed && chat.canSubmitComposer())
        do {
            try await DirectChatBlockingPolicy.requireUnblocked(room: BlockingTestRoom(), database: db,
                ownID: blockingOwnID, isCurrentSession: { true })
            Issue.record("The UI fallback bypassed the dispatch check")
        } catch DirectChatBlockingError.blocked(let id) { #expect(id == blockedPerson) }
        blocking.error = nil // The alert clears the presented error.
        failing.wrappedValue = false
        blocking.retryLastFailure()
        try await wait { blocking.state == .blocked(blockedPerson) && chat.isComposerSendBlocked }
        #expect(blocking.error == nil)

        // Losing the next snapshot must not discard a known block.
        failing.wrappedValue = true
        await blocking.refresh()?.value
        #expect(blocking.error != nil && blocking.state == .blocked(blockedPerson))
        #expect(!chat.canSubmitComposer())
    }

    @Test("Account invalidation during an SDK read prevents dispatch")
    func invalidatedDispatch() async throws {
        let db = try await database(), gate = ProfileTestRequest<Void>(), active = Atomic(true)
        let room = BlockingTestRoom(gate: gate)
        let request = Task {
            try await DirectChatBlockingPolicy.requireUnblocked(room: room, database: db,
                ownID: blockingOwnID, isCurrentSession: { active.wrappedValue })
        }
        try await wait { await gate.isPending }
        active.wrappedValue = false
        await gate.finish(())
        do {
            try await request.value
            Issue.record("A retired account admitted dispatch")
        } catch DirectChatBlockingError.staleSession { }
    }

    @Test("Locking keeps the composed text and forward preview until the user explicitly sends")
    func draftSurvivesLock() throws {
        let input = ChatInputNode()
        _ = input.view
        var sent: [ComposerText] = []
        input.onSend = { text, _ in sent.append(text) }
        input.setCurrentText("Draft")
        input.setForwardPreview(senderName: "Alice", body: "Forwarded text")
        input.setComposerLocked(true)
        input.sendButtonNode.sendActions(forControlEvents: .touchUpInside, with: nil)
        #expect(sent.isEmpty)
        #expect(input.textInputNode.textView.text == "Draft")
        input.setComposerLocked(false)
        // The policy can change before the locked appearance is delivered.
        input.onShouldSend = { false }
        input.sendButtonNode.sendActions(forControlEvents: .touchUpInside, with: nil)
        #expect(sent.isEmpty)
        #expect(input.textInputNode.textView.text == "Draft")
        input.onShouldSend = { true }
        input.setCurrentText("")
        // An empty composer can send only while the forward preview survives.
        input.sendButtonNode.sendActions(forControlEvents: .touchUpInside, with: nil)
        #expect(sent.count == 1)
    }

    @Test("The blocked panel fits long names and large text without covering its action")
    func panelLayout() throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        let panel = ReadOnlyComposerPlaceholderView()
        parent.addSubview(panel)
        let button = try #require(panel.subviews.compactMap { $0 as? UIButton }.first)
        var taps = 0
        panel.onUnblock = { taps += 1 }
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            panel.traitOverrides.preferredContentSizeCategory = category
            panel.configure(blockedName: String(repeating: "Long name ", count: 15), isUnblocking: false)
            panel.updateLayout(in: parent)
            panel.layoutIfNeeded()
            let labels = panel.subviews.compactMap { $0 as? UILabel }
            #expect(labels.allSatisfy { $0.frame.maxY < button.frame.minY })
            #expect(button.frame.maxY <= panel.bounds.height)
            #expect(panel.frame.minY >= 0)
            #expect(button.bounds.height >= 44)
            #expect(!panel.isAccessibilityElement && button.isAccessibilityElement)
        }
        button.sendActions(for: .touchUpInside)
        #expect(taps == 1)
        panel.configure(blockedName: "Alice", isUnblocking: true)
        #expect(!button.isEnabled && button.configuration?.showsActivityIndicator == true)
        panel.configure(blockedName: nil, isUnblocking: false)
        #expect(button.isHidden)
    }
}
