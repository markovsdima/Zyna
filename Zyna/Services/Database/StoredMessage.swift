//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
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
    var reactionsJSON: String
    var sendStatus: String
}

// MARK: - ChatMessage → StoredMessage

extension StoredMessage {

    init(from msg: ChatMessage, roomId: String) {
        self.id = msg.id
        self.roomId = roomId
        self.senderId = msg.senderId
        self.senderDisplayName = msg.senderDisplayName
        self.isOutgoing = msg.isOutgoing
        self.timestamp = msg.timestamp.timeIntervalSince1970
        self.reactionsJSON = Self.encodeReactions(msg.reactions)
        self.sendStatus = "synced"

        switch msg.itemIdentifier {
        case .eventId(let id):
            self.eventId = id
            self.transactionId = nil
        case .transactionId(let id):
            self.transactionId = id
            self.eventId = nil
            self.sendStatus = "sending"
        case nil:
            self.eventId = msg.eventId
            self.transactionId = nil
        }

        switch msg.content {
        case .text(let body):
            contentType = "text"
            contentBody = body
        case .image(let source, let width, let height, let caption):
            contentType = "image"
            contentMediaJSON = source.toJson()
            contentImageWidth = width.map(Int64.init)
            contentImageHeight = height.map(Int64.init)
            contentCaption = caption
        case .voice(let source, let duration, let waveform):
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
        case .unsupported(let typeName):
            contentType = "unsupported"
            contentBody = typeName
        case .redacted:
            contentType = "redacted"
        }
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

        return ChatMessage(
            id: id,
            eventId: eventId,
            itemIdentifier: itemIdentifier,
            senderId: senderId,
            senderDisplayName: senderDisplayName,
            isOutgoing: isOutgoing,
            timestamp: Date(timeIntervalSince1970: timestamp),
            content: content,
            reactions: Self.decodeReactions(reactionsJSON)
        )
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
                caption: contentCaption
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

private extension StoredMessage {

    struct ReactionJSON: Codable {
        let key: String
        let count: Int
        let isOwn: Bool
    }

    static func encodeReactions(_ reactions: [MessageReaction]) -> String {
        let items = reactions.map { ReactionJSON(key: $0.key, count: $0.count, isOwn: $0.isOwn) }
        guard let data = try? JSONEncoder().encode(items),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func decodeReactions(_ json: String) -> [MessageReaction] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([ReactionJSON].self, from: data) else { return [] }
        return items.map { MessageReaction(key: $0.key, count: $0.count, isOwn: $0.isOwn) }
    }
}
