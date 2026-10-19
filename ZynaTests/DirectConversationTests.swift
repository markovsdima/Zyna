// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK
import Testing
@testable import Zyna

private final class ConversationTestRoom: Room, @unchecked Sendable {
    let roomID: String
    let memberState: Membership
    init(_ roomID: String, membership: Membership = .joined) {
        self.roomID = roomID; memberState = membership
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func id() -> String { roomID }
    override func membership() -> Membership { memberState }
}

private final class ConversationTestClient: Client, @unchecked Sendable {
    struct State {
        var rooms: [Room] = []
        var createCount = 0
        var request: CreateRoomParameters?
        var gate: ProfileTestRequest<Void>?
        var accessedOnMain = false
    }
    let state = Atomic(State())
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func getDmRooms(userId: String) throws -> [Room] {
        state.modify { $0.accessedOnMain = $0.accessedOnMain || Thread.isMainThread }
        return state.wrappedValue.rooms
    }
    override func createRoom(request: CreateRoomParameters) async throws -> String {
        state.modify { $0.createCount += 1; $0.request = request }
        if let gate = state.wrappedValue.gate { try await gate.wait() }
        let room = ConversationTestRoom("!new:example.org")
        state.modify { $0.rooms.append(room) }
        return room.roomID
    }
    override func getRoom(roomId: String) throws -> Room? {
        state.wrappedValue.rooms.first { $0.id() == roomId }
    }
}

@Suite("Explicit direct conversation requests")
struct DirectConversationTests {
    @Test("Existing joined rooms are reused, including the contact's preferred conversation")
    func existingRoom() async throws {
        let client = ConversationTestClient()
        let other = ConversationTestRoom("!other:example.org")
        let preferred = ConversationTestRoom("!preferred:example.org")
        client.state.modify { $0.rooms = [other, preferred] }
        let room = try await DirectConversationService().open(userID: "@alice:example.org", client: client,
            sessionID: "account", preferredRoomID: preferred.roomID)
        #expect(room === preferred)
        #expect(client.state.wrappedValue.createCount == 0)
        #expect(!client.state.wrappedValue.accessedOnMain)
    }

    @Test("Concurrent requests create once and resolve directly from the SDK before any list publication")
    func coalescedCreation() async throws {
        let service = DirectConversationService(), client = ConversationTestClient()
        let gate = ProfileTestRequest<Void>()
        client.state.modify { $0.gate = gate }
        async let first = service.open(userID: "@alice:example.org", client: client, sessionID: "account")
        async let second = service.open(userID: "@alice:example.org", client: client, sessionID: "account")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.isPending), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.isPending)
        await gate.finish(())
        let (a, b) = try await (first, second)
        #expect(a === b && a.id() == "!new:example.org")
        #expect(client.state.wrappedValue.createCount == 1)
        #expect(client.state.wrappedValue.request?.isEncrypted == true)
        #expect(client.state.wrappedValue.request?.invite == ["@alice:example.org"])
    }

    @Test("An existing invitation does not silently create a second room")
    func invitation() async throws {
        let client = ConversationTestClient()
        client.state.modify { $0.rooms = [ConversationTestRoom("!invite:example.org", membership: .invited)] }
        await #expect(throws: DirectConversationError.self) {
            try await DirectConversationService().open(userID: "@alice:example.org", client: client, sessionID: "account")
        }
        #expect(client.state.wrappedValue.createCount == 0)
    }
}
