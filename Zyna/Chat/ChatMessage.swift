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
    case file(source: MediaSource, filename: String, mimetype: String?, size: UInt64?, caption: String?)
    case callEvent(type: CallEventType, callId: String, reason: String?)
    case systemEvent(text: String, kind: SystemEventKind)
    case unsupported(typeName: String)
    case redacted

    // MediaSource is a class — compare by URL, not reference.
    // Image dimensions: treat nil as "not yet loaded", not as a change.
    static func == (lhs: ChatMessageContent, rhs: ChatMessageContent) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): return a == b
        case (.notice(let a), .notice(let b)): return a == b
        case (.emote(let a), .emote(let b)): return a == b
        case (.redacted, .redacted): return true
        case (.unsupported(let a), .unsupported(let b)): return a == b
        case (.callEvent(let t1, let c1, let r1), .callEvent(let t2, let c2, let r2)):
            return t1 == t2 && c1 == c2 && r1 == r2
        case (.systemEvent(let t1, let k1), .systemEvent(let t2, let k2)):
            return t1 == t2 && k1 == k2
        case (.image(let s1, let w1, let h1, let c1), .image(let s2, let w2, let h2, let c2)):
            // Treat nil dimensions as "not yet loaded" — don't trigger
            // cell recreation when SDK sends the same image without/with size.
            let wMatch = w1 == w2 || w1 == nil || w2 == nil
            let hMatch = h1 == h2 || h1 == nil || h2 == nil
            return s1.url() == s2.url() && wMatch && hMatch && c1 == c2
        case (.voice(let s1, let d1, let w1), .voice(let s2, let d2, let w2)):
            return s1.url() == s2.url() && d1 == d2 && w1 == w2
        case (.file(let s1, let f1, let m1, let sz1, let c1), .file(let s2, let f2, let m2, let sz2, let c2)):
            return s1.url() == s2.url() && f1 == f2 && m1 == m2 && sz1 == sz2 && c1 == c2
        default: return false
        }
    }

    var isRedacted: Bool {
        if case .redacted = self { return true }
        return false
    }

    /// Returns the text body for text/notice/emote, nil for media.
    var textBody: String? {
        switch self {
        case .text(let body): return body
        case .notice(let body): return body
        case .emote(let body): return body
        default: return nil
        }
    }

    /// Media source + mimetype for re-upload during forwarding.
    var mediaForwardInfo: (source: MediaSource, mimetype: String)? {
        switch self {
        case .image(let source, _, _, _):
            return (source, "image/jpeg")
        case .voice(let source, _, _):
            return (source, "audio/mp4")
        case .file(let source, _, let mime, _, _):
            return (source, mime ?? "application/octet-stream")
        default:
            return nil
        }
    }

    var textPreview: String {
        switch self {
        case .text(let body): return body
        case .image: return "Photo"
        case .voice: return "Voice message"
        case .file(_, let filename, _, _, _): return filename
        case .callEvent(let type, _, let reason): return type.displayText(reason: reason)
        case .systemEvent(let text, _): return text
        case .notice(let body): return body
        case .emote(let body): return body
        case .unsupported: return "Message"
        case .redacted: return "Deleted message"
        }
    }

    var isStandaloneEvent: Bool {
        switch self {
        case .callEvent, .systemEvent:
            return true
        default:
            return false
        }
    }

    var visibleImageCaption: String? {
        guard case .image(_, _, _, let caption) = self,
              let caption
        else { return nil }
        let visible = caption
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : visible
    }

    var visibleFileCaption: String? {
        guard case .file(_, _, _, _, let caption) = self,
              let caption
        else { return nil }
        let visible = caption
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : visible
    }

}

// MARK: - Call Event Type

enum CallEventType: String, Codable, Equatable {
    case invited    // call was initiated
    case ended      // call ended (reason in separate field)

    func displayText(reason: String?) -> String {
        switch self {
        case .invited:
            return "Call"
        case .ended:
            switch reason {
            case "timeout":   return "Missed call"
            case "declined":  return "Declined call"
            case "busy":      return "Busy"
            default:          return "Call ended"
            }
        }
    }
}

// MARK: - System Event Kind

enum SystemEventKind: String, Codable, Equatable {
    case membership
    case profileChange
    case roomState
}

// MARK: - Reply Info

