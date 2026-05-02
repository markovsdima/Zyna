//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Combine
import UniformTypeIdentifiers
import MatrixRustSDK
import GRDB

private let logTimeline = ScopedLog(.timeline)
private let logMediaGroup = ScopedLog(.media, prefix: "[MediaGroup]")
private let logVideoTimeline = ScopedLog(.video, prefix: "[VideoTimeline]")
private let logVideoQueue = ScopedLog(.video, prefix: "[VideoQueue]")

struct OutgoingDispatchReceipt {
    let acceptedByTransport: Bool
    let transactionId: String?

    static let failed = OutgoingDispatchReceipt(
        acceptedByTransport: false,
        transactionId: nil
    )

    static func accepted(transactionId: String?) -> OutgoingDispatchReceipt {
        OutgoingDispatchReceipt(acceptedByTransport: true, transactionId: transactionId)
    }
}

// MARK: - Timeline Service

final class TimelineService {

    let isPaginatingSubject = CurrentValueSubject<Bool, Never>(false)
    let rawTimelineItemsSubject = PassthroughSubject<[TimelineItem], Never>()

    /// Raw SDK diffs forwarded to the diff batcher.
    var onDiffs: (([TimelineDiff]) -> Void)?

    /// Timestamp of the newest own message read by someone else.
    var onReadCursor: ((TimeInterval) -> Void)?

    /// Event acknowledged by the current user's own fully-read marker.
    var onOwnFullyReadMarker: ((String) -> Void)?

    /// Room-local send queue updates used to bind outgoing envelopes.
    /// The Bool indicates whether the outgoing envelope store changed.
    var onSendQueueUpdate: ((RoomSendQueueUpdate, Bool) -> Void)?

    private let room: Room
    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?
    private var sendQueueListenerHandle: TaskHandle?
    private var roomAccountDataHandle: TaskHandle?
    private let localEventTransactionBroker = LocalEventTransactionBroker()

    init(room: Room) {
        self.room = room
    }

    var hasLiveTimeline: Bool { timeline != nil }

    // MARK: - Start

    func startListening(subscribeForSync: Bool = true) async {
        do {
            // Subscribe room for full sliding sync delivery (live events)
            if subscribeForSync {
                try? await MatrixClientService.shared.roomListService?.subscribeToRooms(roomIds: [room.id()])
            }

            let timeline = try await room.timeline()
            self.timeline = timeline

            let listener = ZynaTimelineListener { [weak self] diffs in
                self?.handleDiffs(diffs)
            }
            self.listenerHandle = await timeline.addListener(listener: listener)

            let sendQueueListener = ZynaSendQueueListener { [weak self] update in
                self?.handleSendQueueUpdate(update)
            }
            self.sendQueueListenerHandle = try await room.subscribeToSendQueueUpdates(
                listener: sendQueueListener
            )

            if let client = MatrixClientService.shared.client {
                let roomAccountDataListener = ZynaRoomAccountDataListener { [weak self] event, roomId in
                    self?.handleRoomAccountDataEvent(event, roomId: roomId)
                }
                self.roomAccountDataHandle = try client.observeRoomAccountDataEvent(
                    roomId: room.id(),
                    eventType: .fullyRead,
                    listener: roomAccountDataListener
                )
            }

            logTimeline("Timeline listener started for room \(room.id())")
        } catch {
            logTimeline("Failed to start timeline: \(error)")
        }
    }

    // MARK: - Handle Diffs

    private func handleDiffs(_ diffs: [TimelineDiff]) {
        var allItems: [TimelineItem] = []

        for diff in diffs {
            switch diff {
            case .append(let items):
                allItems.append(contentsOf: items)
            case .pushBack(let item):
                allItems.append(item)
            case .pushFront(let item):
                allItems.append(item)
            case .insert(_, let item):
                allItems.append(item)
            case .set(_, let item):
                allItems.append(item)
            case .reset(let items):
                allItems.append(contentsOf: items)
            default:
                break
            }
        }

        if !allItems.isEmpty {
            rawTimelineItemsSubject.send(allItems)
        }

        // Extract read cursor: the timestamp of the newest own message
        // that has a read receipt from someone else.
        var readCursorTimestamp: TimeInterval?
        for item in allItems {
            guard let event = item.asEvent() else { continue }
            let timestamp = TimeInterval(event.timestamp) / 1000

            if event.isOwn {
                let hasOtherReceipt = event.readReceipts.contains { $0.key != event.sender }
                if hasOtherReceipt {
                    if readCursorTimestamp == nil || timestamp > readCursorTimestamp! {
                        readCursorTimestamp = timestamp
                    }
                }
            }
        }

        // Forward raw diffs + read cursor to the batcher
        onDiffs?(diffs)
        if let cursor = readCursorTimestamp {
            onReadCursor?(cursor)
        }

        logTimeline("Timeline diffs forwarded: \(diffs.count) diffs")
    }

    private func handleRoomAccountDataEvent(_ event: RoomAccountDataEvent, roomId: String) {
        guard roomId == room.id() else { return }

        switch event {
        case .fullyReadEvent(let eventId):
            onOwnFullyReadMarker?(eventId)
        default:
            break
        }
    }

