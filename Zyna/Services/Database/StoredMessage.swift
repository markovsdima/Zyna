//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit
import GRDB
import MatrixRustSDK

struct StoredMessage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "storedMessage"

    var id: String
    var roomId: String
    var eventId: String?
    var transactionId: String?
    var senderId: String
    var senderDisplayName: String?
    var senderAvatarUrl: String?
    var isOutgoing: Bool
    var timestamp: TimeInterval
    var contentType: String
    var contentBody: String?
    var contentMediaJSON: String?
    var contentImageWidth: Int64?
    var contentImageHeight: Int64?
    var contentCaption: String?
    var contentVoiceDuration: TimeInterval?
    var contentVoiceWaveform: Data?
    var contentFilename: String?
    var contentMimetype: String?
    var contentFileSize: Int64?
    var contentThumbnailMediaJSON: String?
    var contentVideoWidth: Int64?
    var contentVideoHeight: Int64?
    var contentVideoDuration: TimeInterval?
    var reactionsJSON: String
    var sendStatus: String
    var replyEventId: String?
    var replySenderId: String?
    var replySenderName: String?
    var replyBody: String?
    var isEdited: Bool
    var isEditPending: Bool
    var isEditFailed: Bool
    var latestEditEventId: String?
    var editTransactionId: String?

    var zynaAttributesJSON: String?
}

// MARK: - ChatMessage → StoredMessage

extension StoredMessage {

    init(from msg: ChatMessage, roomId: String) {
        // SDK uniqueId is a sequential number per-timeline, not globally
        // unique. Prefix with roomId to avoid cross-room primary key collisions.
        self.id = "\(roomId):\(msg.id)"
        self.roomId = roomId
        self.senderId = msg.senderId
        self.senderDisplayName = msg.senderDisplayName
        self.senderAvatarUrl = msg.senderAvatarUrl
        self.isOutgoing = msg.isOutgoing
        self.timestamp = msg.timestamp.timeIntervalSince1970
        self.reactionsJSON = Self.encodeReactions(msg.reactions)
        self.sendStatus = msg.sendStatus
        self.isEdited = msg.isEdited
        self.isEditPending = msg.isEditPending
        self.isEditFailed = msg.isEditFailed
        self.latestEditEventId = msg.latestEditEventId
        self.editTransactionId = nil

        switch msg.itemIdentifier {
        case .eventId(let id):
            self.eventId = id
            self.transactionId = msg.transactionId
        case .transactionId(let id):
            self.transactionId = id
            self.eventId = nil
            if msg.sendStatus == "synced" || msg.sendStatus == "read" {
                self.sendStatus = "sending"
            }
        case nil:
            self.eventId = msg.eventId
            self.transactionId = nil
        }

        switch msg.content {
        case .text(let body):
            contentType = "text"
            contentBody = body
        case .image(let source, let width, let height, let caption, _):
            guard let source else {
                assertionFailure("StoredMessage cannot persist image content without a media source")
                contentType = "unsupported"
                contentBody = "pendingOutgoingImage"
                break
            }
            contentType = "image"
            contentMediaJSON = source.toJson()
            contentImageWidth = width.map(Int64.init)
            contentImageHeight = height.map(Int64.init)
            contentCaption = caption
        case .video(let source, let thumbnailSource, let width, let height, let duration, let filename, let mimetype, let size, let caption, _):
            guard let source else {
                assertionFailure("StoredMessage cannot persist video content without a media source")
                contentType = "unsupported"
                contentBody = "pendingOutgoingVideo"
                break
            }
            contentType = "video"
            contentMediaJSON = source.toJson()
            contentThumbnailMediaJSON = thumbnailSource?.toJson()
            contentVideoWidth = width.map(Int64.init)
            contentVideoHeight = height.map(Int64.init)
            contentVideoDuration = duration
            contentFilename = filename
            contentMimetype = mimetype
            contentFileSize = size.map(Int64.init)
            contentCaption = caption
        case .voice(let source, let duration, let waveform):
            guard let source else {
                assertionFailure("StoredMessage cannot persist voice content without a media source")
                contentType = "unsupported"
                contentBody = "pendingOutgoingVoice"
                break
            }
            contentType = "voice"
            contentMediaJSON = source.toJson()
            contentVoiceDuration = duration
            contentVoiceWaveform = waveform.withUnsafeBufferPointer { Data(buffer: $0) }
        case .notice(let body):
            contentType = "notice"
            contentBody = body
        case .emote(let body):
            contentType = "emote"
            contentBody = body
        case .pendingOutgoingMediaBatch:
            contentType = "unsupported"
            contentBody = "pendingOutgoingMediaBatch"
        case .file(let source, let filename, let mimetype, let size, let caption):
            guard let source else {
                assertionFailure("StoredMessage cannot persist file content without a media source")
                contentType = "unsupported"
                contentBody = "pendingOutgoingFile"
                break
            }
            contentType = "file"
            contentMediaJSON = source.toJson()
            contentFilename = filename
            contentMimetype = mimetype
            contentFileSize = size.map(Int64.init)
            contentCaption = caption
        case .callEvent(let type, let callId, let reason):
            contentType = "call"
            contentBody = callId
            contentCaption = type.rawValue
            contentMimetype = reason
        case .systemEvent(let text, let kind):
            contentType = "system"
            contentBody = text
            contentCaption = kind.rawValue
        case .unsupported(let typeName):
            contentType = "unsupported"
            contentBody = typeName
        case .redacted:
            contentType = "redacted"
        }

        if let reply = msg.replyInfo {
            self.replyEventId = reply.eventId
            self.replySenderId = reply.senderId
            self.replySenderName = reply.senderDisplayName
            self.replyBody = reply.body
        }

        self.zynaAttributesJSON = Self.encodeZynaAttributes(msg.zynaAttributes)
    }
}