struct ReplyInfo: Equatable {
    let eventId: String
    let senderId: String
    let senderDisplayName: String?
    let body: String
}

// MARK: - Reaction

struct ReactionSender: Codable, Equatable {
    let userId: String
    let timestamp: TimeInterval
}

struct MessageReaction: Equatable {
    let key: String
    let senders: [ReactionSender]
    let isOwn: Bool
    /// Fallback count for GRDB rows that still use the older reactions cache format.
    /// Once a message is refreshed from Matrix timeline/history sync, sender details
    /// are written and this fallback is no longer needed.
    let legacyCount: Int?

    init(
        key: String,
        senders: [ReactionSender],
        isOwn: Bool,
        legacyCount: Int? = nil
    ) {
        self.key = key
        self.senders = senders
        self.isOwn = isOwn
        self.legacyCount = legacyCount
    }

    var count: Int {
        max(senders.count, legacyCount ?? 0)
    }

    var hasDetailedSenders: Bool {
        !senders.isEmpty
    }
}

struct ReactionSummaryEntry: Equatable {
    let id: String
    let userId: String
    let displayName: String
    let timestamp: Date
    let reactionKey: String
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

// MARK: - Cluster Neighbor

/// Phantom neighbour just outside the visible window. Carries only
/// what the cluster rule consults, so peek queries don't pay full
/// ChatMessage construction.
struct ClusterNeighbor {
    let senderId: String
    let timestamp: Date
    let isStandaloneEvent: Bool
    let mediaGroupId: String?
}

enum MediaGroupPosition: String, Equatable {
    case top
    case middle
    case bottom
}

struct MediaGroupItem: Equatable {
    let messageId: String
    let eventId: String?
    let transactionId: String?
    let source: MediaSource
    let width: UInt64?
    let height: UInt64?
    let caption: String?
    let sendStatus: String

    static func == (lhs: MediaGroupItem, rhs: MediaGroupItem) -> Bool {
        lhs.messageId == rhs.messageId
            && lhs.eventId == rhs.eventId
            && lhs.transactionId == rhs.transactionId
            && lhs.source.url() == rhs.source.url()
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.caption == rhs.caption
            && lhs.sendStatus == rhs.sendStatus
    }
}

struct MediaGroupPresentation: Equatable {
    let id: String
    let position: MediaGroupPosition
    let totalHint: Int
    let caption: String?
    let captionPlacement: CaptionPlacement
    let suppressIndividualCaption: Bool
    let items: [MediaGroupItem]
    let rendersCompositeBubble: Bool
    let hidesStandaloneBubble: Bool
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Equatable, Hashable {
    let id: String
    let eventId: String?
    let transactionId: String?
    let itemIdentifier: ChatItemIdentifier?
    let senderId: String
    let senderDisplayName: String?
    let senderAvatarUrl: String?
    let isOutgoing: Bool
    let timestamp: Date
    let content: ChatMessageContent
    let reactions: [MessageReaction]
    let replyInfo: ReplyInfo?
    /// Zyna-specific attributes decoded from formatted_body. Always
    /// present (empty struct if none) so UI code has no optional
    /// unwrap noise.
    let zynaAttributes: ZynaMessageAttributes
    let sendStatus: String
    /// Populated by ChatViewModel.decorateClusters. Defaults assume a
    /// standalone message so DMs and one-off callers don't need to set them.
    var isFirstInCluster: Bool = true
    var isLastInCluster: Bool = true
    /// Populated by ChatViewModel for adjacent photo groups.
    var mediaGroupPresentation: MediaGroupPresentation?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        // id (SDK uniqueId) is unstable across timeline recreations.
        // Use eventId as the stable identity; compare other fields by value.
        lhs.eventId == rhs.eventId
            && lhs.transactionId == rhs.transactionId
            && lhs.senderId == rhs.senderId
            && lhs.senderDisplayName == rhs.senderDisplayName
            && lhs.senderAvatarUrl == rhs.senderAvatarUrl
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.timestamp == rhs.timestamp
            && lhs.content == rhs.content
            && lhs.reactions == rhs.reactions
            && lhs.replyInfo == rhs.replyInfo
            && lhs.zynaAttributes == rhs.zynaAttributes
            && lhs.sendStatus == rhs.sendStatus
            && lhs.isLastInCluster == rhs.isLastInCluster
            && lhs.mediaGroupPresentation == rhs.mediaGroupPresentation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