    private func handleSendQueueUpdate(_ update: RoomSendQueueUpdate) {
        switch update {
        case .newLocalEvent(let transactionId):
            logMediaGroup("sendQueue newLocalEvent tx=\(transactionId)")
            logVideoQueue("newLocalEvent tx=\(transactionId)")
        case .cancelledLocalEvent(let transactionId):
            logMediaGroup("sendQueue cancelled tx=\(transactionId)")
            logVideoQueue("cancelled tx=\(transactionId)")
        case .replacedLocalEvent(let transactionId):
            logMediaGroup("sendQueue replaced tx=\(transactionId)")
            logVideoQueue("replaced tx=\(transactionId)")
        case .sendError(let transactionId, let error, let isRecoverable):
            logMediaGroup("sendQueue error tx=\(transactionId) recoverable=\(isRecoverable) error=\(error)")
            logVideoQueue(
                "error tx=\(transactionId) recoverable=\(isRecoverable) errorType=\(String(describing: type(of: error))) error=\(error)"
            )
        case .retryEvent(let transactionId):
            logMediaGroup("sendQueue retry tx=\(transactionId)")
            logVideoQueue("retry tx=\(transactionId)")
        case .sentEvent(let transactionId, let eventId):
            logMediaGroup("sendQueue sent tx=\(transactionId) event=\(eventId)")
            logVideoQueue("sent tx=\(transactionId) event=\(eventId)")
        case .mediaUpload(let relatedTo, let file, let index, _):
            if let file {
                logMediaGroup("sendQueue mediaUpload tx=\(relatedTo) index=\(index) url=\(file.url())")
                logVideoQueue("mediaUpload tx=\(relatedTo) index=\(index) url=\(file.url())")
            } else {
                logMediaGroup("sendQueue mediaUpload progress tx=\(relatedTo) index=\(index)")
                logVideoQueue("mediaUpload progress tx=\(relatedTo) index=\(index)")
            }
        }

        if case .newLocalEvent(let transactionId) = update {
            let broker = localEventTransactionBroker
            let callback = onSendQueueUpdate
            Task {
                if let bindingToken = await broker.yield(transactionId) {
                    let didBind = OutgoingEnvelopeService.shared.bindReservedTransaction(
                        bindingToken: bindingToken,
                        transactionId: transactionId
                    )
                    if didBind {
                        DispatchQueue.main.async {
                            callback?(update, true)
                        }
                    }
                }
            }
        }

        let didMutateOutgoingEnvelopes = OutgoingEnvelopeService.shared.handleSendQueueUpdate(
            roomId: room.id(),
            update: update
        )

        guard didMutateOutgoingEnvelopes || Self.shouldNotifySendQueueObserver(update) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onSendQueueUpdate?(update, didMutateOutgoingEnvelopes)
        }
    }

    private static func shouldNotifySendQueueObserver(_ update: RoomSendQueueUpdate) -> Bool {
        switch update {
        case .sentEvent, .sendError, .cancelledLocalEvent:
            return true
        default:
            return false
        }
    }

    // MARK: - Map SDK Item -> ChatMessage

    static func mapTimelineItem(_ item: TimelineItem) -> ChatMessage? {
        guard let event = item.asEvent() else { return nil }

        let timestamp = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)

        let senderName: String?
        let senderAvatarUrl: String?
        switch event.senderProfile {
        case .ready(let displayName, _, let avatarUrl):
            senderName = displayName
            senderAvatarUrl = avatarUrl
        default:
            senderName = nil
            senderAvatarUrl = nil
        }

        guard let content = contentFromEvent(event) else { return nil }

        let eventId: String? = {
            if case .eventId(let id) = event.eventOrTransactionId {
                return id
            }
            return nil
        }()

        let reactions = buildReactions(from: event)
        let replyInfo = buildReplyInfo(from: event)
        let zynaAttributes = extractZynaAttributes(from: event)
        let isEdited = messageContentIsEdited(from: event)
        let editState = messageEditState(from: event, isEdited: isEdited)

        let itemIdentifier: ChatItemIdentifier? = {
            switch event.eventOrTransactionId {
            case .eventId(let id): return .eventId(id)
            case .transactionId(let id): return .transactionId(id)
            }
        }()

        return ChatMessage(
            id: item.uniqueId().id,
            eventId: eventId,
            transactionId: {
                guard case .transactionId(let id) = event.eventOrTransactionId else { return nil }
                return id
            }(),
            itemIdentifier: itemIdentifier,
            senderId: event.sender,
            senderDisplayName: senderName,
            senderAvatarUrl: senderAvatarUrl,
            isOutgoing: event.isOwn,
            timestamp: timestamp,
            content: content,
            reactions: reactions,
            replyInfo: replyInfo,
            isEditable: event.isEditable,
            isEdited: isEdited,
            isEditPending: editState.isPending,
            isEditFailed: false,
            latestEditEventId: editState.eventId,
            zynaAttributes: zynaAttributes,
            sendStatus: "synced"
        )
    }

    private static func messageContentIsEdited(from event: EventTimelineItem) -> Bool {
        guard case .msgLike(let msgContent) = event.content,
              case .message(let message) = msgContent.kind
        else {
            return false
        }
        return message.isEdited
    }

    private struct MessageEditState {
        let isPending: Bool
        let eventId: String?
    }

    private static func messageEditState(from event: EventTimelineItem, isEdited: Bool) -> MessageEditState {
        guard isEdited,
              let latestEditJSON = event.lazyProvider.debugInfo().latestEditJson
        else {
            return MessageEditState(isPending: false, eventId: nil)
        }
        let eventId = rawEventServerEventId(latestEditJSON)
        return MessageEditState(isPending: eventId == nil, eventId: eventId)
    }

    private static func rawEventServerEventId(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventId = root["event_id"] as? String,
              eventId.hasPrefix("$")
        else {
            return nil
        }
        return eventId
    }

    /// Extracts Zyna-specific attributes embedded in the event's
    /// `formatted_body` HTML. Returns empty attributes for non-text
    /// content or when no carrier span is present.
    static func extractZynaAttributes(from event: EventTimelineItem) -> ZynaMessageAttributes {
        guard case .msgLike(let msgContent) = event.content,
              case .message(let message) = msgContent.kind
        else { return ZynaMessageAttributes() }

        // For media types: check formattedCaption in raw JSON
        // (SDK serialises formattedCaption into the same formatted_body field)
        switch message.msgType {
        case .image, .audio, .file, .video:
            if let rawJSON = event.lazyProvider.debugInfo().originalJson,
               let formatted = Self.extractFormattedBodyFromRawEvent(rawJSON) {
                let attrs = ZynaHTMLCodec.decode(htmlBody: formatted)
                if event.isOwn || attrs.mediaGroup != nil {
                    logMediaGroup(
                        "attrs source=raw item=\(Self.describeItemIdentifier(event.eventOrTransactionId)) own=\(event.isOwn) group=\(Self.describe(attrs.mediaGroup))"
                    )
                }
                return attrs
            }
            if event.isOwn {
                logMediaGroup(
                    "attrs source=none item=\(Self.describeItemIdentifier(event.eventOrTransactionId)) own=true group=none"
                )
            }
            return ZynaMessageAttributes()
        case .text:
            break
        default:
            return ZynaMessageAttributes()
        }

        // Text messages: extract from formatted_body
        if let rawJSON = event.lazyProvider.debugInfo().originalJson,
           let formatted = Self.extractFormattedBodyFromRawEvent(rawJSON) {
            return ZynaHTMLCodec.decode(htmlBody: formatted)
        }

        if event.isOwn {
            logMediaGroup(
                "attrs source=none item=\(Self.describeItemIdentifier(event.eventOrTransactionId)) own=true group=none"
            )
        }
        return ZynaMessageAttributes()
    }

    private static func extractFormattedBodyFromRawEvent(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [String: Any]
        else { return nil }
        return content["formatted_body"] as? String
    }

    private static func buildReactions(from event: EventTimelineItem) -> [MessageReaction] {
        guard case .msgLike(let msgContent) = event.content else { return [] }
        let currentUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        return msgContent.reactions
            .map { reaction in
                let senders = reaction.senders
                    .map {
                        ReactionSender(
                            userId: $0.senderId,
                            timestamp: TimeInterval($0.timestamp) / 1000
                        )
                    }
                    .sorted { $0.timestamp > $1.timestamp }
                return MessageReaction(
                    key: reaction.key,
                    senders: senders,
                    isOwn: reaction.senders.contains { $0.senderId == currentUserId }
                )
            }
            .sorted { $0.count > $1.count }
    }

    private static func buildReplyInfo(from event: EventTimelineItem) -> ReplyInfo? {
        guard case .msgLike(let msgContent) = event.content,
              let inReplyTo = msgContent.inReplyTo else { return nil }

        let replyEventId = inReplyTo.eventId()
        switch inReplyTo.event() {
        case .ready(let content, let sender, let senderProfile, _, _):
            let name: String?
            if case .ready(let displayName, _, _) = senderProfile {
                name = displayName
            } else {
                name = nil
            }
            let body = bodyFromTimelineContent(content) ?? ""
            return ReplyInfo(eventId: replyEventId, senderId: sender, senderDisplayName: name, body: body)
        default:
            // SDK details not ready — try local GRDB cache
            if let stored = try? DatabaseService.shared.dbQueue.read({ db in
                try StoredMessage.filter(Column("eventId") == replyEventId).fetchOne(db)
            }) {
                return ReplyInfo(
                    eventId: replyEventId,
                    senderId: stored.senderId,
                    senderDisplayName: stored.senderDisplayName,
                    body: stored.contentBody ?? stored.contentType
                )
            }
            return ReplyInfo(eventId: replyEventId, senderId: "", senderDisplayName: nil, body: "")
        }
    }

    private static func bodyFromTimelineContent(_ content: TimelineItemContent) -> String? {
        guard case .msgLike(let msgContent) = content else { return nil }
        switch msgContent.kind {
        case .message(let msg):
            switch msg.msgType {
            case .text(let t): return t.body
            case .image: return "Photo"
            case .video: return "Video"
            case .audio: return "Voice message"
            case .file: return "File"
            case .notice(let t): return t.body
            case .emote(let t): return t.body
            default: return "Message"
            }
        case .redacted: return "Deleted message"
        default: return nil
        }
    }

    private static func currentUserId() -> String? {
        try? MatrixClientService.shared.client?.userId()
    }

    private static func senderDisplayName(from event: EventTimelineItem) -> String {
        if case .ready(let displayName, _, _) = event.senderProfile,
           let displayName,
           !displayName.isEmpty {
            return displayName
        }
        return event.sender
    }

    private static func memberDisplayName(userId: String, displayName: String?) -> String {
        guard let displayName, !displayName.isEmpty else { return userId }
        return displayName
    }

    private static func normalizedReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func membershipEventText(
        userId: String,
        userDisplayName: String?,
        change: MembershipChange?,
        reason: String?,
        event: EventTimelineItem
    ) -> String? {
        guard let change else { return nil }

        let senderIsYou = event.isOwn
        let sender = senderDisplayName(from: event)
        let memberIsYou = userId == currentUserId()
        let member = memberDisplayName(userId: userId, displayName: userDisplayName)
        let reason = normalizedReason(reason)

        switch change {
        case .joined:
            return memberIsYou
                ? String(localized: "You joined the room")
                : String(localized: "\(member) joined the room")
        case .left:
            return memberIsYou
                ? String(localized: "You left the room")
                : String(localized: "\(member) left the room")
        case .banned, .kickedAndBanned:
            if let reason {
                if senderIsYou { return String(localized: "You banned \(member): \(reason)") }
                if memberIsYou { return String(localized: "\(sender) banned you: \(reason)") }
                return String(localized: "\(sender) banned \(member): \(reason)")
            }
            if senderIsYou { return String(localized: "You banned \(member)") }
            if memberIsYou { return String(localized: "\(sender) banned you") }
            return String(localized: "\(sender) banned \(member)")
        case .unbanned:
            if senderIsYou { return String(localized: "You unbanned \(member)") }
            if memberIsYou { return String(localized: "\(sender) unbanned you") }
            return String(localized: "\(sender) unbanned \(member)")
        case .kicked:
            if let reason {
                if senderIsYou { return String(localized: "You removed \(member): \(reason)") }
                if memberIsYou { return String(localized: "\(sender) removed you: \(reason)") }
                return String(localized: "\(sender) removed \(member): \(reason)")
            }
            if senderIsYou { return String(localized: "You removed \(member)") }
            if memberIsYou { return String(localized: "\(sender) removed you") }
            return String(localized: "\(sender) removed \(member)")
        case .invited:
            if senderIsYou { return String(localized: "You invited \(member)") }
            if memberIsYou { return String(localized: "\(sender) invited you") }
            return String(localized: "\(sender) invited \(member)")
        case .invitationAccepted:
            return memberIsYou
                ? String(localized: "You accepted the invitation")
                : String(localized: "\(member) accepted the invitation")
        case .invitationRejected:
            return memberIsYou
                ? String(localized: "You declined the invitation")
                : String(localized: "\(member) declined the invitation")
        case .invitationRevoked:
            if senderIsYou { return String(localized: "You revoked \(member)'s invitation") }
            if memberIsYou { return String(localized: "\(sender) revoked your invitation") }
            return String(localized: "\(sender) revoked \(member)'s invitation")
        case .knocked:
            return memberIsYou
                ? String(localized: "You requested to join")
                : String(localized: "\(member) requested to join")
        case .knockAccepted:
            if senderIsYou { return String(localized: "You accepted \(member)'s join request") }
            if memberIsYou { return String(localized: "\(sender) accepted your join request") }
            return String(localized: "\(sender) accepted \(member)'s join request")
        case .knockRetracted:
            return memberIsYou
                ? String(localized: "You withdrew your join request")
                : String(localized: "\(member) withdrew their join request")
        case .knockDenied:
            if senderIsYou { return String(localized: "You denied \(member)'s join request") }
            if memberIsYou { return String(localized: "\(sender) denied your join request") }
            return String(localized: "\(sender) denied \(member)'s join request")
        case .none, .error, .notImplemented:
            return nil
        }
    }

    private static func profileChangeEventText(
        displayName: String?,
        prevDisplayName: String?,
        avatarUrl: String?,
        prevAvatarUrl: String?,
        event: EventTimelineItem
    ) -> String? {
        let member = senderDisplayName(from: event)
        let memberIsYou = event.isOwn
        let displayNameChanged = displayName != prevDisplayName
        var parts: [String] = []

        if displayNameChanged {
            switch (prevDisplayName, displayName, memberIsYou) {
            case (.some(let previous), .some(let current), true):
                parts.append(String(localized: "You changed your display name from \(previous) to \(current)"))
            case (.some(let previous), .some(let current), false):
                parts.append(String(localized: "\(member) changed their display name from \(previous) to \(current)"))
            case (nil, .some(let current), true):
                parts.append(String(localized: "You set your display name to \(current)"))
            case (nil, .some(let current), false):
                parts.append(String(localized: "\(member) set their display name to \(current)"))
            case (.some(let previous), nil, true):
                parts.append(String(localized: "You removed your display name (\(previous))"))
            case (.some(let previous), nil, false):
                parts.append(String(localized: "\(member) removed their display name (\(previous))"))
            case (nil, nil, _):
                break
            }
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private static func roomStateEventText(
        state: OtherState,
        event: EventTimelineItem
    ) -> String? {
        let sender = senderDisplayName(from: event)
        let senderIsYou = event.isOwn

        switch state {
        case .roomAvatar(url: let url):
            if senderIsYou {
                return url == nil
                    ? String(localized: "You removed the room avatar")
                    : String(localized: "You changed the room avatar")
            }
            return url == nil
                ? String(localized: "\(sender) removed the room avatar")
                : String(localized: "\(sender) changed the room avatar")
        case .roomCreate(federate: _):
            return senderIsYou
                ? String(localized: "You created the room")
                : String(localized: "\(sender) created the room")
        case .roomEncryption:
            return String(localized: "Encryption enabled")
        case .roomName(name: let name):
            if let name, !name.isEmpty {
                return senderIsYou
                    ? String(localized: "You changed the room name to \(name)")
                    : String(localized: "\(sender) changed the room name to \(name)")
            }
            return senderIsYou
                ? String(localized: "You removed the room name")
                : String(localized: "\(sender) removed the room name")
        case .roomPinnedEvents(change: let change):
            switch change {
            case .added:
                return senderIsYou
                    ? String(localized: "You pinned messages")
                    : String(localized: "\(sender) pinned messages")
            case .removed:
                return senderIsYou
                    ? String(localized: "You unpinned messages")
                    : String(localized: "\(sender) unpinned messages")
            case .changed:
                return senderIsYou
                    ? String(localized: "You updated pinned messages")
                    : String(localized: "\(sender) updated pinned messages")
            }
        case .roomThirdPartyInvite(displayName: let displayName):
            guard let displayName, !displayName.isEmpty else { return nil }
            return senderIsYou
                ? String(localized: "You invited \(displayName)")
                : String(localized: "\(sender) invited \(displayName)")
        case .roomTopic(topic: let topic):
            if let topic, !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return senderIsYou
                    ? String(localized: "You changed the room topic to \(topic)")
                    : String(localized: "\(sender) changed the room topic to \(topic)")
            }
            return senderIsYou
                ? String(localized: "You removed the room topic")
                : String(localized: "\(sender) removed the room topic")
        case .roomPowerLevels(events: _, previousEvents: _, users: _, previousUsers: _, thresholds: _, previousThresholds: _):
            return nil
        case .policyRuleRoom,
             .policyRuleServer,
             .policyRuleUser,
             .roomAliases,
             .roomCanonicalAlias,
             .roomGuestAccess,
             .roomHistoryVisibility(historyVisibility: _),
             .roomJoinRules(joinRule: _),
             .roomServerAcl,
             .roomTombstone,
             .spaceChild,
             .spaceParent,
             .custom(eventType: _):
            return nil
        }
    }

    private static func contentFromEvent(_ event: EventTimelineItem) -> ChatMessageContent? {
        // Call events: invite is native SDK, signaling rides in span.
        // CallService writes call events to GRDB directly — skip here.
        switch event.content {
        case .callInvite:
            return nil

        case .roomMembership(userId: let userId, userDisplayName: let userDisplayName, change: let change, reason: let reason):
            guard let text = membershipEventText(
                userId: userId,
                userDisplayName: userDisplayName,
                change: change,
                reason: reason,
                event: event
            ) else {
                return nil
            }
            return .systemEvent(text: text, kind: .membership)

        case .profileChange(displayName: let displayName, prevDisplayName: let prevDisplayName, avatarUrl: let avatarUrl, prevAvatarUrl: let prevAvatarUrl):
            guard let text = profileChangeEventText(
                displayName: displayName,
                prevDisplayName: prevDisplayName,
                avatarUrl: avatarUrl,
                prevAvatarUrl: prevAvatarUrl,
                event: event
            ) else {
                return nil
            }
            return .systemEvent(text: text, kind: .profileChange)

        case .state(stateKey: _, content: let state):
            guard let text = roomStateEventText(state: state, event: event) else {
                return nil
            }
            return .systemEvent(text: text, kind: .roomState)

        case .msgLike(let msgContent):
            let attrs = extractZynaAttributes(from: event)
            if attrs.callSignal != nil { return nil }

            switch msgContent.kind {
            case .message(let messageContent):
                guard let content = contentFromMessageType(messageContent.msgType) else { return nil }
                return content
            case .sticker:
                return .unsupported(typeName: "sticker")
            case .poll:
                return .unsupported(typeName: "poll")
            case .redacted:
                return .redacted
            case .unableToDecrypt:
                logTimeline("UTD: eventId=\(event.eventOrTransactionId) sender=\(event.sender)")
                return .text(body: "Encrypted message")
            case .other:
                return nil
            case .liveLocation(content: _):
                return .unsupported(typeName: "location")
            @unknown default:
                return nil
            }

        default:
            return nil
        }
    }

    private static func contentFromMessageType(_ msgType: MessageType) -> ChatMessageContent? {
        switch msgType {
        case .text(let content):
            // Skip zero-width-space-only bodies — carrier messages
            // (call signaling) that slipped past the span check.
            let visible = content.body.replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if visible.isEmpty { return nil }
            return .text(body: content.body)
        case .image(let content):
            return .image(
                source: content.source,
                width: content.info?.width,
                height: content.info?.height,
                caption: content.caption,
                previewImageData: nil
            )
        case .video(let content):
            logVideoTimeline(
                "receive video filename=\(content.filename) source=\(content.source.url()) thumb=\(content.info?.thumbnailSource?.url() ?? "<nil>") size=\(content.info?.width.map(String.init) ?? "<nil>")x\(content.info?.height.map(String.init) ?? "<nil>") duration=\(content.info?.duration.map { String(format: "%.3f", $0) } ?? "<nil>") bytes=\(content.info?.size.map(String.init) ?? "<nil>")"
            )
            return .video(
                source: content.source,
                thumbnailSource: content.info?.thumbnailSource,
                width: content.info?.width,
                height: content.info?.height,
                duration: content.info?.duration,
                filename: content.filename,
                mimetype: content.info?.mimetype,
                size: content.info?.size,
                caption: content.caption,
                previewThumbnailData: nil
            )
        case .notice(let content):
            return .notice(body: content.body)
        case .emote(let content):
            return .emote(body: content.body)
        case .audio(let content):
            let duration = content.audio?.duration ?? content.info?.duration ?? 0
            let waveform = content.audio?.waveform ?? []
            return .voice(source: content.source, duration: duration, waveform: waveform)
        case .file(let content):
            if Self.isLikelyVideoFile(
                filename: content.filename,
                mimetype: content.info?.mimetype
            ) {
                logVideoTimeline(
                    "receive video-file fallback filename=\(content.filename) source=\(content.source.url()) bytes=\(content.info?.size.map(String.init) ?? "<nil>") mime=\(content.info?.mimetype ?? "<nil>")"
                )
                return .video(
                    source: content.source,
                    thumbnailSource: content.info?.thumbnailSource,
                    width: nil,
                    height: nil,
                    duration: nil,
                    filename: content.filename,
                    mimetype: content.info?.mimetype,
                    size: content.info?.size,
                    caption: content.caption,
                    previewThumbnailData: nil
                )
            }
            return .file(
                source: content.source,
                filename: content.filename,
                mimetype: content.info?.mimetype,
                size: content.info?.size,
                caption: content.caption
            )
        default:
            return .unsupported(typeName: "message")
        }
    }

    // MARK: - Pagination

    func paginateBackwards(numEvents: UInt16 = 20) async {
        guard let timeline, !isPaginatingSubject.value else { return }

        await MainActor.run { isPaginatingSubject.send(true) }

        do {
            try await timeline.paginateBackwards(numEvents: numEvents)
            logTimeline("Paginated backwards successfully")
        } catch {
            logTimeline("Pagination failed: \(error)")
        }

        await MainActor.run { isPaginatingSubject.send(false) }
    }

    // MARK: - Forward

    /// Extract message content suitable for forwarding to another room.
    func extractForwardContent(eventId: String) async -> RoomMessageEventContentWithoutRelation? {
        guard let timeline else { return nil }
        do {
            let event = try await timeline.getEventTimelineItemByEventId(eventId: eventId)
            guard case .msgLike(let msgContent) = event.content,
                  case .message(let message) = msgContent.kind
            else { return nil }
            return timeline.createMessageContent(msgType: message.msgType)
        } catch {
            return nil
        }
    }

    /// Send pre-extracted content (used for forwarding from another room).
    func sendForwardedContent(_ content: RoomMessageEventContentWithoutRelation) async {
        guard let timeline else { return }
        do {
            _ = try await timeline.send(msg: content)
            logTimeline("Forwarded message sent")
        } catch {
            logTimeline("Forward send failed: \(error)")
        }
    }

    /// Forward media by downloading from source and re-uploading
    /// with Zyna attributes in the formattedCaption field.
    @discardableResult
    func forwardMedia(
        source: MediaSource,
        mimetype: String,
        attrs: ZynaMessageAttributes,
        caption: String? = nil,
        bindingToken: String
    ) async -> OutgoingDispatchReceipt {
        guard let timeline,
              let client = MatrixClientService.shared.client
        else { return .failed }

        do {
            let data = try await client.getMediaContent(mediaSource: source)

            let plainCaption = caption ?? "\u{200B}"
            let encoded = ZynaHTMLCodec.encode(
                userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(plainCaption),
                attributes: attrs
            )
            let formattedCaption = FormattedBody(format: .html, body: encoded)

            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + Self.extensionFor(mimetype))
            try data.write(to: tmpURL)

            let fileInfo = FileInfo(
                mimetype: mimetype,
                size: UInt64(data.count),
                thumbnailInfo: nil,
                thumbnailSource: nil
            )
            let params = UploadParameters(
                source: .file(filename: tmpURL.path(percentEncoded: false)),
                caption: plainCaption,
                formattedCaption: formattedCaption,
                mentions: nil,
                inReplyTo: nil
            )
            let transactionId = try await sendWithTransaction(bindingToken: bindingToken) {
                _ = try timeline.sendFile(params: params, fileInfo: fileInfo)
            }
            logTimeline("Forwarded media sent with attributes")

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                try? FileManager.default.removeItem(at: tmpURL)
            }
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("Forward media failed: \(error)")
            return .failed
        }
    }

    @discardableResult
    func forwardVoiceMessage(
        source: MediaSource,
        mimetype: String,
        duration: TimeInterval,
        waveform: [UInt16],
        attrs: ZynaMessageAttributes,
        caption: String? = nil,
        bindingToken: String
    ) async -> OutgoingDispatchReceipt {
        guard let client = MatrixClientService.shared.client else { return .failed }

        do {
            let data = try await client.getMediaContent(mediaSource: source)
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + Self.extensionFor(mimetype))
            try data.write(to: tmpURL)

            let receipt = await sendVoiceMessage(
                url: tmpURL,
                duration: duration,
                waveform: waveform.map { Float($0) / 1024.0 },
                mimetype: mimetype,
                caption: caption,
                zynaAttributes: attrs,
                bindingToken: bindingToken
            )

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                try? FileManager.default.removeItem(at: tmpURL)
            }
            return receipt
        } catch {
            logTimeline("Forward voice failed: \(error)")
            return .failed
        }
    }

    private static func extensionFor(_ mimetype: String) -> String {
        switch mimetype {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mp4", "audio/m4a": return "m4a"
        case "audio/ogg": return "ogg"
        default: return "bin"
        }
    }

    private func sendWithTransaction(
        bindingToken: String,
        timeout: Duration = .seconds(10),
        debugLabel: String? = nil,
        _ operation: @escaping () async throws -> Void
    ) async throws -> String? {
        if let debugLabel {
            logVideoTimeline("sendWithTransaction reserve label=\(debugLabel) token=\(bindingToken)")
        }
        await localEventTransactionBroker.reserveWaiter(token: bindingToken)
        do {
            if let debugLabel {
                logVideoTimeline("sendWithTransaction operation start label=\(debugLabel)")
            }
            try await operation()
            if let debugLabel {
                logVideoTimeline("sendWithTransaction operation returned label=\(debugLabel)")
            }
            let transactionId = await localEventTransactionBroker.awaitTransaction(
                for: bindingToken,
                timeout: timeout
            )
            if let debugLabel {
                logVideoTimeline(
                    "sendWithTransaction waiter done label=\(debugLabel) tx=\(transactionId ?? "<nil>") timeout=\(timeout)"
                )
            }
            return transactionId
        } catch {
            await localEventTransactionBroker.cancel(token: bindingToken)
            if let debugLabel {
                logVideoTimeline(
                    "sendWithTransaction failed label=\(debugLabel) errorType=\(String(describing: type(of: error))) error=\(error)"
                )
            }
            throw error
        }
    }

    // MARK: - Send

    @discardableResult
    func sendMessage(_ text: String, bindingToken: String) async -> OutgoingDispatchReceipt {
        guard let timeline else { return .failed }
        do {
            let transactionId = try await sendWithTransaction(bindingToken: bindingToken) {
                _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: text))
            }
            logTimeline("Message sent")
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("Send failed: \(error)")
            return .failed
        }
    }

    /// Sends a text message with a Zyna-specific HTML carrier that embeds
    /// `ZynaMessageAttributes` (custom color, future checklist, etc.).
    /// The plain `body` remains clean text for foreign clients.
    @discardableResult
    func sendMessage(
        _ text: String,
        zynaAttributes: ZynaMessageAttributes,
        bindingToken: String
    ) async -> OutgoingDispatchReceipt {
        guard let timeline else { return .failed }
        // Foreign clients will show `text` verbatim; Zyna reads the
        // data-zyna span out of formatted_body on receive.
        let htmlBody = ZynaHTMLCodec.encode(
            userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(text),
            attributes: zynaAttributes
        )

        do {
            let transactionId = try await sendWithTransaction(bindingToken: bindingToken) {
                _ = try await timeline.send(msg: messageEventContentFromHtml(
                    body: text, htmlBody: htmlBody
                ))
            }
            logTimeline("Message sent with Zyna attrs")
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("Send failed: \(error)")
            return .failed
        }
    }

    @discardableResult
    func sendReply(
        _ text: String,
        to eventId: String,
        bindingToken: String
    ) async -> OutgoingDispatchReceipt {
        guard let timeline else { return .failed }
        do {
            let transactionId = try await sendWithTransaction(bindingToken: bindingToken) {
                try await timeline.sendReply(
                    msg: messageEventContentFromMarkdown(md: text),
                    eventId: eventId
                )
            }
            logTimeline("Reply sent to \(eventId)")
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("Reply send failed: \(error)")
            return .failed
        }
    }

    @discardableResult
    func editMessage(
        _ text: String,
        itemId: ChatItemIdentifier,
        zynaAttributes: ZynaMessageAttributes
    ) async -> OutgoingDispatchReceipt {
        guard let timeline else { return .failed }
        let bindingToken = UUID().uuidString

        let content: RoomMessageEventContentWithoutRelation
        if zynaAttributes.isEmpty {
            content = messageEventContentFromMarkdown(md: text)
        } else {
            let htmlBody = ZynaHTMLCodec.encode(
                userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(text),
                attributes: zynaAttributes
            )
            content = messageEventContentFromHtml(body: text, htmlBody: htmlBody)
        }

        do {
            let transactionId = try await sendWithTransaction(
                bindingToken: bindingToken
            ) {
                try await timeline.edit(
                    eventOrTransactionId: itemId.toSDK(),
                    newContent: .roomMessage(content: content)
                )
            }
            logTimeline("Edited message \(itemId) tx=\(transactionId ?? "nil")")
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("Edit failed: \(error)")
            return .failed
        }
    }

    @discardableResult
    func sendVoiceMessage(
        url: URL,
        duration: TimeInterval,
        waveform: [Float],
        mimetype: String = "audio/mp4",
        caption: String? = nil,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes(),
        bindingToken: String
    ) async -> OutgoingDispatchReceipt {
        guard let timeline else { return .failed }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let plainCaption: String?
        let formattedCaption: FormattedBody?
        if zynaAttributes.isEmpty {
            plainCaption = caption
            formattedCaption = nil
        } else {
            let visibleCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            let userCaption = (visibleCaption?.isEmpty == false) ? visibleCaption! : "\u{200B}"
            plainCaption = userCaption
            let encoded = ZynaHTMLCodec.encode(
                userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(userCaption),
                attributes: zynaAttributes
            )
            formattedCaption = FormattedBody(format: .html, body: encoded)
        }
        let params = UploadParameters(
            source: .file(filename: url.path),
            caption: plainCaption, formattedCaption: formattedCaption, mentions: nil, inReplyTo: nil
        )
        let audioInfo = AudioInfo(duration: duration, size: fileSize, mimetype: mimetype)
        do {
            let transactionId = try await sendWithTransaction(bindingToken: bindingToken) {
                _ = try timeline.sendVoiceMessage(
                    params: params,
                    audioInfo: audioInfo,
                    waveform: waveform
                )
            }
            logTimeline("Voice message sent, duration=\(String(format: "%.1f", duration))s")
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("Voice send failed: \(error)")
            return .failed
        }
    }

    @discardableResult
    func sendImage(
        imageData: Data,
        width: UInt64,
        height: UInt64,
        caption: String?,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes(),
        replyEventId: String? = nil,
        bindingToken: String
    ) async -> OutgoingDispatchReceipt {
        guard let timeline else { return .failed }

        if let mediaGroup = zynaAttributes.mediaGroup {
            logMediaGroup(
                "sendImage start group=\(Self.describe(mediaGroup)) width=\(width) height=\(height) caption=\(caption ?? "<nil>") reply=\(replyEventId ?? "<nil>")"
            )
        } else {
            logMediaGroup(
                "sendImage start standalone width=\(width) height=\(height) caption=\(caption ?? "<nil>") reply=\(replyEventId ?? "<nil>")"
            )
        }

        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        do { try imageData.write(to: imageURL) } catch {
            logTimeline("Image write to temp failed: \(error)")
            return .failed
        }

        let plainCaption: String?
        let formattedCaption: FormattedBody?
        if zynaAttributes.isEmpty {
            plainCaption = caption
            formattedCaption = nil
        } else {
            let visibleCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            let userCaption = (visibleCaption?.isEmpty == false) ? visibleCaption! : "\u{200B}"
            plainCaption = userCaption
            let encoded = ZynaHTMLCodec.encode(
                userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(userCaption),
                attributes: zynaAttributes
            )
            formattedCaption = FormattedBody(format: .html, body: encoded)
        }

        // sendImage throws InvalidAttachmentData — using sendFile
        // as workaround until SDK issue is resolved.
        let fileInfo = FileInfo(
            mimetype: "image/jpeg", size: UInt64(imageData.count),
            thumbnailInfo: nil, thumbnailSource: nil
        )
        let params = UploadParameters(
            source: .file(filename: imageURL.path(percentEncoded: false)),
            caption: plainCaption, formattedCaption: formattedCaption, mentions: nil, inReplyTo: replyEventId
        )
        do {
            let transactionId = try await sendWithTransaction(bindingToken: bindingToken) {
                _ = try timeline.sendFile(params: params, fileInfo: fileInfo)
            }
            logTimeline("Image sent via sendFile, \(width)×\(height)")
            logMediaGroup(
                "sendImage queued tx=\(transactionId ?? "<nil>") group=\(Self.describe(zynaAttributes.mediaGroup)) localURL=\(imageURL.lastPathComponent)"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                try? FileManager.default.removeItem(at: imageURL)
            }
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("Image send failed: \(error)")
            logMediaGroup("sendImage failed group=\(Self.describe(zynaAttributes.mediaGroup)) error=\(error)")
            return .failed
        }
    }

    @discardableResult
    func sendVideo(
        video: ProcessedVideo,
        caption: String?,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes(),
        replyEventId: String? = nil,
        bindingToken: String
    ) async -> OutgoingDispatchReceipt {
        guard let timeline else { return .failed }
        logVideoTimeline(
            "sendVideo start filename=\(video.filename) bindingToken=\(bindingToken.isEmpty ? "<empty>" : bindingToken) bytes=\(video.size) size=\(video.width)x\(video.height) duration=\(String(format: "%.3f", video.duration)) thumbBytes=\(video.thumbnailSize) caption=\(caption ?? "<nil>") reply=\(replyEventId ?? "<nil>") attrsEmpty=\(zynaAttributes.isEmpty)"
        )
        logVideoTimeline(
            "sendVideo files videoExists=\(FileManager.default.fileExists(atPath: video.videoURL.path)) thumbExists=\(FileManager.default.fileExists(atPath: video.thumbnailURL.path)) videoPath=\(video.videoURL.lastPathComponent) thumbPath=\(video.thumbnailURL.lastPathComponent)"
        )

        let plainCaption: String?
        let formattedCaption: FormattedBody?
        if zynaAttributes.isEmpty {
            plainCaption = caption
            formattedCaption = nil
        } else {
            let visibleCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            let userCaption = (visibleCaption?.isEmpty == false) ? visibleCaption! : "\u{200B}"
            plainCaption = userCaption
            let encoded = ZynaHTMLCodec.encode(
                userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(userCaption),
                attributes: zynaAttributes
            )
            formattedCaption = FormattedBody(format: .html, body: encoded)
        }

        let thumbnailInfo = ThumbnailInfo(
            height: video.thumbnailHeight,
            width: video.thumbnailWidth,
            mimetype: "image/jpeg",
            size: video.thumbnailSize
        )
        let videoInfo = VideoInfo(
            duration: video.duration,
            height: video.height,
            width: video.width,
            mimetype: video.mimetype,
            size: video.size,
            thumbnailInfo: thumbnailInfo,
            thumbnailSource: nil,
            blurhash: video.blurhash
        )
        let params = UploadParameters(
            source: .file(filename: video.videoURL.path(percentEncoded: false)),
            caption: plainCaption,
            formattedCaption: formattedCaption,
            mentions: nil,
            inReplyTo: replyEventId
        )

        do {
            logVideoTimeline(
                "sendVideo sdkCall method=sendVideo source=file videoPath=\(video.videoURL.path(percentEncoded: false)) thumbPath=\(video.thumbnailURL.path(percentEncoded: false)) blurhash=\(video.blurhash != nil ? "true" : "false")"
            )
            let transactionId = try await sendWithTransaction(
                bindingToken: bindingToken,
                debugLabel: "video:\(video.filename)"
            ) {
                let handle = try timeline.sendVideo(
                    params: params,
                    thumbnailSource: .file(filename: video.thumbnailURL.path(percentEncoded: false)),
                    videoInfo: videoInfo
                )
                logVideoTimeline("sendVideo join start filename=\(video.filename)")
                try await handle.join()
                logVideoTimeline("sendVideo join done filename=\(video.filename)")
            }
            logTimeline("Video sent: \(video.filename), \(video.size) bytes")
            logVideoTimeline("sendVideo accepted filename=\(video.filename) tx=\(transactionId ?? "<nil>")")
            Self.cleanupProcessedVideoFiles(video, delay: 10)
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("Video send failed: \(error)")
            logVideoTimeline(
                "sendVideo failed filename=\(video.filename) errorType=\(String(describing: type(of: error))) error=\(error)"
            )
            Self.cleanupProcessedVideoFiles(video)
            return .failed
        }
    }

    private static func cleanupProcessedVideoFiles(_ video: ProcessedVideo, delay: TimeInterval = 0) {
        let videoURL = video.videoURL
        let thumbnailURL = video.thumbnailURL
        let workingDirectoryURL = video.videoURL.deletingLastPathComponent()
        let cleanup = {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            try? FileManager.default.removeItem(at: workingDirectoryURL)
        }

        if delay > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: cleanup)
        } else {
            DispatchQueue.global(qos: .utility).async(execute: cleanup)
        }
    }

    private static func isLikelyVideoFile(filename: String, mimetype: String?) -> Bool {
        if mimetype?.lowercased().hasPrefix("video/") == true { return true }
        guard let type = UTType(filenameExtension: (filename as NSString).pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    @discardableResult
    func sendFile(
        url: URL,
        caption: String? = nil,
        replyEventId: String? = nil,
        bindingToken: String
    ) async -> OutgoingDispatchReceipt {
        guard let timeline else { return .failed }

        let filename = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? UInt64) ?? 0

        let mimetype: String
        if let utType = UTType(filenameExtension: url.pathExtension),
           let preferred = utType.preferredMIMEType {
            mimetype = preferred
        } else {
            mimetype = "application/octet-stream"
        }

        let fileInfo = FileInfo(
            mimetype: mimetype, size: fileSize,
            thumbnailInfo: nil, thumbnailSource: nil
        )
        let params = UploadParameters(
            source: .file(filename: url.path(percentEncoded: false)),
            caption: caption, formattedCaption: nil, mentions: nil, inReplyTo: replyEventId
        )
        do {
            let transactionId = try await sendWithTransaction(bindingToken: bindingToken) {
                _ = try timeline.sendFile(params: params, fileInfo: fileInfo)
            }
            logTimeline("File sent: \(filename), \(fileSize) bytes")
            return .accepted(transactionId: transactionId)
        } catch {
            logTimeline("File send failed: \(error)")
            return .failed
        }
    }

    func redactEvent(_ itemId: ChatItemIdentifier, reason: String? = nil) async throws {
        guard let timeline else { return }
        try await timeline.redactEvent(eventOrTransactionId: itemId.toSDK(), reason: reason)
        logTimeline("Redacted event \(itemId)")
    }

    func toggleReaction(_ key: String, to itemId: ChatItemIdentifier) async {
        guard let timeline else { return }
        do {
            try await timeline.toggleReaction(itemId: itemId.toSDK(), key: key)
            logTimeline("Toggled reaction \(key)")
        } catch {
            logTimeline("Toggle reaction failed: \(error)")
        }
    }

    /// Send call signaling data through the timeline's encrypted
    /// send pipeline, wrapped in a Zyna HTML span carrier.
    func sendCallSignaling(_ attrs: ZynaMessageAttributes) async {
        guard let timeline else { return }
        let body = "\u{200B}"   // zero-width space — invisible in foreign clients
        let htmlBody = ZynaHTMLCodec.encode(
            userHTML: body,
            attributes: attrs
        )
        do {
            _ = try await timeline.send(msg: messageEventContentFromHtml(
                body: body, htmlBody: htmlBody
            ))
            logTimeline("Call signaling sent via span")
        } catch {
            logTimeline("Call signaling send failed: \(error)")
        }
    }

    // MARK: - Read Receipts

    func markAsRead() async {
        do {
            try await timeline?.markAsRead(receiptType: .read)
        } catch {
            logTimeline("markAsRead(.read) failed: \(error)")
        }

        do {
            try await timeline?.markAsRead(receiptType: .fullyRead)
        } catch {
            logTimeline("markAsRead(.fullyRead) failed: \(error)")
        }
    }

    @discardableResult
    func sendReadReceipt(for eventId: String) async -> Bool {
        do {
            try await timeline?.sendReadReceipt(receiptType: .read, eventId: eventId)
        } catch {
            logTimeline("sendReadReceipt(.read) failed event=\(eventId): \(error)")
        }

        do {
            try await timeline?.sendReadReceipt(receiptType: .fullyRead, eventId: eventId)
            return true
        } catch {
            logTimeline("sendReadReceipt(.fullyRead) failed event=\(eventId): \(error)")
            return false
        }
    }

    // MARK: - Cleanup

    func stopListening() {
        listenerHandle?.cancel()
        listenerHandle = nil
        sendQueueListenerHandle?.cancel()
        sendQueueListenerHandle = nil
        roomAccountDataHandle?.cancel()
        roomAccountDataHandle = nil
        timeline = nil
    }

    private static func describe(_ mediaGroup: MediaGroupInfo?) -> String {
        guard let mediaGroup else { return "none" }
        return "\(mediaGroup.id)#\(mediaGroup.index + 1)/\(mediaGroup.total) \(mediaGroup.captionPlacement.rawValue)"
    }

    private static func describeItemIdentifier(_ itemId: EventOrTransactionId) -> String {
        switch itemId {
        case .eventId(let id):
            return "event:\(id)"
        case .transactionId(let id):
            return "txn:\(id)"
        }
    }
}

