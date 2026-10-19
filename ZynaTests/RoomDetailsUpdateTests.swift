// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private final class DetailsTestPowerLevels: RoomPowerLevels, @unchecked Sendable {
    let allowed: Bool
    let topicOnly: Bool
    init(_ allowed: Bool, topicOnly: Bool = false) {
        self.allowed = allowed; self.topicOnly = topicOnly; super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func canOwnUserInvite() -> Bool { allowed }
    override func canOwnUserSendState(stateEvent: StateEventType) -> Bool { allowed && (!topicOnly || stateEvent == .roomTopic) }
}

private final class DetailsTestHandle: TaskHandle, @unchecked Sendable {
    override func cancel() { }
}

private final class DetailsTestRoom: Room, @unchecked Sendable {
    let info: Atomic<RoomInfo>
    let listener = Atomic<(any RoomInfoListener)?>(nil)
    let powerReads = Atomic(0)
    init() {
        info = Atomic(RoomInfo(id: "!details:example.org", encryptionState: .encrypted, creators: nil,
            displayName: "Group", rawName: "Group", topic: nil, avatarUrl: nil,
            isDirect: false, isDm: false, isPublic: false, isSpace: false, successorRoom: nil,
            isFavourite: false, isLowPriority: false, canonicalAlias: nil, alternativeAliases: [],
            membership: .joined, inviter: nil, heroes: [], activeMembersCount: 3,
            invitedMembersCount: 0, joinedMembersCount: 3, activeServiceMembersCount: 0,
            serviceMembers: [], highlightCount: 0, notificationCount: 0,
            cachedUserDefinedNotificationMode: nil, hasRoomCall: false, activeRoomCallParticipants: [],
            activeRoomCallConsensusIntent: .none, isMarkedUnread: false, numUnreadMessages: 0,
            numUnreadNotifications: 0, numUnreadMentions: 0, pinnedEventIds: [], joinRule: .invite,
            historyVisibility: .shared, powerLevels: DetailsTestPowerLevels(true), roomVersion: "10",
            privilegedCreatorsRole: false))
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func id() -> String { info.wrappedValue.id }
    override func displayName() -> String? { info.wrappedValue.displayName }
    override func avatarUrl() -> String? { info.wrappedValue.avatarUrl }
    override func encryptionState() -> EncryptionState { info.wrappedValue.encryptionState }
    override func roomInfo() async throws -> RoomInfo { info.wrappedValue }
    override func getPowerLevels() async throws -> RoomPowerLevels {
        powerReads.modify { $0 += 1 }
        return DetailsTestPowerLevels(true)
    }
    override func subscribeToRoomInfoUpdates(listener: any RoomInfoListener) -> TaskHandle {
        self.listener.wrappedValue = listener
        return DetailsTestHandle(noHandle: .init())
    }
    func send(_ change: (inout RoomInfo) -> Void) {
        info.modify(change)
        listener.wrappedValue?.call(roomInfo: info.wrappedValue)
    }
}

@Suite("Room Details incremental updates", .serialized)
@MainActor
struct RoomDetailsUpdateTests {
    private func flushUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("Message updates preserve navigation controls, avatar work and edits")
    func unchangedInformation() async throws {
        let room = DetailsTestRoom()
        let controller = RoomDetailsViewController(room: room, memberCount: 3, roomListService: ZynaRoomListService())
        _ = controller.view
        let bar = try #require(controller.node.glassTopBar)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while bar.items.count != 3, ContinuousClock.now < deadline { await Task.yield() }
        try #require(bar.items.count == 3)
        let controls = bar.subnodes?.compactMap { $0 as? ASButtonNode } ?? []
        try #require(controls.count == 2)
        let identities = controls.map(ObjectIdentifier.init)
        let avatarRevision = controller.node.avatarLoadRevision
        for index in 1...50 { room.send { $0.numUnreadMessages = UInt64(index) } }
        await flushUpdates()
        #expect(bar.subnodes?.compactMap { $0 as? ASButtonNode }.map(ObjectIdentifier.init) == identities)
        #expect(controller.node.avatarLoadRevision == avatarRevision)

        controls.last?.sendActions(forControlEvents: .touchUpInside, with: nil)
        controller.node.updateNameLocally("Unsaved name")
        room.send { $0.numUnreadMessages += 1 }
        await flushUpdates()
        #expect(controller.node.editingName == "Unsaved name")
        room.send { $0.powerLevels = DetailsTestPowerLevels(false) }
        await flushUpdates()
        #expect(bar.items.count == 2)
        #expect(controller.node.editingName == "Group")
        room.send { $0.displayName = "Renamed"; $0.joinedMembersCount = 4 }
        await flushUpdates()
        #expect(controller.node.editingName == "Renamed")
    }

    @Test("Missing SDK power levels do not trigger a duplicate read")
    func missingPowerLevels() async throws {
        let room = DetailsTestRoom()
        room.info.modify { $0.powerLevels = nil }
        let snapshot = try await SDKRoomProfileSource(room: room, fallbackUserID: nil).load()
        #expect(snapshot.permissions == nil && room.powerReads.wrappedValue == 0)
    }

    @Test("Permission to edit only the description enables Edit without enabling name or avatar changes")
    func topicOnlyPermission() async throws {
        let room = DetailsTestRoom()
        room.info.modify { $0.powerLevels = DetailsTestPowerLevels(true, topicOnly: true) }
        let snapshot = try await SDKRoomProfileSource(room: room, fallbackUserID: nil).load()
        #expect(snapshot.permissions?.editTopic == true)
        #expect(snapshot.permissions?.editName == false && snapshot.permissions?.editAvatar == false)
        #expect(RoomProfileAction.edit.isEnabled(in: snapshot))
        let controller = RoomDetailsViewController(room: room, memberCount: 3,
            roomListService: ZynaRoomListService(), initiallyEditing: true)
        _ = controller.view
        let bar = try #require(controller.node.glassTopBar)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while bar.items.count != 3, ContinuousClock.now < deadline { await Task.yield() }
        #expect(bar.items.count == 3)
        #expect(RoomTopicSnapshot(room.info.wrappedValue).canEdit)
        room.send { $0.membership = .left }
        await flushUpdates()
        #expect(bar.items.count == 2 && !RoomTopicSnapshot(room.info.wrappedValue).canEdit)
    }
}
