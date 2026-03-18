//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

private let timelineLog = ScopedLog(.timeline)

// MARK: - Timeline Service

final class TimelineService {

    let isPaginatingSubject = CurrentValueSubject<Bool, Never>(false)
    let rawTimelineItemsSubject = PassthroughSubject<[TimelineItem], Never>()

    /// Raw SDK diffs forwarded to the coalescer.
    var onDiffs: (([TimelineDiff]) -> Void)?

    private let room: Room
    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?

    init(room: Room) {
        self.room = room
    }

    // MARK: - Start

    func startListening() async {
        do {
            // Subscribe room for full sliding sync delivery (live events)
            try? MatrixClientService.shared.roomListService?.subscribeToRooms(roomIds: [room.id()])

            let timeline = try await room.timeline()
            self.timeline = timeline

            let listener = ZynaTimelineListener { [weak self] diffs in
                self?.handleDiffs(diffs)
            }
            self.listenerHandle = await timeline.addListener(listener: listener)

            timelineLog("Timeline listener started for room \(room.id())")
        } catch {
            timelineLog("Failed to start timeline: \(error)")
        }
    }

    // MARK: - Handle Diffs

    private func handleDiffs(_ diffs: [TimelineDiff]) {
        var allItems: [TimelineItem] = []
        var liveItems: [TimelineItem] = []

        for diff in diffs {
            switch diff.change() {
            case .append:
                if let items = diff.append() {
                    allItems.append(contentsOf: items)
                    liveItems.append(contentsOf: items)
                }
            case .pushBack:
                if let item = diff.pushBack() {
                    allItems.append(item)
                    liveItems.append(item)
                }
            case .pushFront:
                if let item = diff.pushFront() { allItems.append(item) }
            case .insert:
                if let update = diff.insert() { allItems.append(update.item) }
            case .set:
                if let update = diff.set() { allItems.append(update.item) }
            case .reset:
                if let items = diff.reset() { allItems.append(contentsOf: items) }
            default:
                break
            }
        }

        // Only check LIVE events for call invites (not pagination history)
        checkForCallInvite(liveItems)

        // Publish raw items for call signaling (deduplication happens in CallSignalingService)
        if !allItems.isEmpty {
            rawTimelineItemsSubject.send(allItems)
        }

        // Forward raw diffs to the coalescer
        onDiffs?(diffs)

        timelineLog("Timeline diffs forwarded: \(diffs.count) diffs")
    }

    // MARK: - Map SDK Item -> ChatMessage

    static func mapTimelineItem(_ item: TimelineItem) -> ChatMessage? {
        guard let event = item.asEvent() else { return nil }

        // Filter out wrapped call signaling messages
        if isCallSignalingMessage(event) { return nil }

        let timestamp = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)

        let senderName: String?
        switch event.senderProfile {
        case .ready(let displayName, _, _):
            senderName = displayName
        default:
            senderName = nil
        }

        guard let content = contentFromEvent(event) else { return nil }

        let eventId: String? = {
            if case .eventId(let id) = event.eventOrTransactionId {
                return id
            }
            return nil
        }()

        let reactions = buildReactions(from: event)

        let itemIdentifier: ChatItemIdentifier? = {
            switch event.eventOrTransactionId {
            case .eventId(let id): return .eventId(id)
            case .transactionId(let id): return .transactionId(id)
            }
        }()