// MARK: - SDK Listener

private actor LocalEventTransactionBroker {

    private struct Waiter {
        let token: String
        var continuation: CheckedContinuation<String?, Never>?
        var assignedTransactionId: String?
        var didStartAwaiting: Bool
    }

    private var waiters: [Waiter] = []

    func reserveWaiter(token: String) {
        waiters.append(
            Waiter(
                token: token,
                continuation: nil,
                assignedTransactionId: nil,
                didStartAwaiting: false
            )
        )
    }

    func awaitTransaction(for token: String, timeout: Duration = .seconds(2)) async -> String? {
        guard let existingIndex = waiters.firstIndex(where: { $0.token == token }) else {
            return nil
        }

        if let transactionId = waiters[existingIndex].assignedTransactionId {
            waiters.remove(at: existingIndex)
            return transactionId
        }

        return await withCheckedContinuation { continuation in
            guard let index = waiters.firstIndex(where: { $0.token == token }) else {
                continuation.resume(returning: nil)
                return
            }

            waiters[index].didStartAwaiting = true
            waiters[index].continuation = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.timeoutWaiter(token: token)
            }
        }
    }

    func cancel(token: String) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation?.resume(returning: nil)
    }

    func yield(_ transactionId: String) -> String? {
        guard let index = waiters.firstIndex(where: { $0.assignedTransactionId == nil }) else {
            return nil
        }

        if let continuation = waiters[index].continuation {
            let token = waiters[index].token
            waiters.remove(at: index)
            continuation.resume(returning: transactionId)
            return token
        }

        waiters[index].assignedTransactionId = transactionId
        let token = waiters[index].token

        if waiters[index].didStartAwaiting {
            waiters.remove(at: index)
        }

        return token
    }

    private func timeoutWaiter(token: String) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        guard waiters[index].assignedTransactionId == nil,
              let continuation = waiters[index].continuation else {
            return
        }
        waiters[index].continuation = nil
        continuation.resume(returning: nil)
    }
}

private final class ZynaTimelineListener: TimelineListener {
    private let handler: @Sendable ([TimelineDiff]) -> Void

    init(handler: @escaping @Sendable ([TimelineDiff]) -> Void) {
        self.handler = handler
    }

    func onUpdate(diff: [TimelineDiff]) {
        handler(diff)
    }
}

private final class ZynaSendQueueListener: SendQueueListener {
    private let handler: @Sendable (RoomSendQueueUpdate) -> Void

    init(handler: @escaping @Sendable (RoomSendQueueUpdate) -> Void) {
        self.handler = handler
    }

    func onUpdate(update: RoomSendQueueUpdate) {
        handler(update)
    }
}

private final class ZynaRoomAccountDataListener: RoomAccountDataListener {
    private let handler: @Sendable (RoomAccountDataEvent, String) -> Void

    init(handler: @escaping @Sendable (RoomAccountDataEvent, String) -> Void) {
        self.handler = handler
    }

    func onChange(event: RoomAccountDataEvent, roomId: String) {
        handler(event, roomId)
    }
}
