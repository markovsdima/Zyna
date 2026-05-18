//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

private let logPendingDirectVideo = ScopedLog(.timeline, prefix: "[DirectRawVideoTx]")

struct PendingDirectVideoRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingDirectVideo"

    var itemId: String
    var envelopeId: String
    var roomId: String
    var originalFileName: String
    var thumbnailFileName: String
    var originalMimetype: String
    var originalSize: Int64
    var originalWidth: Int64
    var originalHeight: Int64
    var originalDuration: TimeInterval
    var thumbnailMimetype: String
    var thumbnailSize: Int64
    var thumbnailWidth: Int64
    var thumbnailHeight: Int64
    var blurhash: String?
    var uploadedVideoJSON: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
}

struct PendingDirectVideoCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
    let video: PendingDirectVideoRecord
    let payload: OutgoingVideoPayload
}

struct PendingDirectVideoMissingAssetCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
}

final class PendingDirectVideoService {

    static let shared = PendingDirectVideoService()

    private var dbQueue: DatabaseQueue { DatabaseService.shared.dbQueue }

    private init() {}

    func prepareVideo(
        envelopeId: String,
        itemIndex: Int,
        roomId: String,
        video: ProcessedVideo
    ) -> Bool {
        let itemId = OutgoingEnvelopeItemRecord.makeId(
            groupId: envelopeId,
            itemIndex: itemIndex
        )
        let originalExtension = video.videoURL.pathExtension.isEmpty
            ? "mp4"
            : video.videoURL.pathExtension
        let thumbnailExtension = video.thumbnailURL.pathExtension.isEmpty
            ? "jpg"
            : video.thumbnailURL.pathExtension
        let originalFileName = "\(itemId)-original.\(originalExtension)"
        let thumbnailFileName = "\(itemId)-thumbnail.\(thumbnailExtension)"
        let originalURL = videoFileURL(fileName: originalFileName)
        let thumbnailURL = videoFileURL(fileName: thumbnailFileName)

        do {
            try copyProtectedFile(from: video.videoURL, to: originalURL)
            try copyProtectedFile(from: video.thumbnailURL, to: thumbnailURL)

            let now = Date().timeIntervalSince1970
            let record = PendingDirectVideoRecord(
                itemId: itemId,
                envelopeId: envelopeId,
                roomId: roomId,
                originalFileName: originalFileName,
                thumbnailFileName: thumbnailFileName,
                originalMimetype: video.mimetype,
                originalSize: Int64(clamping: video.size),
                originalWidth: Int64(clamping: video.width),
                originalHeight: Int64(clamping: video.height),
                originalDuration: video.duration,
                thumbnailMimetype: "image/jpeg",
                thumbnailSize: Int64(clamping: video.thumbnailSize),
                thumbnailWidth: Int64(clamping: video.thumbnailWidth),
                thumbnailHeight: Int64(clamping: video.thumbnailHeight),
                blurhash: video.blurhash,
                uploadedVideoJSON: nil,
                createdAt: now,
                updatedAt: now
            )

            try dbQueue.write { db in
                try record.save(db)
            }
            logPendingDirectVideo(
                "asset prepared envelope=\(envelopeId) item=\(itemIndex) bytes=\(video.size) thumbBytes=\(video.thumbnailSize)"
            )
            return true
        } catch {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            logPendingDirectVideo(
                "asset prepare failed envelope=\(envelopeId) item=\(itemIndex) error=\(error)"
            )
            return false
        }
    }

    func record(itemId: String) -> PendingDirectVideoRecord? {
        try? dbQueue.read { db in
            try PendingDirectVideoRecord.fetchOne(db, key: itemId)
        }
    }

    func markUploaded(itemId: String, uploadedVideoJSON: String) -> Bool {
        let didChange = (try? dbQueue.write { db in
            guard var record = try PendingDirectVideoRecord.fetchOne(db, key: itemId) else {
                return false
            }
            let didChange = record.uploadedVideoJSON != uploadedVideoJSON
            record.uploadedVideoJSON = uploadedVideoJSON
            record.updatedAt = Date().timeIntervalSince1970
            try record.save(db)
            return didChange
        }) ?? false

        if didChange {
            logPendingDirectVideo(
                "asset uploaded item=\(itemId) uploadedBytes=\(uploadedVideoJSON.count)"
            )
        }
        return didChange
    }

    func outboxCandidates(envelopeIds: Set<String>? = nil) -> [PendingDirectVideoCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Column("kind") == OutgoingEnvelopeKind.video.rawValue)
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
            let videos = try PendingDirectVideoRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)
            let videosByItemId = Dictionary(uniqueKeysWithValues: videos.map {
                ($0.itemId, $0)
            })

            return envelopes.compactMap { envelope -> PendingDirectVideoCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let transactionId = item.transactionId,
                      !transactionId.isEmpty,
                      let video = videosByItemId[item.id],
                      let payload = snapshot.videoPayload,
                      Self.isOutboxState(item.transportState) else {
                    return nil
                }
                return PendingDirectVideoCandidate(
                    envelope: snapshot,
                    item: item,
                    video: video,
                    payload: payload
                )
            }
        }) ?? []
    }

    func missingAssetCandidates(
        envelopeIds: Set<String>? = nil
    ) -> [PendingDirectVideoMissingAssetCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Column("kind") == OutgoingEnvelopeKind.video.rawValue)
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
            let videoItemIds = Set(try PendingDirectVideoRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)
                .map(\.itemId))

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)

            return envelopes.compactMap { envelope -> PendingDirectVideoMissingAssetCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let transactionId = item.transactionId,
                      !transactionId.isEmpty,
                      !videoItemIds.contains(item.id),
                      item.transportState == .queued else {
                    return nil
                }
                return PendingDirectVideoMissingAssetCandidate(
                    envelope: snapshot,
                    item: item
                )
            }
        }) ?? []
    }

    func originalFileURL(for record: PendingDirectVideoRecord) -> URL {
        videoFileURL(fileName: record.originalFileName)
    }

    func thumbnailFileURL(for record: PendingDirectVideoRecord) -> URL {
        videoFileURL(fileName: record.thumbnailFileName)
    }

    func deleteAssets(envelopeIds: Set<String>) {
        guard !envelopeIds.isEmpty else { return }
        let fileNames: [String] = (try? dbQueue.read { db in
            let records = try PendingDirectVideoRecord
                .filter(envelopeIds.contains(Column("envelopeId")))
                .fetchAll(db)
            return records.flatMap {
                [$0.originalFileName, $0.thumbnailFileName]
            }
        }) ?? []
        for fileName in fileNames {
            try? FileManager.default.removeItem(at: videoFileURL(fileName: fileName))
        }
    }

    private static func isOutboxState(_ state: OutgoingTransportState) -> Bool {
        switch state {
        case .queued, .uploading, .uploaded, .sending, .retrying:
            return true
        case .sent, .failed:
            return false
        }
    }

    private func copyProtectedFile(from sourceURL: URL, to destinationURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try? LocalDataProtection.applyProtection(to: destinationURL, protection: .sensitive)
    }

    private func videoDirectoryURL() -> URL {
        let userId = UserDefaults.standard.string(forKey: "com.zyna.matrix.lastUserId")
        let directory = LocalDataProtection.outgoingVideoDirectory(for: userId)
        _ = try? LocalDataProtection.createProtectedDirectory(
            at: directory,
            protection: .sensitive,
            excludeFromBackup: true
        )
        return directory
    }

    private func videoFileURL(fileName: String) -> URL {
        videoDirectoryURL().appendingPathComponent(fileName)
    }
}
