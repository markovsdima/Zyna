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

// MARK: - Timeline Service

final class TimelineService {

    let isPaginatingSubject = CurrentValueSubject<Bool, Never>(false)
    let rawTimelineItemsSubject = PassthroughSubject<[TimelineItem], Never>()

    /// Raw SDK diffs forwarded to the diff batcher.
    var onDiffs: (([TimelineDiff]) -> Void)?

    /// Timestamp of the newest own message read by someone else.
    var onReadCursor: ((TimeInterval) -> Void)?

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
            try? await MatrixClientService.shared.roomListService?.subscribeToRooms(roomIds: [room.id()])

            let timeline = try await room.timeline()
            self.timeline = timeline

            let listener = ZynaTimelineListener { [weak self] diffs in
                self?.handleDiffs(diffs)
            }
            self.listenerHandle = await timeline.addListener(listener: listener)

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
            guard let event = item.asEvent(), event.isOwn else { continue }
            let hasOtherReceipt = event.readReceipts.contains { $0.key != event.sender }
            if hasOtherReceipt {
                let ts = TimeInterval(event.timestamp) / 1000
                if readCursorTimestamp == nil || ts > readCursorTimestamp! {
                    readCursorTimestamp = ts
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
            senderAvatarUrl: senderAvatarUrl,
            isOutgoing: event.isOwn,
            timestamp: timestamp,
            content: content,
            reactions: reactions,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            sendStatus: "synced"
        )
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
                return ZynaHTMLCodec.decode(htmlBody: formatted)
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

        // Fallback for our own just-sent messages: during the brief
        // window where the local-echo and first sync diffs arrive
        // without the prepared rawJSON, the bubble would flash default
        // blue. Look up the colour we just stashed in the cache.
        guard event.isOwn,
              case .msgLike(let c) = event.content,
              case .message(let m) = c.kind,
              case .text(let t) = m.msgType
        else { return ZynaMessageAttributes() }

        if let cached = OutgoingAttributesCache.shared.peek(
            body: t.body,
            senderId: event.sender
        ) {
            return cached
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

    private static func reasonSuffix(_ reason: String?) -> String {
        guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return ": \(reason)"
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
        let reasonText = reasonSuffix(reason)

        switch change {
        case .joined:
            return memberIsYou ? "You joined the room" : "\(member) joined the room"
        case .left:
            return memberIsYou ? "You left the room" : "\(member) left the room"
        case .banned, .kickedAndBanned:
            if senderIsYou { return "You banned \(member)\(reasonText)" }
            if memberIsYou { return "\(sender) banned you\(reasonText)" }
            return "\(sender) banned \(member)\(reasonText)"
        case .unbanned:
            if senderIsYou { return "You unbanned \(member)" }
            if memberIsYou { return "\(sender) unbanned you" }
            return "\(sender) unbanned \(member)"
        case .kicked:
            if senderIsYou { return "You removed \(member)\(reasonText)" }
            if memberIsYou { return "\(sender) removed you\(reasonText)" }
            return "\(sender) removed \(member)\(reasonText)"
        case .invited:
            if senderIsYou { return "You invited \(member)" }
            if memberIsYou { return "\(sender) invited you" }
            return "\(sender) invited \(member)"
        case .invitationAccepted:
            return memberIsYou ? "You accepted the invitation" : "\(member) accepted the invitation"
        case .invitationRejected:
            return memberIsYou ? "You declined the invitation" : "\(member) declined the invitation"
        case .invitationRevoked:
            if senderIsYou { return "You revoked \(member)'s invitation" }
            if memberIsYou { return "\(sender) revoked your invitation" }
            return "\(sender) revoked \(member)'s invitation"
        case .knocked:
            return memberIsYou ? "You requested to join" : "\(member) requested to join"
        case .knockAccepted:
            if senderIsYou { return "You accepted \(member)'s join request" }
            if memberIsYou { return "\(sender) accepted your join request" }
            return "\(sender) accepted \(member)'s join request"
        case .knockRetracted:
            return memberIsYou ? "You withdrew your join request" : "\(member) withdrew their join request"
        case .knockDenied:
            if senderIsYou { return "You denied \(member)'s join request" }
            if memberIsYou { return "\(sender) denied your join request" }
            return "\(sender) denied \(member)'s join request"
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
        let avatarChanged = avatarUrl != prevAvatarUrl

        var parts: [String] = []

        if displayNameChanged {
            switch (prevDisplayName, displayName, memberIsYou) {
            case (.some(let previous), .some(let current), true):
                parts.append("You changed your display name from \(previous) to \(current)")
            case (.some(let previous), .some(let current), false):
                parts.append("\(member) changed their display name from \(previous) to \(current)")
            case (nil, .some(let current), true):
                parts.append("You set your display name to \(current)")
            case (nil, .some(let current), false):
                parts.append("\(member) set their display name to \(current)")
            case (.some(let previous), nil, true):
                parts.append("You removed your display name (\(previous))")
            case (.some(let previous), nil, false):
                parts.append("\(member) removed their display name (\(previous))")
            case (nil, nil, _):
                break
            }
        }

        if avatarChanged {
            parts.append(memberIsYou ? "You changed your avatar" : "\(member) changed their avatar")
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
                return url == nil ? "You removed the room avatar" : "You changed the room avatar"
            }
            return url == nil ? "\(sender) removed the room avatar" : "\(sender) changed the room avatar"
        case .roomCreate(federate: _):
            return senderIsYou ? "You created the room" : "\(sender) created the room"
        case .roomEncryption:
            return "Encryption enabled"
        case .roomName(name: let name):
            if let name, !name.isEmpty {
                return senderIsYou
                    ? "You changed the room name to \(name)"
                    : "\(sender) changed the room name to \(name)"
            }
            return senderIsYou ? "You removed the room name" : "\(sender) removed the room name"
        case .roomPinnedEvents(change: let change):
            switch change {
            case .added:
                return senderIsYou ? "You pinned messages" : "\(sender) pinned messages"
            case .removed:
                return senderIsYou ? "You unpinned messages" : "\(sender) unpinned messages"
            case .changed:
                return senderIsYou ? "You updated pinned messages" : "\(sender) updated pinned messages"
            }
        case .roomThirdPartyInvite(displayName: let displayName):
            guard let displayName, !displayName.isEmpty else { return nil }
            return senderIsYou ? "You invited \(displayName)" : "\(sender) invited \(displayName)"
        case .roomTopic(topic: let topic):
            if let topic, !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return senderIsYou
                    ? "You changed the room topic to \(topic)"
                    : "\(sender) changed the room topic to \(topic)"
            }
            return senderIsYou ? "You removed the room topic" : "\(sender) removed the room topic"
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
            return .image(source: content.source, width: content.info?.width, height: content.info?.height, caption: content.caption)
        case .notice(let content):
            return .notice(body: content.body)
        case .emote(let content):
            return .emote(body: content.body)
        case .audio(let content):
            let duration = content.audio?.duration ?? content.info?.duration ?? 0
            let waveform = content.audio?.waveform ?? []
            return .voice(source: content.source, duration: duration, waveform: waveform)
        case .file(let content):
            return .file(
                source: content.source,
                filename: content.filename,
                mimetype: content.info?.mimetype,
                size: content.info?.size
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
    func forwardMedia(source: MediaSource, mimetype: String, attrs: ZynaMessageAttributes, caption: String? = nil) async {
        guard let timeline,
              let client = MatrixClientService.shared.client
        else { return }

        do {
            let data = try await client.getMediaContent(mediaSource: source)

            let plainCaption = caption ?? "\u{200B}"
            let encoded = ZynaHTMLCodec.encode(
                userHTML: plainCaption,
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
            _ = try timeline.sendFile(params: params, fileInfo: fileInfo)
            logTimeline("Forwarded media sent with attributes")

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                try? FileManager.default.removeItem(at: tmpURL)
            }
        } catch {
            logTimeline("Forward media failed: \(error)")
        }
    }

    private static func extensionFor(_ mimetype: String) -> String {
        switch mimetype {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "audio/mp4", "audio/m4a": return "m4a"
        case "audio/ogg": return "ogg"
        default: return "bin"
        }
    }

    // MARK: - Send

    func sendMessage(_ text: String) async {
        guard let timeline else { return }
        do {
            try await timeline.send(msg: messageEventContentFromMarkdown(md: text))
            logTimeline("Message sent")
        } catch {
            logTimeline("Send failed: \(error)")
        }
    }

    /// Sends a text message with a Zyna-specific HTML carrier that embeds
    /// `ZynaMessageAttributes` (custom color, future checklist, etc.).
    /// The plain `body` remains clean text for foreign clients.
    func sendMessage(_ text: String, zynaAttributes: ZynaMessageAttributes) async {
        guard let timeline else { return }
        // Foreign clients will show `text` verbatim; Zyna reads the
        // data-zyna span out of formatted_body on receive.
        let htmlBody = ZynaHTMLCodec.encode(
            userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(text),
            attributes: zynaAttributes
        )

        // Optimistic cache so the local echo / pre-rawJSON timeline
        // updates can render the bubble with the right color instead
        // of flashing through the default blue first.
        let senderId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        OutgoingAttributesCache.shared.remember(
            attributes: zynaAttributes,
            body: text,
            senderId: senderId
        )

        do {
            try await timeline.send(msg: messageEventContentFromHtml(
                body: text, htmlBody: htmlBody
            ))
            logTimeline("Message sent with Zyna attrs")
        } catch {
            logTimeline("Send failed: \(error)")
        }
    }

    func sendReply(_ text: String, to eventId: String) async {
        guard let timeline else { return }
        do {
            try await timeline.sendReply(msg: messageEventContentFromMarkdown(md: text), eventId: eventId)
            logTimeline("Reply sent to \(eventId)")
        } catch {
            logTimeline("Reply send failed: \(error)")
        }
    }

    func sendVoiceMessage(url: URL, duration: TimeInterval, waveform: [Float]) async {
        guard let timeline else { return }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let params = UploadParameters(
            source: .file(filename: url.path),
            caption: nil, formattedCaption: nil, mentions: nil, inReplyTo: nil
        )
        let audioInfo = AudioInfo(duration: duration, size: fileSize, mimetype: "audio/mp4")
        do {
            _ = try timeline.sendVoiceMessage(
                params: params, audioInfo: audioInfo, waveform: waveform
            )
            logTimeline("Voice message sent, duration=\(String(format: "%.1f", duration))s")
        } catch {
            logTimeline("Voice send failed: \(error)")
        }
    }

    func sendImage(imageData: Data, width: UInt64, height: UInt64, caption: String?) async {
        guard let timeline else { return }

        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        do { try imageData.write(to: imageURL) } catch {
            logTimeline("Image write to temp failed: \(error)")
            return
        }

        // sendImage throws InvalidAttachmentData — using sendFile
        // as workaround until SDK issue is resolved.
        let fileInfo = FileInfo(
            mimetype: "image/jpeg", size: UInt64(imageData.count),
            thumbnailInfo: nil, thumbnailSource: nil
        )
        let params = UploadParameters(
            source: .file(filename: imageURL.path(percentEncoded: false)),
            caption: caption, formattedCaption: nil, mentions: nil, inReplyTo: nil
        )
        do {
            _ = try timeline.sendFile(params: params, fileInfo: fileInfo)
            logTimeline("Image sent via sendFile, \(width)×\(height)")
        } catch {
            logTimeline("Image send failed: \(error)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            try? FileManager.default.removeItem(at: imageURL)
        }
    }

    func sendFile(url: URL) async {
        guard let timeline else { return }

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
            caption: nil, formattedCaption: nil, mentions: nil, inReplyTo: nil
        )
        do {
            _ = try timeline.sendFile(params: params, fileInfo: fileInfo)
            logTimeline("File sent: \(filename), \(fileSize) bytes")
        } catch {
            logTimeline("File send failed: \(error)")
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
            logTimeline("markAsRead failed: \(error)")
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
