// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK

enum ContentReportTarget: Hashable, Sendable {
    case message(eventID: String, senderID: String)
    case room(isDirect: Bool)
    case invitation

    static func isRemoteEventID(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix("$") && id.count > 1
    }

    var isInvitation: Bool { self == .invitation }
    var isMessage: Bool { if case .message = self { true } else { false } }
    var title: String {
        switch self {
        case .message: String(localized: "Report message", table: "Reports")
        case .room(let direct): direct ? String(localized: "Report conversation", table: "Reports")
            : String(localized: "Report room", table: "Reports")
        case .invitation: String(localized: "Decline invitation", table: "Reports")
        }
    }
}

struct ContentReportContext: Equatable, Sendable {
    var recipient: String
    var canReport: Bool
    var blockUserID: String?
    var isBlocked: Bool
    var isEncrypted: Bool
}

enum ContentReportStep: CaseIterable, Hashable, Sendable {
    case report, block, leave
}

protocol ContentReportSource: Sendable {
    func load() async throws -> ContentReportContext
    func perform(_ step: ContentReportStep, reason: String, userID: String?) async throws
}

enum ContentReportFailure: Error {
    case unavailable

    static func message(for error: Error) -> String {
        if case ClientError.MatrixApi(_, let code, _, _) = error {
            switch code {
            case "M_UNRECOGNIZED": return String(localized: "Your server does not support this report.", table: "Reports")
            case "M_LIMIT_EXCEEDED": return String(localized: "Too many requests. Wait a moment before trying again.", table: "Reports")
            case "M_NOT_FOUND": return String(localized: "The content is unavailable or can no longer be reported.", table: "Reports")
            case "M_FORBIDDEN": return String(localized: "Your server did not allow this action.", table: "Reports")
            default: break
            }
        }
        if error is ContentReportFailure {
            return String(localized: "This action is no longer available.", table: "Reports")
        }
        return String(localized: "Couldn't complete this action. Check your connection and try again.", table: "Reports")
    }
}

struct SDKContentReportSource: ContentReportSource {
    let client: Client
    let room: Room
    let target: ContentReportTarget
    let database: AccountDatabase

    func load() async throws -> ContentReportContext {
        try await Task.detached { [self] in
            let info = try await room.roomInfo()
            if target.isMessage, info.membership != .joined { throw ContentReportFailure.unavailable }
            let ownID = try client.userId()
            let blockID: String?
            switch target {
            case .message(_, let senderID): blockID = senderID
            case .room:
                blockID = Self.directBlockTarget(isDirect: info.isDirect, activeMembers: info.activeMembersCount,
                    heroIDs: info.heroes.map(\.userId), ownID: ownID)
            case .invitation:
                guard info.membership == .invited else { throw ContentReportFailure.unavailable }
                blockID = info.inviter?.userId
            }
            let userID = blockID == ownID ? nil : blockID
            // Read the persisted account cache: the in-memory list can still
            // be empty before the first sync after launch.
            let isBlocked: Bool
            if let userID {
                isBlocked = try await database.read { try IgnoredContentStore.contains(userID, in: $0) }
            } else {
                isBlocked = false
            }
            let supported = target.isMessage ? true : try await client.isReportRoomApiSupported()
            return ContentReportContext(recipient: URL(string: client.homeserver())?.host ?? client.homeserver(),
                canReport: supported, blockUserID: userID,
                isBlocked: isBlocked,
                isEncrypted: room.encryptionState() != .notEncrypted)
        }.value
    }

    static func directBlockTarget(isDirect: Bool, activeMembers: UInt64, heroIDs: [String], ownID: String) -> String? {
        DirectChatBlockingPolicy.recipient(isDirect: isDirect, activeMembers: activeMembers, heroIDs: heroIDs, ownID: ownID)
    }

    func perform(_ step: ContentReportStep, reason: String, userID: String?) async throws {
        try Task.checkCancellation()
        switch step {
        case .report:
            switch target {
            case .message(let eventID, _):
                guard ContentReportTarget.isRemoteEventID(eventID) else { throw ContentReportFailure.unavailable }
                try await room.reportContent(eventId: eventID, reason: reason)
            case .room, .invitation: try await room.reportRoom(reason: reason)
            }
        case .block:
            guard let userID else { throw ContentReportFailure.unavailable }
            try await IgnoredUsersService(client: client).ignore(userId: userID)
        case .leave:
            if target.isInvitation, room.membership() != .invited { throw ContentReportFailure.unavailable }
            try await room.leave()
        }
    }
}
