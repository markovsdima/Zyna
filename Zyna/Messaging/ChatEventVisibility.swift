//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// Explicit app exclusions shared by timeline mapping and UTD repair.
/// SDK visibility alone does not mean that Zyna displays a chat row.
enum ChatEventVisibility {
    enum Exclusion: String, Sendable {
        case zynaCallSignal, legacyCallInvite, emptyText, callReaction
    }

    static func exclusion(for content: TimelineItemContent,
                          attributes: ZynaMessageAttributes) -> Exclusion? {
        switch content {
        case .callInvite:
            return .legacyCallInvite
        case .msgLike(let content):
            guard case .message(let message) = content.kind else { return nil }
            let body: String?
            if case .text(let text) = message.msgType { body = text.body }
            else { body = nil }
            return messageExclusion(hasCallSignal: attributes.callSignal != nil, textBody: body)
        default:
            return nil
        }
    }

    /// SDK-visible events can supply ordinary app exclusions. The one custom
    /// call reaction type has its own structural proof: Ruma does not know it
    /// and correctly returns indeterminate. Other unknowns remain unresolved.
    static func exclusion(for inspection: RoomTimelineEventInspection) -> Exclusion? {
        guard inspection.decryptionFailure == nil,
              inspection.disposition == .visible || inspection.disposition == .indeterminate,
              let content = try? JSONSerialization.jsonObject(
                with: Data(inspection.event.contentJson.utf8)) as? [String: Any] else { return nil }
        if inspection.event.eventType == "io.element.call.reaction" {
            guard let raw = try? JSONSerialization.jsonObject(
                with: Data(inspection.event.rawJson.utf8)) as? [String: Any],
                  raw["type"] as? String == "io.element.call.reaction", raw["state_key"] == nil,
                  (raw["unsigned"] as? [String: Any])?["redacted_because"] == nil,
                  let emoji = content["emoji"] as? String,
                  !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let relation = content["m.relates_to"] as? [String: Any],
                  relation["rel_type"] as? String == "m.reference",
                  let target = relation["event_id"] as? String, target.hasPrefix("$"), target.count > 1
            else { return nil }
            return .callReaction
        }
        guard inspection.disposition == .visible else { return nil }
        switch inspection.event.eventType {
        case "m.call.invite":
            // Do not infer an invite from a redacted event's type alone.
            guard content["call_id"] is String, content["offer"] is [String: Any] else { return nil }
            return .legacyCallInvite
        case "m.room.message":
            guard let type = content["msgtype"] as? String,
                  let body = content["body"] as? String else { return nil }
            // Match extractZynaAttributes: notice/emote do not carry attrs.
            let carriesAttributes = ["m.text", "m.image", "m.audio", "m.file", "m.video"].contains(type)
            let formatted = content["formatted_body"] as? String
                ?? (content["m.new_content"] as? [String: Any])?["formatted_body"] as? String
            let hasCallSignal = carriesAttributes && formatted.map {
                ZynaHTMLCodec.decode(htmlBody: $0).callSignal != nil
            } == true
            return messageExclusion(hasCallSignal: hasCallSignal, textBody: type == "m.text" ? body : nil)
        default:
            return nil
        }
    }

    private static func messageExclusion(hasCallSignal: Bool, textBody: String?) -> Exclusion? {
        if hasCallSignal { return .zynaCallSignal }
        if let textBody, textBody.replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyText }
        return nil
    }
}
