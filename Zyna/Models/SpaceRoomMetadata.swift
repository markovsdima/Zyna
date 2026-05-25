//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import MatrixRustSDK

struct SpaceRoomMetadata: Equatable {
    let canonicalAlias: String?
    let topic: String?
    let joinRule: JoinRule?
    let worldReadable: Bool?
    let guestCanJoin: Bool
    let membership: Membership?
    let via: [String]
    let joinedMembersCount: UInt64
    let childrenCount: UInt64

    init(
        canonicalAlias: String?,
        topic: String?,
        joinRule: JoinRule?,
        worldReadable: Bool?,
        guestCanJoin: Bool,
        membership: Membership?,
        via: [String],
        joinedMembersCount: UInt64,
        childrenCount: UInt64
    ) {
        self.canonicalAlias = canonicalAlias
        self.topic = topic
        self.joinRule = joinRule
        self.worldReadable = worldReadable
        self.guestCanJoin = guestCanJoin
        self.membership = membership
        self.via = via
        self.joinedMembersCount = joinedMembersCount
        self.childrenCount = childrenCount
    }

    init(spaceRoom: SpaceRoom) {
        self.init(
            canonicalAlias: spaceRoom.canonicalAlias,
            topic: spaceRoom.topic,
            joinRule: spaceRoom.joinRule,
            worldReadable: spaceRoom.worldReadable,
            guestCanJoin: spaceRoom.guestCanJoin,
            membership: spaceRoom.state,
            via: spaceRoom.via,
            joinedMembersCount: spaceRoom.numJoinedMembers,
            childrenCount: spaceRoom.childrenCount
        )
    }

    init(roomInfo: RoomInfo) {
        self.init(
            canonicalAlias: roomInfo.canonicalAlias,
            topic: roomInfo.topic,
            joinRule: roomInfo.joinRule,
            worldReadable: nil,
            guestCanJoin: false,
            membership: roomInfo.membership,
            via: Self.viaServers(for: roomInfo.id),
            joinedMembersCount: roomInfo.joinedMembersCount,
            childrenCount: 0
        )
    }

    var isJoined: Bool {
        membership == .joined
    }

    func withMembership(_ membership: Membership?) -> SpaceRoomMetadata {
        SpaceRoomMetadata(
            canonicalAlias: canonicalAlias,
            topic: topic,
            joinRule: joinRule,
            worldReadable: worldReadable,
            guestCanJoin: guestCanJoin,
            membership: membership,
            via: via,
            joinedMembersCount: joinedMembersCount,
            childrenCount: childrenCount
        )
    }

    private static func viaServers(for roomId: String) -> [String] {
        guard let serverName = roomId.split(separator: ":", maxSplits: 1).last,
              !serverName.isEmpty else {
            return []
        }
        return [String(serverName)]
    }
}
