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

    private let room: Room
    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?
    private var timelineItems: [TimelineItem] = []

    init(room: Room) {
        self.room = room
    }

    // MARK: - Start

    func startListening() async {
        do {
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
        for diff in diffs {
            applySingleDiff(diff)
        }

        let messages = timelineItems.compactMap { Self.mapTimelineItem($0) }

        DispatchQueue.main.async { [weak self] in
            self?.messagesSubject.send(messages)
        }

        timelineLog("Timeline updated: \(messages.count) messages")
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func applySingleDiff(_ diff: TimelineDiff) {
        switch diff.change() {
        case .append:
            if let items = diff.append() {
                timelineItems.append(contentsOf: items)
            }
        case .pushBack:
            if let item = diff.pushBack() {
                timelineItems.append(item)
            }
        case .pushFront:
            if let item = diff.pushFront() {
                timelineItems.insert(item, at: 0)
            }
        case .insert:
            if let update = diff.insert() {
                timelineItems.insert(update.item, at: Int(update.index))
            }
        case .set:
            if let update = diff.set() {
                let idx = Int(update.index)
                if idx < timelineItems.count {
                    timelineItems[idx] = update.item
                }
            }
        case .remove:
            if let index = diff.remove() {
                let idx = Int(index)
                if idx < timelineItems.count {
                    timelineItems.remove(at: idx)
                }
            }
        case .popBack:
            if !timelineItems.isEmpty { timelineItems.removeLast() }
        case .popFront:
            if !timelineItems.isEmpty { timelineItems.removeFirst() }
        case .reset:
            if let items = diff.reset() {
                timelineItems = items
            }
        case .truncate:
            if let length = diff.truncate() {
                timelineItems = Array(timelineItems.prefix(Int(length)))
            }
        case .clear:
            timelineItems = []
        }
    }

    // MARK: - Map SDK Item -> ChatMessage

    private static func mapTimelineItem(_ item: TimelineItem) -> ChatMessage? {
        guard let event = item.asEvent() else { return nil }

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
            return .image(width: content.info?.width, height: content.info?.height, caption: nil)
        case .notice(let content):
            return .notice(body: content.body)
        case .emote(let content):
            return .emote(body: content.body)
        default:
            return .unsupported(typeName: "message")
        }
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