        return ChatMessage(
            id: item.uniqueId().id,
            eventId: eventId,
            itemIdentifier: itemIdentifier,
            senderId: event.sender,
            senderDisplayName: senderName,
            isOutgoing: event.isOwn,
            timestamp: timestamp,
            content: content,
            reactions: reactions
        )
    }

    private static func buildReactions(from event: EventTimelineItem) -> [MessageReaction] {
        guard case .msgLike(let msgContent) = event.content else { return [] }
        let currentUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        return msgContent.reactions
            .map { reaction in
                MessageReaction(
                    key: reaction.key,
                    count: reaction.senders.count,
                    isOwn: reaction.senders.contains { $0.senderId == currentUserId }
                )
            }
            .sorted { $0.count > $1.count }
    }

    private static func contentFromEvent(_ event: EventTimelineItem) -> ChatMessageContent? {
        guard case .msgLike(let msgContent) = event.content else { return nil }

        switch msgContent.kind {
        case .message(let messageContent):
            return contentFromMessageType(messageContent.msgType)
        case .sticker:
            return .unsupported(typeName: "sticker")
        case .poll:
            return .unsupported(typeName: "poll")
        case .redacted:
            return .redacted
        case .unableToDecrypt:
            return .text(body: "Encrypted message")
        }
    }

    private static func contentFromMessageType(_ msgType: MessageType) -> ChatMessageContent {
        switch msgType {
        case .text(let content):
            return .text(body: content.body)
        case .image(let content):
            return .image(source: content.source, width: content.info?.width, height: content.info?.height, caption: content.caption)
        case .notice(let content):
            return .notice(body: content.body)
        case .emote(let content):
            return .emote(body: content.body)
        case .audio(let content):
            let duration = content.audio?.duration ?? content.info?.duration ?? 0
            let waveform = content.audio?.waveform ?? []
            return .voice(source: content.source, duration: duration, waveform: waveform)
        default:
            return .unsupported(typeName: "message")
        }
    }

    private static func isCallSignalingMessage(_ event: EventTimelineItem) -> Bool {
        guard case .msgLike(let msgContent) = event.content,
              case .message(let message) = msgContent.kind,
              case .text(let text) = message.msgType else { return false }
        return text.body.hasPrefix(CallSignalingService.signalingPrefix)
    }

    // MARK: - Pagination

    func paginateBackwards() async {
        guard let timeline, !isPaginatingSubject.value else { return }

        await MainActor.run { isPaginatingSubject.send(true) }

        do {
            try await timeline.paginateBackwards(numEvents: 20)
            timelineLog("Paginated backwards successfully")
        } catch {
            timelineLog("Pagination failed: \(error)")
        }

        await MainActor.run { isPaginatingSubject.send(false) }
    }

    // MARK: - Send

    func sendMessage(_ text: String) async {
        guard let timeline else { return }
        do {
            try await timeline.send(msg: messageEventContentFromMarkdown(md: text))
            timelineLog("Message sent")
        } catch {
            timelineLog("Send failed: \(error)")
        }
    }

    func sendVoiceMessage(url: URL, duration: TimeInterval, waveform: [UInt16]) async {
        guard let timeline else { return }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let params = UploadParameters(
            source: .file(filename: url.path),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            replyParams: nil,
            useSendQueue: true
        )
        let audioInfo = AudioInfo(duration: duration, size: fileSize, mimetype: "audio/mp4")
        do {
            _ = try timeline.sendVoiceMessage(
                params: params,
                audioInfo: audioInfo,
                waveform: waveform,
                progressWatcher: nil
            )
            timelineLog("Voice message sent, duration=\(String(format: "%.1f", duration))s")
        } catch {
            timelineLog("Voice send failed: \(error)")
        }
    }

    func redactEvent(_ itemId: ChatItemIdentifier, reason: String? = nil) async throws {
        guard let timeline else { return }
        try await timeline.redactEvent(eventOrTransactionId: itemId.toSDK(), reason: reason)
        timelineLog("Redacted event \(itemId)")
    }

    func toggleReaction(_ key: String, to itemId: ChatItemIdentifier) async {
        guard let timeline else { return }
        do {
            try await timeline.toggleReaction(itemId: itemId.toSDK(), key: key)
            timelineLog("Toggled reaction \(key)")
        } catch {
            timelineLog("Toggle reaction failed: \(error)")
        }
    }

    /// Send call signaling data through the timeline's encrypted send pipeline.
    func sendCallSignaling(_ text: String) async {
        guard let timeline else { return }
        do {
            _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: text))
        } catch {
            timelineLog("Call signaling send failed: \(error)")
        }
    }

    // MARK: - Incoming Call Detection

    private func checkForCallInvite(_ items: [TimelineItem]) {
        for item in items {
            guard let event = item.asEvent(),
                  !event.isOwn,
                  case .callInvite = event.content else { continue }

            // Ignore old invites (e.g. from history pagination)
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)
            guard abs(eventTime.timeIntervalSinceNow) < 60 else { continue }

            // Don't trigger if already in a call
            guard !CallService.shared.state.isActive else { continue }

            // Extract callId and SDP from raw event JSON
            let debugInfo = event.lazyProvider.debugInfo()
            guard let json = debugInfo.originalJson,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = dict["content"] as? [String: Any],
                  let callId = content["call_id"] as? String else {
                timelineLog("Call invite detected but failed to extract callId")
                continue
            }

            // Extract SDP offer directly — can't rely on signaling receiving it later
            let offerSDP: String? = {
                if let offer = content["offer"] as? [String: Any],
                   let sdp = offer["sdp"] as? String {
                    return sdp
                }
                return nil
            }()

            let callerName: String? = {
                if case .ready(let name, _, _) = event.senderProfile { return name }
                return nil
            }()

            timelineLog("Incoming call invite detected: callId=\(callId) from \(callerName ?? event.sender), sdp=\(offerSDP?.count ?? 0) bytes")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                CallService.shared.handleIncomingCall(
                    room: self.room,
                    callId: callId,
                    callerName: callerName,
                    offerSDP: offerSDP,
                    timelineService: self
                )
            }

            // Only handle the first invite
            break
        }
    }

    // MARK: - Cleanup

    func stopListening() {
        listenerHandle?.cancel()
        listenerHandle = nil
        timeline = nil
    }
}

// MARK: - SDK Listener

private final class ZynaTimelineListener: TimelineListener {
    private let handler: ([TimelineDiff]) -> Void

    init(handler: @escaping ([TimelineDiff]) -> Void) {
        self.handler = handler
    }

    func onUpdate(diff: [TimelineDiff]) {
        handler(diff)
    }
}
