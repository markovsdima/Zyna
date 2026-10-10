// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ChatMessageLink: Equatable {
    let eventID: String
    let photoIndex: Int?

    var accessibilityTitle: String {
        if let photoIndex {
            return String(localized: "Copy link to photo \(photoIndex + 1)")
        }
        return String(localized: "Copy link")
    }

    /// A composite bubble has no single event. Expose each confirmed item
    /// separately to VoiceOver, retaining its original position in the album.
    static func targets(for message: ChatMessage) -> [Self] {
        guard !message.isSyntheticOutgoingEnvelope, !message.isSyntheticIncomingAssembly,
              !message.content.isRedacted else { return [] }
        if let group = message.mediaGroupPresentation, group.rendersCompositeBubble {
            return group.items.enumerated().compactMap { index, item in
                guard let id = remoteID(item.eventId) else { return nil }
                return Self(eventID: id, photoIndex: index)
            }
        }
        guard let id = remoteID(message.eventId) else { return [] }
        return [Self(eventID: id, photoIndex: nil)]
    }

    /// A caption or overflow tile has no unambiguous event target. Never
    /// silently copy the representative event of an album in that case.
    static func target(for message: ChatMessage, selectedItem: MediaGroupItem?) -> Self? {
        let targets = targets(for: message)
        guard let group = message.mediaGroupPresentation, group.rendersCompositeBubble else {
            return targets.first
        }
        guard let selectedItem,
              let index = group.items.firstIndex(where: { $0.messageId == selectedItem.messageId }) else { return nil }
        return targets.first { $0.photoIndex == index }
    }

    private static func remoteID(_ id: String?) -> String? {
        // Local echoes use transaction IDs; a server event ID starts with '$'.
        guard let id, id.hasPrefix("$"), id.count > 1 else { return nil }
        return id
    }
}