// MARK: - StoredMessage → ChatMessage

extension StoredMessage {

    func toChatMessage() -> ChatMessage? {
        guard let content = buildContent() else { return nil }

        let itemIdentifier: ChatItemIdentifier?
        if let eventId {
            itemIdentifier = .eventId(eventId)
        } else if let transactionId {
            itemIdentifier = .transactionId(transactionId)
        } else {
            itemIdentifier = nil
        }

        let replyInfo: ReplyInfo?
        if let replyEventId, let replySenderId {
            replyInfo = ReplyInfo(
                eventId: replyEventId,
                senderId: replySenderId,
                senderDisplayName: replySenderName,
                body: replyBody ?? ""
            )
        } else {
            replyInfo = nil
        }

        return ChatMessage(
            id: id,
            eventId: eventId,
            transactionId: transactionId,
            itemIdentifier: itemIdentifier,
            senderId: senderId,
            senderDisplayName: senderDisplayName,
            senderAvatarUrl: senderAvatarUrl,
            isOutgoing: isOutgoing,
            timestamp: Date(timeIntervalSince1970: timestamp),
            content: content,
            reactions: Self.decodeReactions(reactionsJSON),
            replyInfo: replyInfo,
            isEditable: Self.isStoredMessageEditable(
                content: content,
                isOutgoing: isOutgoing,
                eventId: eventId,
                sendStatus: sendStatus
            ),
            isEdited: isEdited,
            isEditPending: isEditPending,
            isEditFailed: isEditFailed,
            latestEditEventId: latestEditEventId,
            zynaAttributes: Self.decodeZynaAttributes(zynaAttributesJSON),
            sendStatus: sendStatus
        )
    }

    private static func isStoredMessageEditable(
        content: ChatMessageContent,
        isOutgoing: Bool,
        eventId: String?,
        sendStatus: String
    ) -> Bool {
        guard isOutgoing,
              eventId?.isEmpty == false
        else {
            return false
        }
        switch sendStatus {
        case "sent", "synced", "read":
            break
        default:
            return false
        }
        if case .text = content {
            return true
        }
        return false
    }

