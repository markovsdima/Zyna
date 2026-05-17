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

enum OutgoingSendFailureReason: Equatable {
    case ownDeviceVerificationRequired
    case recipientIdentityVerificationRequired

    static func fromQueueWedgeError(_ error: QueueWedgeError) -> OutgoingSendFailureReason? {
        switch error {
        case .crossVerificationRequired:
            return .ownDeviceVerificationRequired
        case .insecureDevices, .identityViolations:
            return .recipientIdentityVerificationRequired
        default:
            return nil
        }
    }
}

struct OutgoingSendFailureContext: Equatable {
    let reason: OutgoingSendFailureReason
    let affectedUserIds: [String]
    let insecureDevicesByUserId: [String: [String]]

    static func reasonOnly(_ reason: OutgoingSendFailureReason) -> OutgoingSendFailureContext {
        OutgoingSendFailureContext(
            reason: reason,
            affectedUserIds: [],
            insecureDevicesByUserId: [:]
        )
    }

    static func fromQueueWedgeError(_ error: QueueWedgeError) -> OutgoingSendFailureContext? {
        switch error {
        case .crossVerificationRequired:
            return .reasonOnly(.ownDeviceVerificationRequired)
        case .identityViolations(let users):
            return OutgoingSendFailureContext(
                reason: .recipientIdentityVerificationRequired,
                affectedUserIds: users.sorted(),
                insecureDevicesByUserId: [:]
            )
        case .insecureDevices(let userDeviceMap):
            let normalized = userDeviceMap.mapValues { $0.sorted() }
            return OutgoingSendFailureContext(
                reason: .recipientIdentityVerificationRequired,
                affectedUserIds: normalized.keys.sorted(),
                insecureDevicesByUserId: normalized
            )
        default:
            return nil
        }
    }

    static func fromError(_ error: Error) -> OutgoingSendFailureContext? {
        let errorText = [
            String(reflecting: error),
            String(describing: error),
            (error as NSError).localizedDescription
        ]
        .joined(separator: "\n")
        .lowercased()

        if containsAny(
            [
                "crosssigningnotsetup",
                "cross signing not setup",
                "cross-signing has not been configured",
                "sendingfromunverifieddevice",
                "sending from unverified device",
                "deviceverificationrequired",
                "current device has not been cross-signed",
                "not been cross-signed by our own identity"
            ],
            in: errorText
        ) {
            return .reasonOnly(.ownDeviceVerificationRequired)
        }

        if containsAny(
            [
                "verifieduserchangedidentity",
                "verified user changed identity",
                "changed their identity",
                "verifieduserhasunsigneddevice",
                "verified user has unsigned device",
                "unsigned device",
                "senderidentitynottrusted"
            ],
            in: errorText
        ) {
            return .reasonOnly(.recipientIdentityVerificationRequired)
        }

        return nil
    }

    private static func containsAny(_ needles: [String], in haystack: String) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

struct OutgoingDispatchReceipt {
    let acceptedByTransport: Bool
    let transactionId: String?
    let eventId: String?
    let failureContext: OutgoingSendFailureContext?
    let retryableTransportFailure: Bool

    static let failed = OutgoingDispatchReceipt(
        acceptedByTransport: false,
        transactionId: nil,
        eventId: nil,
        failureContext: nil,
        retryableTransportFailure: false
    )

    static func accepted(
        transactionId: String?,
        eventId: String? = nil
    ) -> OutgoingDispatchReceipt {
        OutgoingDispatchReceipt(
            acceptedByTransport: true,
            transactionId: transactionId,
            eventId: eventId,
            failureContext: nil,
            retryableTransportFailure: false
        )
    }

    static func rejected(reason: OutgoingSendFailureReason?) -> OutgoingDispatchReceipt {
        .rejected(context: reason.map(OutgoingSendFailureContext.reasonOnly))
    }

    static func rejected(
        context: OutgoingSendFailureContext?,
        retryableTransportFailure: Bool = false
    ) -> OutgoingDispatchReceipt {
        OutgoingDispatchReceipt(
            acceptedByTransport: false,
            transactionId: nil,
            eventId: nil,
            failureContext: context,
            retryableTransportFailure: retryableTransportFailure
        )
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

    private let room: Room
    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?
    private var roomAccountDataHandle: TaskHandle?

    init(room: Room) {
        self.room = room
    }

    var hasLiveTimeline: Bool { timeline != nil }

    func prepareDirectRawTextTransactionId(
        replyEventId: String?,
        existingTransactionId: String? = nil
    ) -> String? {
        DirectRawTextSender.prepareTransactionId(
            replyEventId: replyEventId,
            existingTransactionId: existingTransactionId
        )
    }

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
        let directRawTransactionId = extractDirectRawTransactionId(from: event)
        let transactionId: String? = {
            if case .transactionId(let id) = event.eventOrTransactionId {
                return id
            }
            return directRawTransactionId
        }()
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
            transactionId: transactionId,
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

    private static func extractDirectRawTransactionId(from event: EventTimelineItem) -> String? {
        guard event.isOwn,
              let rawJSON = event.lazyProvider.debugInfo().originalJson,
              let data = rawJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [String: Any],
              let transactionId = content[DirectRawTextSender.transactionIdContentKey] as? String,
              !transactionId.isEmpty
        else {
            return nil
        }
        return transactionId
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
        if let formattedBody = content["formatted_body"] as? String {
            return formattedBody
        }
        if let newContent = content["m.new_content"] as? [String: Any] {
            return newContent["formatted_body"] as? String
        }
        return nil
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
            case .audio: return String(localized: "Voice message")
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
            case .unableToDecrypt(let message):
                logTimeline("UTD: eventId=\(event.eventOrTransactionId) sender=\(event.sender) \(describeEncryptedMessage(message))")
                return .text(body: String(localized: "Unable to decrypt message"))
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
                thumbnailSource: content.info?.thumbnailSource,
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

    private static func describeEncryptedMessage(_ message: EncryptedMessage) -> String {
        switch message {
        case .olmV1Curve25519AesSha2(let senderKey):
            return "algorithm=olmV1Curve25519AesSha2 senderKey=\(senderKey)"
        case .megolmV1AesSha2(let sessionId, let cause):
            return "algorithm=megolmV1AesSha2 sessionId=\(sessionId) cause=\(cause)"
        case .unknown:
            return "algorithm=unknown"
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
            await handleMatrixTransportError(error)
        }

        await MainActor.run { isPaginatingSubject.send(false) }
    }

    private func handleMatrixTransportError(_ error: Error) async {
        await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
    }

    private static func isLikelyVideoFile(filename: String, mimetype: String?) -> Bool {
        if mimetype?.lowercased().hasPrefix("video/") == true { return true }
        guard let type = UTType(filenameExtension: (filename as NSString).pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// Send call signaling data through the timeline's encrypted
    /// send pipeline, wrapped in a Zyna HTML span carrier.
    func sendCallSignaling(_ attrs: ZynaMessageAttributes) async throws {
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
            await handleMatrixTransportError(error)
            throw error
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

private final class ZynaTimelineListener: TimelineListener {
    private let handler: @Sendable ([TimelineDiff]) -> Void

    init(handler: @escaping @Sendable ([TimelineDiff]) -> Void) {
        self.handler = handler
    }

    func onUpdate(diff: [TimelineDiff]) {
        handler(diff)
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
