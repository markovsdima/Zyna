//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

struct StoredSpaceChild: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "storedSpaceChild"

    var spaceId: String
    var childId: String
    var sortOrder: Int
    var displayName: String
    var avatarURL: String?
    var lastMessage: String?
    var lastMessageSenderName: String?
    var lastMessageTimestamp: TimeInterval?
    var unreadCount: Int
    var unreadMentionCount: Int
    var isMarkedUnread: Bool
    var isEncrypted: Bool
    var isSpace: Bool
    var isMuted: Bool
    var directUserId: String?
    var spaceChildRoomCount: Int
    var spaceChildSpaceCount: Int
    var spaceRecentRoomsJSON: String?
    var canonicalAlias: String?
    var topic: String?
    var joinRuleKind: String?
    var joinRuleCustom: String?
    var worldReadable: Bool?
    var guestCanJoin: Bool
    var membership: String?
    var viaJSON: String?
    var joinedMembersCount: Int64
    var childrenCount: Int64
    var joinRuleRulesJSON: String?
}

// MARK: - RoomSummary -> StoredSpaceChild

extension StoredSpaceChild {

    init(spaceId: String, summary: RoomSummary, sortOrder: Int) {
        let encodedJoinRule = Self.encodeJoinRule(summary.spaceMetadata?.joinRule)

        self.spaceId = spaceId
        self.childId = summary.id
        self.sortOrder = sortOrder
        self.displayName = summary.displayName
        self.avatarURL = summary.avatarURL
        self.lastMessage = summary.lastMessage
        self.lastMessageSenderName = summary.lastMessageSenderName
        self.lastMessageTimestamp = summary.lastMessageTimestamp?.timeIntervalSince1970
        self.unreadCount = Int(summary.unreadCount)
        self.unreadMentionCount = Int(summary.unreadMentionCount)
        self.isMarkedUnread = summary.isMarkedUnread
        self.isEncrypted = summary.isEncrypted
        self.isSpace = summary.isSpace
        self.isMuted = summary.isMuted
        self.directUserId = summary.directUserId
        self.spaceChildRoomCount = summary.spaceChildRoomCount
        self.spaceChildSpaceCount = summary.spaceChildSpaceCount
        self.spaceRecentRoomsJSON = Self.encodeSpaceRecentRooms(summary.spaceRecentRooms)
        self.canonicalAlias = summary.spaceMetadata?.canonicalAlias
        self.topic = summary.spaceMetadata?.topic
        self.joinRuleKind = encodedJoinRule.kind
        self.joinRuleCustom = encodedJoinRule.custom
        self.worldReadable = summary.spaceMetadata?.worldReadable
        self.guestCanJoin = summary.spaceMetadata?.guestCanJoin ?? false
        self.membership = Self.encodeMembership(summary.spaceMetadata?.membership)
        self.viaJSON = Self.encodeStrings(summary.spaceMetadata?.via ?? [])
        self.joinedMembersCount = Self.int64(summary.spaceMetadata?.joinedMembersCount ?? 0)
        self.childrenCount = Self.int64(summary.spaceMetadata?.childrenCount ?? 0)
        self.joinRuleRulesJSON = encodedJoinRule.rulesJSON
    }
}

// MARK: - StoredSpaceChild -> RoomSummary

extension StoredSpaceChild {

    func toRoomSummary() -> RoomSummary {
        RoomSummary(
            id: childId,
            displayName: displayName,
            avatarURL: avatarURL,
            lastMessage: lastMessage,
            lastMessageSenderName: lastMessageSenderName,
            lastMessageTimestamp: lastMessageTimestamp.map { Date(timeIntervalSince1970: $0) },
            unreadCount: UInt64(unreadCount),
            unreadMentionCount: UInt64(unreadMentionCount),
            isMarkedUnread: isMarkedUnread,
            isEncrypted: isEncrypted,
            isSpace: isSpace,
            isMuted: isMuted,
            directUserId: directUserId,
            spaceChildRoomCount: spaceChildRoomCount,
            spaceChildSpaceCount: spaceChildSpaceCount,
            spaceRecentRooms: Self.decodeSpaceRecentRooms(spaceRecentRoomsJSON),
            spaceMetadata: decodedSpaceMetadata()
        )
    }

