//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

private let logPendingForwardedMedia = ScopedLog(.timeline, prefix: "[DirectForwardMediaTx]")

enum PendingForwardedMediaKind: String, Codable, Equatable {
    case image
    case video
    case voice
    case file

    var envelopeKind: OutgoingEnvelopeKind {
        switch self {
        case .image: return .image
        case .video: return .video
        case .voice: return .voice
        case .file: return .file
        }
    }
}

struct PendingForwardedMediaDraft {
    let kind: PendingForwardedMediaKind
    let source: MediaSource
    let thumbnailSource: MediaSource?
    let filename: String?
    let mimetype: String?
    let size: UInt64?
    let width: UInt64?
    let height: UInt64?
    let duration: TimeInterval?
    let waveform: [UInt16]
}

struct PendingForwardedMediaRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingForwardedMedia"

    var itemId: String
    var envelopeId: String
    var roomId: String
    var mediaKind: String
    var sourceJSON: String
    var thumbnailSourceJSON: String?
    var filename: String?
    var caption: String?
    var mimetype: String?
    var size: Int64?
    var width: Int64?
    var height: Int64?
    var duration: TimeInterval?
    var waveformJSON: String?
    var transactionId: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    var kind: PendingForwardedMediaKind? {
        PendingForwardedMediaKind(rawValue: mediaKind)
    }

    var source: MediaSource? {
        try? MediaSource.fromJson(json: sourceJSON)
    }

    var thumbnailSource: MediaSource? {
        guard let thumbnailSourceJSON else { return nil }
        return try? MediaSource.fromJson(json: thumbnailSourceJSON)
    }

    var waveform: [UInt16] {
        guard let waveformJSON,
              let data = waveformJSON.data(using: .utf8),
              let samples = try? JSONDecoder().decode([UInt16].self, from: data)
        else {
            return []
        }
        return samples
    }

    func messageType(zynaAttributes: ZynaMessageAttributes) throws -> MessageType {
        guard let kind else { throw PendingForwardedMediaError.invalidKind }
        let source = try MediaSource.fromJson(json: sourceJSON)
        let thumbnailSource = try thumbnailSourceJSON.map {
            try MediaSource.fromJson(json: $0)
        }
        let captionPayload = DirectRawMediaSender.mediaCaptionPayload(
            caption: caption,
            zynaAttributes: zynaAttributes
        )
        let formattedCaption = captionPayload.formattedHTML.map {
            FormattedBody(format: .html, body: $0)
        }

        switch kind {
        case .image:
            let info = ImageInfo(
                height: Self.uint64(height),
                width: Self.uint64(width),
                mimetype: mimetype ?? "image/jpeg",
                size: Self.uint64(size),
                thumbnailInfo: nil,
                thumbnailSource: thumbnailSource,
                blurhash: nil,
                isAnimated: nil
            )
            return .image(
                content: ImageMessageContent(
                    filename: filename ?? "image.jpg",
                    caption: captionPayload.plain,
                    formattedCaption: formattedCaption,
                    source: source,
                    info: info
                )
            )
        case .video:
            let info = VideoInfo(
                duration: duration,
                height: Self.uint64(height),
                width: Self.uint64(width),
                mimetype: mimetype ?? "video/mp4",
                size: Self.uint64(size),
                thumbnailInfo: nil,
                thumbnailSource: thumbnailSource,
                blurhash: nil
            )
            return .video(
                content: VideoMessageContent(
                    filename: filename ?? "video.mp4",
                    caption: captionPayload.plain,
                    formattedCaption: formattedCaption,
                    source: source,
                    info: info
                )
            )
        case .voice:
            let voiceDuration = duration ?? 0
            let info = AudioInfo(
                duration: duration,
                size: Self.uint64(size),
                mimetype: mimetype ?? "audio/mp4"
            )
            return .audio(
                content: AudioMessageContent(
                    filename: filename ?? "voice.m4a",
                    caption: captionPayload.plain,
                    formattedCaption: formattedCaption,
                    source: source,
                    info: info,
                    audio: UnstableAudioDetailsContent(
                        duration: voiceDuration,
                        waveform: waveform
                    ),
                    voice: UnstableVoiceContent()
                )
            )
        case .file:
            let info = FileInfo(
                mimetype: mimetype ?? "application/octet-stream",
                size: Self.uint64(size),
                thumbnailInfo: nil,
                thumbnailSource: thumbnailSource
            )
            return .file(
                content: FileMessageContent(
                    filename: filename ?? "file",
                    caption: captionPayload.plain,
                    formattedCaption: formattedCaption,
                    source: source,
                    info: info
                )
            )
        }
    }

    private static func uint64(_ value: Int64?) -> UInt64? {
        value.map { UInt64(clamping: $0) }
    }
}

struct PendingForwardedMediaCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
    let forwardedMedia: PendingForwardedMediaRecord
}

struct PendingForwardedMediaMissingRecordCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
}

enum PendingForwardedMediaError: Error {
    case invalidKind
}

final class PendingForwardedMediaService {

    static let shared = PendingForwardedMediaService()

    private var dbQueue: DatabaseQueue { DatabaseService.shared.dbQueue }

    private init() {}

