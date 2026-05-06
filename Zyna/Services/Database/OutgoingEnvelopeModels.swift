//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit
import GRDB
import MatrixRustSDK

enum OutgoingEnvelopeKind: String, Codable, Equatable {
    case text
    case image
    case video
    case voice
    case file
    case mediaBatch
}

enum OutgoingTransportState: String, Codable, Equatable {
    case queued
    case sending
    case uploading
    case retrying
    case sent
    case failed

    var messageSendStatus: String {
        switch self {
        case .queued:
            return "queued"
        case .sending, .uploading:
            return "sending"
        case .retrying:
            return "retrying"
        case .sent:
            return "sent"
        case .failed:
            return "failed"
        }
    }
}

struct OutgoingTextPayload: Codable, Equatable {
    let body: String
}

struct OutgoingImagePayload: Codable, Equatable {
    let caption: String?
    let width: UInt64?
    let height: UInt64?
}

struct OutgoingVideoPayload: Codable, Equatable {
    let filename: String
    let caption: String?
    let width: UInt64?
    let height: UInt64?
    let duration: TimeInterval?
    let mimetype: String?
    let size: UInt64?
}

struct OutgoingVoicePayload: Codable, Equatable {
    let duration: TimeInterval
    let waveform: [UInt16]
}

struct OutgoingFilePayload: Codable, Equatable {
    let filename: String
    let mimetype: String?
    let size: UInt64?
    let caption: String?
}

struct OutgoingMediaBatchPayload: Codable, Equatable {
    let caption: String?
    let captionPlacement: CaptionPlacement
    let expectedItemCount: Int
    let layoutOverride: MediaGroupLayoutOverride?
}

enum OutgoingEnvelopePayload: Equatable {
    case text(OutgoingTextPayload)
    case image(OutgoingImagePayload)
    case video(OutgoingVideoPayload)
    case voice(OutgoingVoicePayload)
    case file(OutgoingFilePayload)
    case mediaBatch(OutgoingMediaBatchPayload)

    private struct CodablePayload: Codable {
        let kind: String
        let body: String?
        let caption: String?
        let captionPlacement: String?
        let expectedItemCount: Int?
        let width: UInt64?
        let height: UInt64?
        let primarySplitPermille: Int?
        let secondarySplitPermille: Int?
        let filename: String?
        let mimetype: String?
        let size: UInt64?
        let duration: TimeInterval?
        let waveform: [UInt16]?
    }

