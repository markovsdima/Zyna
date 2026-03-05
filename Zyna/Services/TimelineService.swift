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

    let messagesSubject = CurrentValueSubject<[ChatMessage], Never>([])
    let isPaginatingSubject = CurrentValueSubject<Bool, Never>(false)
    let rawTimelineItemsSubject = PassthroughSubject<[TimelineItem], Never>()

    private let room: Room
    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?
    private var timelineItems: [TimelineItem] = []

    /// Incrementally maintained ChatMessage array (chronological order).
    private var chatMessages: [ChatMessage] = []

    /// For each timelineItems[i], whether it maps to a ChatMessage.
    private var isMappable: [Bool] = []

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
                self?.applyDiffs(diffs)
            }
            self.listenerHandle = await timeline.addListener(listener: listener)

            timelineLog("Timeline listener started for room \(room.id())")
        } catch {
            timelineLog("Failed to start timeline: \(error)")
        }
    }

    // MARK: - Apply Diffs

    private func applyDiffs(_ diffs: [TimelineDiff]) {
        var allItems: [TimelineItem] = []
        var liveItems: [TimelineItem] = []

        for diff in diffs {
            let change = diff.change()

            switch change {
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

            applySingleDiff(diff)
        }

        // Only check LIVE events for call invites (not pagination history)
        checkForCallInvite(liveItems)

        // Publish raw items for call signaling (deduplication happens in CallSignalingService)
        if !allItems.isEmpty {
            rawTimelineItemsSubject.send(allItems)
        }

        // Safety net: SDK may mutate TimelineItem objects in-place (e.g. decryption)
        // without sending explicit `set` diffs. Re-map to keep chatMessages current.
        let freshMessages = timelineItems.compactMap { Self.mapTimelineItem($0) }
        let structuralChange = freshMessages.count != chatMessages.count
            || zip(freshMessages, chatMessages).contains { $0.id != $1.id }

        if structuralChange {
            chatMessages = freshMessages
            isMappable = timelineItems.map { Self.mapTimelineItem($0) != nil }
        } else if freshMessages != chatMessages {
            chatMessages = freshMessages
        }

        // CurrentValueSubject — consumer coalesces via `for await .values`
        messagesSubject.value = chatMessages

        timelineLog("Timeline updated: \(diffs.count) diffs, \(chatMessages.count) messages")
    }

    // MARK: - Apply Single Diff (maintains chatMessages incrementally)

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func applySingleDiff(_ diff: TimelineDiff) {
        switch diff.change() {

        case .append:
            guard let items = diff.append() else { return }
            for item in items {
                timelineItems.append(item)
                if let msg = Self.mapTimelineItem(item) {
                    chatMessages.append(msg)
                    isMappable.append(true)
                } else {
                    isMappable.append(false)
                }
            }

        case .pushBack:
            guard let item = diff.pushBack() else { return }
            timelineItems.append(item)
            if let msg = Self.mapTimelineItem(item) {
                chatMessages.append(msg)
                isMappable.append(true)
            } else {
                isMappable.append(false)
            }

        case .pushFront:
            guard let item = diff.pushFront() else { return }
            timelineItems.insert(item, at: 0)
            if let msg = Self.mapTimelineItem(item) {
                chatMessages.insert(msg, at: 0)
                isMappable.insert(true, at: 0)
            } else {
                isMappable.insert(false, at: 0)
            }

        case .insert:
            guard let update = diff.insert() else { return }
            let tlIdx = Int(update.index)
            timelineItems.insert(update.item, at: tlIdx)
            if let msg = Self.mapTimelineItem(update.item) {
                let msgIdx = chatMessageIndex(forTimelineIndex: tlIdx)
                chatMessages.insert(msg, at: msgIdx)
                isMappable.insert(true, at: tlIdx)
            } else {
                isMappable.insert(false, at: tlIdx)
            }

        case .set:
            guard let update = diff.set() else { return }
            let tlIdx = Int(update.index)
            guard tlIdx < timelineItems.count else { return }

            let wasMappable = isMappable[tlIdx]
            let oldMsgIdx = wasMappable ? chatMessageIndex(forTimelineIndex: tlIdx) : nil

            timelineItems[tlIdx] = update.item
            let newMsg = Self.mapTimelineItem(update.item)
            let nowMappable = newMsg != nil
            isMappable[tlIdx] = nowMappable

            switch (wasMappable, nowMappable) {
            case (true, true):
                chatMessages[oldMsgIdx!] = newMsg!
            case (false, true):
                let msgIdx = chatMessageIndex(forTimelineIndex: tlIdx)
                chatMessages.insert(newMsg!, at: msgIdx)
            case (true, false):
                chatMessages.remove(at: oldMsgIdx!)
            case (false, false):
                break
            }

        case .remove:
            guard let index = diff.remove() else { return }
            let tlIdx = Int(index)
            guard tlIdx < timelineItems.count else { return }

            if isMappable[tlIdx] {
                let msgIdx = chatMessageIndex(forTimelineIndex: tlIdx)
                chatMessages.remove(at: msgIdx)
            }
            timelineItems.remove(at: tlIdx)
            isMappable.remove(at: tlIdx)

        case .popBack:
            guard !timelineItems.isEmpty else { return }
            if isMappable.last == true {
                chatMessages.removeLast()
            }
            timelineItems.removeLast()
            isMappable.removeLast()

        case .popFront:
            guard !timelineItems.isEmpty else { return }
            if isMappable.first == true {
                chatMessages.removeFirst()
            }
            timelineItems.removeFirst()
            isMappable.removeFirst()

        case .reset:
            if let items = diff.reset() {
                timelineItems = items
            }
            rebuildChatMessages()

        case .truncate:
            if let length = diff.truncate() {
                timelineItems = Array(timelineItems.prefix(Int(length)))
            }
            rebuildChatMessages()

        case .clear:
            timelineItems = []
            chatMessages = []
            isMappable = []
        }
    }

    // MARK: - Helpers

    /// Returns the ChatMessage array index for a given timelineItems index.
    private func chatMessageIndex(forTimelineIndex timelineIndex: Int) -> Int {
        var count = 0
        for i in 0..<timelineIndex {
            if isMappable[i] { count += 1 }
        }
        return count
    }

    /// Full rebuild of chatMessages and isMappable from timelineItems.
    private func rebuildChatMessages() {
        isMappable = timelineItems.map { Self.mapTimelineItem($0) != nil }
        chatMessages = timelineItems.compactMap { Self.mapTimelineItem($0) }
    }

    // MARK: - Map SDK Item -> ChatMessage

    private static func mapTimelineItem(_ item: TimelineItem) -> ChatMessage? {
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

        return ChatMessage(
            id: item.uniqueId().id,
            eventId: eventId,
            senderId: event.sender,
            senderDisplayName: senderName,
            isOutgoing: event.isOwn,
            timestamp: timestamp,
            content: content
        )
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
            return .text(body: "Message deleted")
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
