//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK
import Testing
@testable import Zyna

@Suite("Explicit chat event exclusions")
struct ChatEventVisibilityTests {
    @Test("Inspection and timeline mapping agree on empty text", arguments: [
        ("", true), (" \n\t", true), ("\u{200B} \n", true),
        ("\u{200B}hello", false), ("Unable to decrypt message", false),
        ("👨‍👩‍👧", false), ("\u{200D}", false)
    ])
    func text(_ sample: (String, Bool)) throws {
        let (body, excluded) = sample
        let inspection = try Self.inspection(content: ["msgtype": "m.text", "body": body])
        let content = TimelineItemContent.msgLike(content: .init(kind: .message(content: .init(
            msgType: .text(content: .init(body: body, formatted: nil)), body: body, isEdited: false, mentions: nil)),
            reactions: [], inReplyTo: nil, threadRoot: nil, threadSummary: nil))
        let expected: ChatEventVisibility.Exclusion? = excluded ? .emptyText : nil
        #expect(ChatEventVisibility.exclusion(for: inspection) == expected)
        #expect(ChatEventVisibility.exclusion(for: content, attributes: .init()) == expected)
    }

    @Test("Only recognized carrier-bearing message types can exclude a call signal", arguments: [
        ("m.text", true), ("m.image", true), ("m.audio", true), ("m.file", true), ("m.video", true),
        ("m.notice", false), ("m.emote", false), ("custom.type", false)
    ])
    func callCarrier(_ sample: (String, Bool)) throws {
        let attributes = ZynaMessageAttributes(callSignal: .init(type: "m.call.answer", payload: "{}"))
        let formatted = ZynaHTMLCodec.encode(userHTML: "Call signal", attributes: attributes)
        let inspection = try Self.inspection(content: [
            "msgtype": sample.0, "body": "Call signal", "formatted_body": formatted
        ])
        #expect(ChatEventVisibility.exclusion(for: inspection) == (sample.1 ? .zynaCallSignal : nil))
        let malformed = try Self.inspection(content: [
            "msgtype": sample.0, "body": "Real text", "formatted_body": "<span data-zyna='broken'></span>"
        ])
        #expect(ChatEventVisibility.exclusion(for: malformed) == nil)
    }

    @Test("MatrixRTC, unsupported types, missing bodies and redacted invites stay outside app exclusions")
    func preservedEvents() throws {
        for type in ["org.matrix.msc4075.rtc.notification", "org.matrix.msc3401.call.member",
                     "m.call.answer", "org.matrix.msc3381.poll.start", "m.room.message", "m.call.invite", "custom.type"] {
            #expect(ChatEventVisibility.exclusion(for: try Self.inspection(type: type, content: [:])) == nil)
        }
        for type in ["m.notice", "m.emote"] {
            #expect(ChatEventVisibility.exclusion(for: try Self.inspection(
                content: ["msgtype": type, "body": "\u{200B}"])) == nil)
        }
        #expect(ChatEventVisibility.exclusion(for: TimelineItemContent.callInvite, attributes: .init()) == .legacyCallInvite)
        #expect(ChatEventVisibility.exclusion(for: TimelineItemContent.rtcNotification(
            callIntent: "video", declinedBy: []), attributes: .init()) == nil)
        var malformed = try Self.inspection(content: [:])
        malformed.event.contentJson = "broken json"
        #expect(ChatEventVisibility.exclusion(for: malformed) == nil)
    }

    private static func inspection(type: String = "m.room.message", content: [String: Any]) throws -> RoomTimelineEventInspection {
        .init(event: .init(roomId: "!room", eventType: type, eventId: "$event", sender: "@alice:example.org",
            originServerTsMs: 0, contentJson: String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self),
            rawJson: "{}", encryptionInfo: nil), disposition: .visible, decryptionFailure: nil)
    }

    @Test("Only a structurally recognized custom call reaction can resolve an indeterminate event")
    func customCallReaction() throws {
        let content: [String: Any] = ["emoji": "👏", "name": "clapping",
            "m.relates_to": ["rel_type": "m.reference", "event_id": "$membership"]]
        var valid = try Self.inspection(type: "io.element.call.reaction", content: content)
        valid.event.rawJson = #"{"type":"io.element.call.reaction","content":{}}"#
        valid.disposition = .indeterminate
        #expect(ChatEventVisibility.exclusion(for: valid) == .callReaction)
        valid.disposition = .visible
        #expect(ChatEventVisibility.exclusion(for: valid) == .callReaction)
        valid.disposition = .indeterminate

        var unknown = valid
        unknown.event.eventType = "other.call.reaction"
        #expect(ChatEventVisibility.exclusion(for: unknown) == nil)
        var encrypted = valid
        encrypted.disposition = .unableToDecrypt
        #expect(ChatEventVisibility.exclusion(for: encrypted) == nil)
        encrypted = valid
        encrypted.decryptionFailure = .unknown
        #expect(ChatEventVisibility.exclusion(for: encrypted) == nil)

        for raw in ["broken json", "{}", #"{"type":"m.room.encrypted"}"#,
                    #"{"type":"io.element.call.reaction","state_key":""}"#,
                    #"{"type":"io.element.call.reaction","unsigned":{"redacted_because":{}}}"#] {
            var malformed = valid
            malformed.event.rawJson = raw
            #expect(ChatEventVisibility.exclusion(for: malformed) == nil)
        }
        for json in ["{}", "broken json",
                     #"{"emoji":"","m.relates_to":{"rel_type":"m.reference","event_id":"$member"}}"#,
                     #"{"emoji":42,"m.relates_to":{"rel_type":"m.reference","event_id":"$member"}}"#,
                     #"{"emoji":"👏","m.relates_to":{"rel_type":"m.annotation","event_id":"$member"}}"#,
                     #"{"emoji":"👏","m.relates_to":{"rel_type":"m.reference","event_id":""}}"#] {
            var malformed = valid
            malformed.event.contentJson = json
            #expect(ChatEventVisibility.exclusion(for: malformed) == nil)
        }
    }
}