    func encodeJSON() -> String? {
        let payload: CodablePayload
        switch self {
        case .text(let text):
            payload = CodablePayload(
                kind: OutgoingEnvelopeKind.text.rawValue,
                body: text.body,
                caption: nil,
                captionPlacement: nil,
                expectedItemCount: 1,
                width: nil,
                height: nil,
                primarySplitPermille: nil,
                secondarySplitPermille: nil,
                filename: nil,
                mimetype: nil,
                size: nil,
                duration: nil,
                waveform: nil
            )
        case .image(let image):
            payload = CodablePayload(
                kind: OutgoingEnvelopeKind.image.rawValue,
                body: nil,
                caption: image.caption,
                captionPlacement: nil,
                expectedItemCount: 1,
                width: image.width,
                height: image.height,
                primarySplitPermille: nil,
                secondarySplitPermille: nil,
                filename: nil,
                mimetype: nil,
                size: nil,
                duration: nil,
                waveform: nil
            )
        case .video(let video):
            payload = CodablePayload(
                kind: OutgoingEnvelopeKind.video.rawValue,
                body: nil,
                caption: video.caption,
                captionPlacement: nil,
                expectedItemCount: 1,
                width: video.width,
                height: video.height,
                primarySplitPermille: nil,
                secondarySplitPermille: nil,
                filename: video.filename,
                mimetype: video.mimetype,
                size: video.size,
                duration: video.duration,
                waveform: nil
            )
        case .voice(let voice):
            payload = CodablePayload(
                kind: OutgoingEnvelopeKind.voice.rawValue,
                body: nil,
                caption: nil,
                captionPlacement: nil,
                expectedItemCount: 1,
                width: nil,
                height: nil,
                primarySplitPermille: nil,
                secondarySplitPermille: nil,
                filename: nil,
                mimetype: nil,
                size: nil,
                duration: voice.duration,
                waveform: voice.waveform
            )
        case .file(let file):
            payload = CodablePayload(
                kind: OutgoingEnvelopeKind.file.rawValue,
                body: nil,
                caption: file.caption,
                captionPlacement: nil,
                expectedItemCount: 1,
                width: nil,
                height: nil,
                primarySplitPermille: nil,
                secondarySplitPermille: nil,
                filename: file.filename,
                mimetype: file.mimetype,
                size: file.size,
                duration: nil,
                waveform: nil
            )
        case .mediaBatch(let batch):
            payload = CodablePayload(
                kind: OutgoingEnvelopeKind.mediaBatch.rawValue,
                body: nil,
                caption: batch.caption,
                captionPlacement: batch.captionPlacement.rawValue,
                expectedItemCount: batch.expectedItemCount,
                width: nil,
                height: nil,
                primarySplitPermille: batch.layoutOverride?.primarySplitPermille,
                secondarySplitPermille: batch.layoutOverride?.secondarySplitPermille,
                filename: nil,
                mimetype: nil,
                size: nil,
                duration: nil,
                waveform: nil
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeJSON(_ json: String?) -> OutgoingEnvelopePayload? {
        guard let json,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CodablePayload.self, from: data),
              let kind = OutgoingEnvelopeKind(rawValue: payload.kind)
        else {
            return nil
        }

        switch kind {
        case .text:
            return .text(
                OutgoingTextPayload(
                    body: payload.body ?? ""
                )
            )
        case .image:
            return .image(
                OutgoingImagePayload(
                    caption: payload.caption,
                    width: payload.width,
                    height: payload.height
                )
            )
        case .video:
            return .video(
                OutgoingVideoPayload(
                    filename: payload.filename ?? "video.mp4",
                    caption: payload.caption,
                    width: payload.width,
                    height: payload.height,
                    duration: payload.duration,
                    mimetype: payload.mimetype,
                    size: payload.size
                )
            )
        case .voice:
            return .voice(
                OutgoingVoicePayload(
                    duration: payload.duration ?? 0,
                    waveform: payload.waveform ?? []
                )
            )
        case .file:
            return .file(
                OutgoingFilePayload(
                    filename: payload.filename ?? "file",
                    mimetype: payload.mimetype,
                    size: payload.size,
                    caption: payload.caption
                )
            )
        case .mediaBatch:
            return .mediaBatch(
                OutgoingMediaBatchPayload(
                    caption: payload.caption,
                    captionPlacement: CaptionPlacement(rawValue: payload.captionPlacement ?? "") ?? .bottom,
                    expectedItemCount: payload.expectedItemCount ?? 0,
                    layoutOverride: payload.primarySplitPermille.map {
                        MediaGroupLayoutOverride(
                            primarySplitPermille: $0,
                            secondarySplitPermille: payload.secondarySplitPermille
                        )
                    }
                )
            )
        }
    }
}

struct OutgoingEnvelopeRecord: Codable, FetchableRecord, PersistableRecord {
    // Legacy table name kept to avoid churn in the physical schema while
    // the logical model moves from "pending media group" to generic
    // outgoing envelopes.
    // TODO: When we do the planned homeserver / account reset and old
    // local databases no longer matter, rename the physical tables to
    // outgoingEnvelope / outgoingEnvelopeItem as well.
    static let databaseTableName = "pendingMediaGroup"

    var id: String
    var roomId: String
    var caption: String?
    var captionPlacement: String
    var expectedItemCount: Int
    var createdAt: TimeInterval
    var replyEventId: String?
    var replySenderId: String?
    var replySenderName: String?
    var replyBody: String?
    var kind: String?
    var state: String?
    var payloadJSON: String?
    var zynaAttributesJSON: String?

    var decodedKind: OutgoingEnvelopeKind {
        OutgoingEnvelopeKind(rawValue: kind ?? "") ?? .mediaBatch
    }

    var decodedState: OutgoingTransportState {
        OutgoingTransportState(rawValue: state ?? "") ?? .queued
    }

    var payload: OutgoingEnvelopePayload {
        if let payload = OutgoingEnvelopePayload.decodeJSON(payloadJSON) {
            return payload
        }
        switch decodedKind {
        case .text:
            return .text(OutgoingTextPayload(body: caption ?? ""))
        case .image:
            return .image(
                OutgoingImagePayload(
                    caption: caption,
                    width: nil,
                    height: nil
                )
            )
        case .video:
            return .video(
                OutgoingVideoPayload(
                    filename: caption ?? "video.mp4",
                    caption: nil,
                    width: nil,
                    height: nil,
                    duration: nil,
                    mimetype: nil,
                    size: nil
                )
            )
        case .voice:
            return .voice(
                OutgoingVoicePayload(
                    duration: 0,
                    waveform: []
                )
            )
        case .file:
            return .file(
                OutgoingFilePayload(
                    filename: caption ?? "file",
                    mimetype: nil,
                    size: nil,
                    caption: nil
                )
            )
        case .mediaBatch:
            return .mediaBatch(
                OutgoingMediaBatchPayload(
                    caption: caption,
                    captionPlacement: CaptionPlacement(rawValue: captionPlacement) ?? .bottom,
                    expectedItemCount: expectedItemCount,
                    layoutOverride: nil
                )
            )
        }
    }

    var zynaAttributes: ZynaMessageAttributes {
        StoredMessage.decodeZynaAttributes(zynaAttributesJSON)
    }

    var replyInfo: ReplyInfo? {
        guard let replyEventId, let replySenderId, let replyBody else { return nil }
        return ReplyInfo(
            eventId: replyEventId,
            senderId: replySenderId,
            senderDisplayName: replySenderName,
            body: replyBody
        )
    }
}

struct OutgoingEnvelopeItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingMediaGroupItem"

    var id: String
    var groupId: String
    var itemIndex: Int
    var bindingToken: String?
    var transactionId: String?
    var eventId: String?
    var mediaSourceJSON: String?
    var previewImageData: Data?
    var previewWidth: Int64?
    var previewHeight: Int64?
    var transportState: String?

    static func makeId(groupId: String, itemIndex: Int) -> String {
        "\(groupId):\(itemIndex)"
    }

    var mediaSource: MediaSource? {
        guard let mediaSourceJSON else { return nil }
        return try? MediaSource.fromJson(json: mediaSourceJSON)
    }

    var decodedTransportState: OutgoingTransportState {
        if let transportState,
           let state = OutgoingTransportState(rawValue: transportState) {
            return state
        }
        if eventId != nil {
            return .sent
        }
        if mediaSourceJSON != nil {
            return .uploading
        }
        return transactionId == nil ? .queued : .sending
    }
}

struct OutgoingEnvelopeSnapshot {
    let id: String
    let roomId: String
    let kind: OutgoingEnvelopeKind
    let state: OutgoingTransportState
    let payload: OutgoingEnvelopePayload
    let zynaAttributes: ZynaMessageAttributes
    let createdAt: Date
    let replyInfo: ReplyInfo?
    let items: [OutgoingEnvelopeItemSnapshot]