    private func buildContent() -> ChatMessageContent? {
        switch contentType {
        case "text":
            return .text(body: contentBody ?? "")
        case "image":
            guard let json = contentMediaJSON,
                  let source = try? MediaSource.fromJson(json: json) else { return nil }
            return .image(
                source: source,
                width: contentImageWidth.map(UInt64.init),
                height: contentImageHeight.map(UInt64.init),
                caption: contentCaption,
                previewImageData: nil
            )
        case "video":
            guard let json = contentMediaJSON,
                  let source = try? MediaSource.fromJson(json: json) else { return nil }
            let thumbnailSource = contentThumbnailMediaJSON.flatMap {
                try? MediaSource.fromJson(json: $0)
            }
            return .video(
                source: source,
                thumbnailSource: thumbnailSource,
                width: contentVideoWidth.map(UInt64.init),
                height: contentVideoHeight.map(UInt64.init),
                duration: contentVideoDuration,
                filename: contentFilename ?? "video.mp4",
                mimetype: contentMimetype,
                size: contentFileSize.map(UInt64.init),
                caption: contentCaption,
                previewThumbnailData: nil
            )
        case "voice":
            guard let json = contentMediaJSON,
                  let source = try? MediaSource.fromJson(json: json) else { return nil }
            let waveform: [UInt16]
            if let data = contentVoiceWaveform {
                waveform = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            } else {
                waveform = []
            }
            return .voice(source: source, duration: contentVoiceDuration ?? 0, waveform: waveform)
        case "notice":
            return .notice(body: contentBody ?? "")
        case "emote":
            return .emote(body: contentBody ?? "")
        case "file":
            guard let json = contentMediaJSON,
                  let source = try? MediaSource.fromJson(json: json) else { return nil }
            return .file(
                source: source,
                filename: contentFilename ?? "file",
                mimetype: contentMimetype,
                size: contentFileSize.map(UInt64.init),
                caption: contentCaption
            )
        case "call":
            guard let callId = contentBody,
                  let typeRaw = contentCaption,
                  let type = CallEventType(rawValue: typeRaw) else { return nil }
            return .callEvent(type: type, callId: callId, reason: contentMimetype)
        case "system":
            guard let text = contentBody,
                  let kindRaw = contentCaption,
                  let kind = SystemEventKind(rawValue: kindRaw) else { return nil }
            return .systemEvent(text: text, kind: kind)
        case "unsupported":
            return .unsupported(typeName: contentBody ?? "unknown")
        case "redacted":
            return .redacted
        default:
            return nil
        }
    }
}

// MARK: - Reactions JSON

extension StoredMessage {

    struct ReactionSenderJSON: Codable {
        let userId: String
        let timestamp: TimeInterval
    }

    struct ReactionJSON: Codable {
        let key: String
        let senders: [ReactionSenderJSON]
        let isOwn: Bool
        let legacyCount: Int?
    }

    struct LegacyReactionJSON: Codable {
        let key: String
        let count: Int
        let isOwn: Bool
    }

    static func encodeReactions(_ reactions: [MessageReaction]) -> String {
        let items = reactions.map {
            ReactionJSON(
                key: $0.key,
                senders: $0.senders.map {
                    ReactionSenderJSON(userId: $0.userId, timestamp: $0.timestamp)
                },
                isOwn: $0.isOwn,
                legacyCount: nil
            )
        }
        guard let data = try? JSONEncoder().encode(items),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func decodeReactions(_ json: String) -> [MessageReaction] {
        guard let data = json.data(using: .utf8) else { return [] }

        if let items = try? JSONDecoder().decode([ReactionJSON].self, from: data) {
            return items.map {
                MessageReaction(
                    key: $0.key,
                    senders: $0.senders.map {
                        ReactionSender(userId: $0.userId, timestamp: $0.timestamp)
                    },
                    isOwn: $0.isOwn,
                    legacyCount: $0.legacyCount
                )
            }
        }

        guard let legacyItems = try? JSONDecoder().decode([LegacyReactionJSON].self, from: data) else {
            return []
        }
        return legacyItems.map {
            MessageReaction(
                key: $0.key,
                senders: [],
                isOwn: $0.isOwn,
                legacyCount: $0.count
            )
        }
    }
}

// MARK: - Zyna attributes JSON

extension StoredMessage {

    struct ZynaAttributesJSON: Codable {
        let color: String?
        let checklist: [ChecklistItem]?
        let callSignal: CallSignalData?
        let forwardedFrom: String?
        let mediaGroup: MediaGroupInfo?
    }

    static func encodeZynaAttributes(_ attrs: ZynaMessageAttributes) -> String? {
        guard !attrs.isEmpty else { return nil }
        let payload = ZynaAttributesJSON(
            color: attrs.color?.hexString,
            checklist: attrs.checklist,
            callSignal: attrs.callSignal,
            forwardedFrom: attrs.forwardedFrom,
            mediaGroup: attrs.mediaGroup
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    static func decodeZynaAttributes(_ json: String?) -> ZynaMessageAttributes {
        guard let json,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ZynaAttributesJSON.self, from: data)
        else { return ZynaMessageAttributes() }
        return ZynaMessageAttributes(
            color: payload.color.flatMap(UIColor.fromHexString),
            checklist: payload.checklist,
            callSignal: payload.callSignal,
            forwardedFrom: payload.forwardedFrom,
            mediaGroup: payload.mediaGroup
        )
    }
}