    func prepareForwardedMedia(
        envelopeId: String,
        itemIndex: Int,
        roomId: String,
        draft: PendingForwardedMediaDraft,
        caption: String?,
        transactionId: String
    ) -> Bool {
        let itemId = OutgoingEnvelopeItemRecord.makeId(
            groupId: envelopeId,
            itemIndex: itemIndex
        )
        let now = Date().timeIntervalSince1970
        let record = PendingForwardedMediaRecord(
            itemId: itemId,
            envelopeId: envelopeId,
            roomId: roomId,
            mediaKind: draft.kind.rawValue,
            sourceJSON: draft.source.toJson(),
            thumbnailSourceJSON: draft.thumbnailSource?.toJson(),
            filename: draft.filename,
            caption: Self.normalizeCaption(caption),
            mimetype: draft.mimetype,
            size: draft.size.map { Int64(clamping: $0) },
            width: draft.width.map { Int64(clamping: $0) },
            height: draft.height.map { Int64(clamping: $0) },
            duration: draft.duration,
            waveformJSON: Self.encodeWaveform(draft.waveform),
            transactionId: transactionId,
            createdAt: now,
            updatedAt: now
        )

        do {
            try dbQueue.write { db in
                try record.save(db)
            }
            logPendingForwardedMedia(
                "asset prepared envelope=\(envelopeId) item=\(itemIndex) kind=\(draft.kind.rawValue) tx=\(transactionId)"
            )
            return true
        } catch {
            logPendingForwardedMedia(
                "asset prepare failed envelope=\(envelopeId) item=\(itemIndex) kind=\(draft.kind.rawValue) error=\(error)"
            )
            return false
        }
    }

    func outboxCandidates(
        envelopeIds: Set<String>? = nil
    ) -> [PendingForwardedMediaCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var recordRequest = PendingForwardedMediaRecord
                .order(Column("createdAt").asc)

            if let envelopeIds {
                recordRequest = recordRequest.filter(envelopeIds.contains(Column("envelopeId")))
            }

            let records = try recordRequest.fetchAll(db)
            guard !records.isEmpty else { return [] }

            let envelopeIds = records.map(\.envelopeId)
            let envelopes = try OutgoingEnvelopeRecord
                .filter(envelopeIds.contains(Column("id")))
                .order(Column("createdAt").asc)
                .fetchAll(db)
            let groupIds = envelopes.map(\.id)
            let items = try OutgoingEnvelopeItemRecord
                .filter(groupIds.contains(Column("groupId")))
                .order(Column("itemIndex").asc)
                .fetchAll(db)

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)
            let recordsByItemId = Dictionary(uniqueKeysWithValues: records.map {
                ($0.itemId, $0)
            })

            return envelopes.compactMap { envelope -> PendingForwardedMediaCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let record = recordsByItemId[item.id],
                      let kind = record.kind,
                      snapshot.kind == kind.envelopeKind,
                      Self.isOutboxState(item.transportState) else {
                    return nil
                }
                return PendingForwardedMediaCandidate(
                    envelope: snapshot,
                    item: item,
                    forwardedMedia: record
                )
            }
        }) ?? []
    }

    func missingRecordCandidates(
        envelopeIds: Set<String>? = nil
    ) -> [PendingForwardedMediaMissingRecordCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Self.forwardedEnvelopeKinds.contains(Column("kind")))
                .order(Column("createdAt").asc)

            if let envelopeIds {
                request = request.filter(envelopeIds.contains(Column("id")))
            }

            let envelopes = try request.fetchAll(db)
            guard !envelopes.isEmpty else { return [] }

            let groupIds = envelopes.map(\.id)
            let items = try OutgoingEnvelopeItemRecord
                .filter(groupIds.contains(Column("groupId")))
                .order(Column("itemIndex").asc)
                .fetchAll(db)
            let itemIds = items.map(\.id)
            let forwardedItemIds = Set(try PendingForwardedMediaRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)
                .map(\.itemId))

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)

            return envelopes.compactMap { envelope -> PendingForwardedMediaMissingRecordCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard snapshot.zynaAttributes.forwardedFrom != nil,
                      let item = snapshot.primaryItem,
                      item.eventId == nil,
                      item.transactionId == nil,
                      item.bindingToken != nil,
                      item.mediaSource != nil,
                      item.transportState == .queued,
                      !forwardedItemIds.contains(item.id) else {
                    return nil
                }
                return PendingForwardedMediaMissingRecordCandidate(
                    envelope: snapshot,
                    item: item
                )
            }
        }) ?? []
    }

    private static func isOutboxState(_ state: OutgoingTransportState) -> Bool {
        switch state {
        case .queued, .sending, .retrying:
            return true
        case .uploading, .uploaded, .sent, .failed:
            return false
        }
    }

    private static func normalizeCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func encodeWaveform(_ waveform: [UInt16]) -> String? {
        guard !waveform.isEmpty,
              let data = try? JSONEncoder().encode(waveform)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static var forwardedEnvelopeKinds: [String] {
        [
            OutgoingEnvelopeKind.image.rawValue,
            OutgoingEnvelopeKind.video.rawValue,
            OutgoingEnvelopeKind.voice.rawValue,
            OutgoingEnvelopeKind.file.rawValue
        ]
    }
}
