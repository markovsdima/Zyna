//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

private let logCall = ScopedLog(.call)

// MARK: - Call Signaling Service

/// Handles sending and receiving call signaling events for VoIP.
/// Sends m.call.invite natively (SDK delivers it as .callInvite).
/// Sends answer/candidates/hangup via the Zyna HTML span carrier
/// (`data-zyna` attribute with `callSignal` payload) through the
/// timeline's encrypted send pipeline.
/// Receives timeline items from TimelineService (not its own listener).
final class CallSignalingService {

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
        logCall("Signaling subscribed to TimelineService for room \(roomId)")
    }

    // MARK: - Send Events

    func sendInvite(_ content: CallInviteContent) async throws {
        guard let json = CallEventJSON.encode(content) else {
            logCall("Failed to encode call invite")
            return
        }
        // Send as native m.call.invite — SDK delivers as .callInvite in timeline
        try await room.sendRaw(eventType: "m.call.invite", content: json)
        logCall("Sent m.call.invite (callId: \(content.callId))")
    }

    func sendAnswer(_ content: CallAnswerContent) async throws {
        try await sendViaTimeline(type: "m.call.answer", content: content)
        logCall("Sent m.call.answer (callId: \(content.callId))")
    }

    func sendCandidates(_ content: CallCandidatesContent) async throws {
        try await sendViaTimeline(type: "m.call.candidates", content: content)
        logCall("Sent m.call.candidates (callId: \(content.callId), count: \(content.candidates.count))")
    }

    func sendHangup(_ content: CallHangupContent) async throws {
        try await sendViaTimeline(type: "m.call.hangup", content: content)
        logCall("Sent m.call.hangup (callId: \(content.callId))")
    }

    // MARK: - Stop

    func stop() {
        cancellables.removeAll()
        timelineService = nil
        logCall("Signaling stopped for room \(roomId)")
    }

    // MARK: - Private — Send

    /// Sends call signaling data as a Zyna-attributed message through
    /// the timeline. The signaling payload rides in the hidden
    /// `<span data-zyna="...">` carrier; `body` shows a neutral
    /// placeholder for foreign clients.
    private func sendViaTimeline<T: Encodable>(type: String, content: T) async throws {
        guard let payload = CallEventJSON.encode(content) else { return }
        let attrs = ZynaMessageAttributes(
            callSignal: CallSignalData(type: type, payload: payload)
        )
        await timelineService?.sendCallSignaling(attrs)
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

        case .msgLike:
            let attrs = TimelineService.extractZynaAttributes(from: event)
            if let signal = attrs.callSignal {
                handleSpanSignaling(signal)
            }

        default:
            break
        }
    }

    // MARK: - Parse Incoming Call Events

    /// Handle native m.call.invite (delivered as .callInvite by SDK)
    private func handleCallInvite(_ event: EventTimelineItem) {
        guard let contentDict = extractEventContent(event) else {
            logCall("Failed to extract content from call invite")
            return
        }

        guard let content = CallEventJSON.decode(CallInviteContent.self, from: contentDict) else {
            logCall("Failed to decode CallInviteContent from raw JSON")
            return
        }

        logCall("Received call invite: callId=\(content.callId), sdp=\(content.offer.sdp.count) bytes")
        incomingEventSubject.send(.invite(content))
    }

    /// Handle call signaling from Zyna span carrier.
    private func handleSpanSignaling(_ signal: CallSignalData) {
        logCall("Received signaling via span: \(signal.type)")
        parseCallData(type: signal.type, jsonString: signal.payload)
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
            logCall("Received call answer: callId=\(content.callId)")
            incomingEventSubject.send(.answer(content))

        case "m.call.candidates":
            guard let content = CallEventJSON.decode(CallCandidatesContent.self, from: dict) else { return }
            logCall("Received ICE candidates: callId=\(content.callId), count=\(content.candidates.count)")
            incomingEventSubject.send(.candidates(content))

        case "m.call.hangup":
            guard let content = CallEventJSON.decode(CallHangupContent.self, from: dict) else { return }
            logCall("Received call hangup: callId=\(content.callId)")
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
