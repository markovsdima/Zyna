//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - Message Content

enum ChatMessageContent {
    case text(body: String)
    case image(width: UInt64?, height: UInt64?, caption: String?)
    case notice(body: String)
    case emote(body: String)
    case unsupported(typeName: String)
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let eventId: String?
    let senderId: String
    let senderDisplayName: String?
    let isOutgoing: Bool
    let timestamp: Date
    let content: ChatMessageContent

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}
