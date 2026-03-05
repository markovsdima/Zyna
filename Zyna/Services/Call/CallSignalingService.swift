//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

private let callLog = ScopedLog(.call)

// MARK: - Call Signaling Service

/// Handles sending and receiving call signaling events for VoIP.
/// Sends m.call.invite natively (SDK delivers it as .callInvite).
/// Sends answer/candidates/hangup as text messages through the timeline's
/// encrypted send pipeline, with a marker prefix for identification.
/// Receives timeline items from TimelineService (not its own listener).
final class CallSignalingService {

    /// Prefix used to identify call signaling messages in text bodies.
    static let signalingPrefix = "ZYNA_CALL:"

    // MARK: - Incoming Events

    let incomingEventSubject = PassthroughSubject<CallSignalingEvent, Never>()

    // MARK: - Properties

    let roomId: String
    private let room: Room
    private let ownUserId: String
    private weak var timelineService: TimelineService?
    private var processedEventIds = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(room: Room, ownUserId: String) {
        self.room = room
        self.roomId = room.id()
        self.ownUserId = ownUserId
    }

    // MARK: - Subscribe to TimelineService

    func subscribe(to timelineService: TimelineService) {
        self.timelineService = timelineService

        timelineService.rawTimelineItemsSubject
            .sink { [weak self] items in
                self?.processItems(items)
            }
            .store(in: &cancellables)
        callLog("Signaling subscribed to TimelineService for room \(roomId)")
    }

    // MARK: - Send Events

    func sendInvite(_ content: CallInviteContent) async throws {
        guard let json = CallEventJSON.encode(content) else {
            callLog("Failed to encode call invite")
            return
        }
        // Send as native m.call.invite — SDK delivers as .callInvite in timeline
        try await room.sendRaw(eventType: "m.call.invite", content: json)
        callLog("Sent m.call.invite (callId: \(content.callId))")
    }

    func sendAnswer(_ content: CallAnswerContent) async throws {
        try await sendViaTimeline(type: "m.call.answer", content: content)
        callLog("Sent m.call.answer (callId: \(content.callId))")
    }

    func sendCandidates(_ content: CallCandidatesContent) async throws {
        try await sendViaTimeline(type: "m.call.candidates", content: content)
        callLog("Sent m.call.candidates (callId: \(content.callId), count: \(content.candidates.count))")
    }

    func sendHangup(_ content: CallHangupContent) async throws {
        try await sendViaTimeline(type: "m.call.hangup", content: content)
        callLog("Sent m.call.hangup (callId: \(content.callId))")
    }

    // MARK: - Stop

    func stop() {
        cancellables.removeAll()
        timelineService = nil
        callLog("Signaling stopped for room \(roomId)")
    }

    // MARK: - Private — Send

    /// Sends call signaling data as an encrypted text message through the timeline.
    /// Format: "ZYNA_CALL:m.call.answer:{json_data}"
    private func sendViaTimeline<T: Encodable>(type: String, content: T) async throws {
        guard let innerJSON = CallEventJSON.encode(content) else { return }
        let body = "\(Self.signalingPrefix)\(type):\(innerJSON)"
        await timelineService?.sendCallSignaling(body)
    }

    // MARK: - Private — Receive

    private func processItems(_ items: [TimelineItem]) {
        for item in items {
            processTimelineItem(item)
        }
    }

    private func processTimelineItem(_ item: TimelineItem) {
        guard let event = item.asEvent() else { return }

        // Skip own events
        guard !event.isOwn else { return }

        // Deduplicate
        let itemId = item.uniqueId().id
        guard !processedEventIds.contains(itemId) else { return }
        processedEventIds.insert(itemId)

        switch event.content {
        case .callInvite:
            handleCallInvite(event)

        case .msgLike(let msgContent):
            // Check for signaling messages in text content
            if case .message(let message) = msgContent.kind,
               case .text(let text) = message.msgType,
               text.body.hasPrefix(Self.signalingPrefix) {
                handleTextSignaling(text.body)
            }

        case .failedToParseMessageLike(let eventType, _) where eventType.hasPrefix("m.call."):
            handleLegacyCallEvent(event, eventType: eventType)

        default:
            break
        }
    }

    // MARK: - Parse Incoming Call Events

    /// Handle native m.call.invite (delivered as .callInvite by SDK)
    private func handleCallInvite(_ event: EventTimelineItem) {
        guard let contentDict = extractEventContent(event) else {
            callLog("Failed to extract content from call invite")
            return
        }

        guard let content = CallEventJSON.decode(CallInviteContent.self, from: contentDict) else {
            callLog("Failed to decode CallInviteContent from raw JSON")
            return
        }

        callLog("Received call invite: callId=\(content.callId), sdp=\(content.offer.sdp.count) bytes")
        incomingEventSubject.send(.invite(content))
    }

    /// Handle call signaling encoded in text message body.
    /// Format: "ZYNA_CALL:m.call.answer:{json_data}"
    private func handleTextSignaling(_ body: String) {
        let payload = String(body.dropFirst(Self.signalingPrefix.count))

        // Split into type and JSON data at the first ":"
        guard let colonIndex = payload.firstIndex(of: ":") else { return }
        let type = String(payload[payload.startIndex..<colonIndex])
        let jsonString = String(payload[payload.index(after: colonIndex)...])

        callLog("Received signaling via text: \(type)")
        parseCallData(type: type, jsonString: jsonString)
    }

    /// Handle legacy/failedToParse call events (from other clients using VoIP v1, etc.)
    private func handleLegacyCallEvent(_ event: EventTimelineItem, eventType: String) {
        guard let contentDict = extractEventContent(event) else { return }
        callLog("Parsed legacy call event type: \(eventType)")
        parseCallData(type: eventType, dict: contentDict)
    }

    // MARK: - Shared Parsing

    private func parseCallData(type: String, jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        parseCallData(type: type, dict: dict)
    }

    private func parseCallData(type: String, dict: [String: Any]) {
        switch type {
        case "m.call.answer":
            guard let content = CallEventJSON.decode(CallAnswerContent.self, from: dict) else { return }
            callLog("Received call answer: callId=\(content.callId)")
            incomingEventSubject.send(.answer(content))

        case "m.call.candidates":
            guard let content = CallEventJSON.decode(CallCandidatesContent.self, from: dict) else { return }
            callLog("Received ICE candidates: callId=\(content.callId), count=\(content.candidates.count)")
            incomingEventSubject.send(.candidates(content))

        case "m.call.hangup":
            guard let content = CallEventJSON.decode(CallHangupContent.self, from: dict) else { return }
            callLog("Received call hangup: callId=\(content.callId)")
            incomingEventSubject.send(.hangup(content))

        default:
            break
        }
    }

    // MARK: - Raw JSON Extraction

    private func extractEventContent(_ event: EventTimelineItem) -> [String: Any]? {
        let debugInfo = event.lazyProvider.debugInfo()
        guard let json = debugInfo.originalJson,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentDict = dict["content"] as? [String: Any] else { return nil }
        return contentDict
    }
}
