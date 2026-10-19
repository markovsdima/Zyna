//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import MatrixRustSDK

/// Temporary entry point for exercising real media edits through the SDK.
/// Album captions and Zyna-specific formatting need their own editing flow.
enum DebugPhotoCaptionEdit {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "This photo is no longer available for caption editing." }
    }

    static func canEdit(_ message: ChatMessage) -> Bool {
        guard message.isOutgoing, message.eventId?.hasPrefix("$") == true,
              ["sent", "synced", "read"].contains(message.sendStatus),
              !message.isEditPending, !message.isSyntheticOutgoingEnvelope,
              !message.isSyntheticIncomingAssembly, message.mediaGroupPresentation == nil,
              message.zynaAttributes == ZynaMessageAttributes(),
              case .image = message.content else { return false }
        return true
    }

    static func normalized(_ caption: String) -> String? {
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func send(_ message: ChatMessage, caption: String, timeline: Timeline) async throws {
        guard canEdit(message), let eventID = message.eventId else { throw Failure.unavailable }
        try Task.checkCancellation()
        try await timeline.edit(eventOrTransactionId: .eventId(eventId: eventID),
            newContent: .mediaCaption(caption: normalized(caption), formattedCaption: nil, mentions: nil))
    }
}
#endif