    init(record: OutgoingEnvelopeRecord, items: [OutgoingEnvelopeItemRecord]) {
        self.id = record.id
        self.roomId = record.roomId
        self.kind = record.decodedKind
        self.state = record.decodedState
        self.payload = record.payload
        self.zynaAttributes = record.zynaAttributes
        self.createdAt = Date(timeIntervalSince1970: record.createdAt)
        self.replyInfo = record.replyInfo
        self.items = items
            .sorted { $0.itemIndex < $1.itemIndex }
            .map(OutgoingEnvelopeItemSnapshot.init(record:))
    }

    var mediaBatchPayload: OutgoingMediaBatchPayload? {
        guard case .mediaBatch(let batchPayload) = payload else { return nil }
        return batchPayload
    }

    var textPayload: OutgoingTextPayload? {
        guard case .text(let textPayload) = payload else { return nil }
        return textPayload
    }

    var imagePayload: OutgoingImagePayload? {
        guard case .image(let imagePayload) = payload else { return nil }
        return imagePayload
    }

    var videoPayload: OutgoingVideoPayload? {
        guard case .video(let videoPayload) = payload else { return nil }
        return videoPayload
    }

    var voicePayload: OutgoingVoicePayload? {
        guard case .voice(let voicePayload) = payload else { return nil }
        return voicePayload
    }

    var filePayload: OutgoingFilePayload? {
        guard case .file(let filePayload) = payload else { return nil }
        return filePayload
    }

    var caption: String? {
        mediaBatchPayload?.caption
    }

    var captionPlacement: CaptionPlacement {
        mediaBatchPayload?.captionPlacement ?? .bottom
    }

    var expectedItemCount: Int {
        mediaBatchPayload?.expectedItemCount ?? max(items.count, 1)
    }

    var primaryItem: OutgoingEnvelopeItemSnapshot? {
        items.first
    }
}

struct OutgoingMediaDraftItem {
    let previewImageData: Data
    let width: UInt64
    let height: UInt64
}

struct OutgoingEnvelopeItemSnapshot {
    let id: String
    let groupId: String
    let itemIndex: Int
    let bindingToken: String?
    let transactionId: String?
    let eventId: String?
    let mediaSource: MediaSource?
    let previewImageData: Data?
    let previewWidth: UInt64?
    let previewHeight: UInt64?
    let transportState: OutgoingTransportState

    init(record: OutgoingEnvelopeItemRecord) {
        self.id = record.id
        self.groupId = record.groupId
        self.itemIndex = record.itemIndex
        self.bindingToken = record.bindingToken
        self.transactionId = record.transactionId
        self.eventId = record.eventId
        self.mediaSource = record.mediaSource
        self.previewImageData = record.previewImageData
        self.previewWidth = record.previewWidth.map(UInt64.init)
        self.previewHeight = record.previewHeight.map(UInt64.init)
        self.transportState = record.decodedTransportState
    }
}