    private func decodedSpaceMetadata() -> SpaceRoomMetadata? {
        let hasMetadata = canonicalAlias != nil
            || topic != nil
            || joinRuleKind != nil
            || worldReadable != nil
            || membership != nil
            || viaJSON != nil
            || guestCanJoin
            || joinedMembersCount > 0
            || childrenCount > 0
        guard hasMetadata else { return nil }

        return SpaceRoomMetadata(
            canonicalAlias: canonicalAlias,
            topic: topic,
            joinRule: Self.decodeJoinRule(
                kind: joinRuleKind,
                custom: joinRuleCustom,
                rulesJSON: joinRuleRulesJSON
            ),
            worldReadable: worldReadable,
            guestCanJoin: guestCanJoin,
            membership: Self.decodeMembership(membership),
            via: Self.decodeStrings(viaJSON),
            joinedMembersCount: Self.uint64(joinedMembersCount),
            childrenCount: Self.uint64(childrenCount)
        )
    }
}

// MARK: - Encoding Helpers

private extension StoredSpaceChild {

    static func encodeSpaceRecentRooms(_ rooms: [SpaceChildSummary]) -> String? {
        guard !rooms.isEmpty,
              let data = try? JSONEncoder().encode(rooms) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeSpaceRecentRooms(_ raw: String?) -> [SpaceChildSummary] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let rooms = try? JSONDecoder().decode([SpaceChildSummary].self, from: data)
        else { return [] }
        return rooms
    }

    static func encodeStrings(_ values: [String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeStrings(_ raw: String?) -> [String] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }

    static func encodeMembership(_ membership: Membership?) -> String? {
        guard let membership else { return nil }

        switch membership {
        case .joined:
            return "joined"
        case .invited:
            return "invited"
        case .knocked:
            return "knocked"
        case .banned:
            return "banned"
        case .left:
            return "left"
        @unknown default:
            return String(describing: membership)
        }
    }

    static func decodeMembership(_ raw: String?) -> Membership? {
        switch raw {
        case "joined":
            return .joined
        case "invited":
            return .invited
        case "knocked":
            return .knocked
        case "banned":
            return .banned
        case "left":
            return .left
        default:
            return nil
        }
    }

    static func encodeJoinRule(_ joinRule: JoinRule?) -> (kind: String?, custom: String?, rulesJSON: String?) {
        guard let joinRule else { return (nil, nil, nil) }

        switch joinRule {
        case .public:
            return ("public", nil, nil)
        case .restricted(let rules):
            return ("restricted", nil, encodeAllowRules(rules))
        case .knock:
            return ("knock", nil, nil)
        case .knockRestricted(let rules):
            return ("knockRestricted", nil, encodeAllowRules(rules))
        case .invite:
            return ("invite", nil, nil)
        case .private:
            return ("private", nil, nil)
        case .custom(repr: let repr):
            return ("custom", repr, nil)
        @unknown default:
            return ("custom", String(describing: joinRule), nil)
        }
    }

    static func decodeJoinRule(kind: String?, custom: String?, rulesJSON: String?) -> JoinRule? {
        switch kind {
        case "public":
            return .public
        case "restricted":
            return .restricted(rules: decodeAllowRules(rulesJSON))
        case "knock":
            return .knock
        case "knockRestricted":
            return .knockRestricted(rules: decodeAllowRules(rulesJSON))
        case "invite":
            return .invite
        case "private":
            return .private
        case "custom":
            return .custom(repr: custom ?? "")
        default:
            return nil
        }
    }

    static func encodeAllowRules(_ rules: [AllowRule]) -> String? {
        let roomIds = rules.compactMap { rule -> String? in
            if case let .roomMembership(roomId) = rule {
                return roomId
            }
            return nil
        }
        return encodeStrings(roomIds)
    }

    static func decodeAllowRules(_ raw: String?) -> [AllowRule] {
        decodeStrings(raw).map { .roomMembership(roomId: $0) }
    }

    static func int64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    static func uint64(_ value: Int64) -> UInt64 {
        value > 0 ? UInt64(value) : 0
    }
}
