//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

// MARK: - Message Content

enum ChatMessageContent: Equatable {
    case text(body: String)
    case image(source: MediaSource, width: UInt64?, height: UInt64?, caption: String?)
    case notice(body: String)
    case emote(body: String)
    case voice(source: MediaSource, duration: TimeInterval, waveform: [UInt16])
    case unsupported(typeName: String)
    case redacted

    var isRedacted: Bool {
        if case .redacted = self { return true }
        return false
    }

    var textPreview: String {
        switch self {
        case .text(let body): return body
        case .image: return "Photo"
        case .voice: return "Voice message"
        case .notice(let body): return body
        case .emote(let body): return body
        case .unsupported: return "Message"
        case .redacted: return "Deleted message"
        }
    }

    static func == (lhs: ChatMessageContent, rhs: ChatMessageContent) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)):
            return a == b
        case (.image(let s1, let w1, let h1, let c1), .image(let s2, let w2, let h2, let c2)):
            return s1.url() == s2.url() && w1 == w2 && h1 == h2 && c1 == c2
        case (.voice(let s1, let d1, let w1), .voice(let s2, let d2, let w2)):
            return s1.url() == s2.url() && d1 == d2 && w1 == w2
        case (.notice(let a), .notice(let b)):
            return a == b
        case (.emote(let a), .emote(let b)):
            return a == b
        case (.unsupported(let a), .unsupported(let b)):
            return a == b
        case (.redacted, .redacted):
            return true
        default:
            return false
        }
    }
}

// MARK: - Reply Info

struct ReplyInfo: Equatable {
    let eventId: String
    let senderId: String
    let senderDisplayName: String?
    let body: String
}

// MARK: - Reaction

struct MessageReaction: Equatable {
    let key: String
    let count: Int
    let isOwn: Bool
}

// MARK: - Item Identifier (safe copy of SDK's EventOrTransactionId)

enum ChatItemIdentifier: Equatable {
    case eventId(String)
    case transactionId(String)

    func toSDK() -> EventOrTransactionId {
        switch self {
        case .eventId(let id): return .eventId(eventId: id)
        case .transactionId(let id): return .transactionId(transactionId: id)
        }
    }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Equatable, Hashable {
    let id: String
    let eventId: String?
    let itemIdentifier: ChatItemIdentifier?
    let senderId: String
    let senderDisplayName: String?
    let isOutgoing: Bool
    let timestamp: Date
    let content: ChatMessageContent
    let reactions: [MessageReaction]
    let replyInfo: ReplyInfo?
    /// Zyna-specific attributes decoded from formatted_body. Always
    /// present (empty struct if none) so UI code has no optional
    /// unwrap noise.
    let zynaAttributes: ZynaMessageAttributes
    /// Delivery pipeline status. For now populated as "synced" for
    /// every message that comes off the SDK timeline; proper
    /// per-stage tracking lands once we wire SendHandle observation.
    let sendStatus: String

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.eventId == rhs.eventId
            && lhs.senderId == rhs.senderId
            && lhs.senderDisplayName == rhs.senderDisplayName
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.timestamp == rhs.timestamp
            && lhs.content == rhs.content
            && lhs.reactions == rhs.reactions
            && lhs.replyInfo == rhs.replyInfo
            && lhs.zynaAttributes == rhs.zynaAttributes
            && lhs.sendStatus == rhs.sendStatus
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
