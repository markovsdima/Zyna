//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

private let logPendingDirectImage = ScopedLog(.timeline, prefix: "[DirectRawImageTx]")

struct PendingDirectImageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingDirectImage"

    var itemId: String
    var envelopeId: String
    var roomId: String
    var originalFileName: String
    var thumbnailFileName: String
    var originalMimetype: String
    var originalSize: Int64
    var originalWidth: Int64
    var originalHeight: Int64
    var thumbnailMimetype: String
    var thumbnailSize: Int64
    var thumbnailWidth: Int64
    var thumbnailHeight: Int64
    var blurhash: String?
    var uploadedImageJSON: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
}

struct PendingDirectImageCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
    let image: PendingDirectImageRecord
}

struct PendingDirectImageMissingAssetCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
}

final class PendingDirectImageService {

    static let shared = PendingDirectImageService()

    private var dbQueue: DatabaseQueue { DatabaseService.shared.dbQueue }

    private init() {}

    func prepareImage(
        envelopeId: String,
        itemIndex: Int,
        roomId: String,
        image: ProcessedImage
    ) -> Bool {
        let itemId = OutgoingEnvelopeItemRecord.makeId(
            groupId: envelopeId,
            itemIndex: itemIndex
        )
        let originalFileName = "\(itemId)-original.jpg"
        let thumbnailFileName = "\(itemId)-thumbnail.jpg"

        do {
            try LocalDataProtection.writeProtectedData(
                image.imageData,
                to: imageFileURL(fileName: originalFileName),
                protection: .sensitive
            )
            try LocalDataProtection.writeProtectedData(
                image.thumbnailData,
                to: imageFileURL(fileName: thumbnailFileName),
                protection: .sensitive
            )

            let now = Date().timeIntervalSince1970
            let record = PendingDirectImageRecord(
                itemId: itemId,
                envelopeId: envelopeId,
                roomId: roomId,
                originalFileName: originalFileName,
                thumbnailFileName: thumbnailFileName,
                originalMimetype: "image/jpeg",
                originalSize: Int64(clamping: UInt64(image.imageData.count)),
                originalWidth: Int64(clamping: image.width),
                originalHeight: Int64(clamping: image.height),
                thumbnailMimetype: "image/jpeg",
                thumbnailSize: Int64(clamping: image.thumbnailSize),
                thumbnailWidth: Int64(clamping: image.thumbnailWidth),
                thumbnailHeight: Int64(clamping: image.thumbnailHeight),
                blurhash: image.blurhash,
                uploadedImageJSON: nil,
                createdAt: now,
                updatedAt: now
            )

            try dbQueue.write { db in
                try record.save(db)
            }
            logPendingDirectImage(
                "asset prepared envelope=\(envelopeId) item=\(itemIndex) bytes=\(image.imageData.count) thumbBytes=\(image.thumbnailData.count)"
            )
            return true
        } catch {
            try? FileManager.default.removeItem(at: imageFileURL(fileName: originalFileName))
            try? FileManager.default.removeItem(at: imageFileURL(fileName: thumbnailFileName))
            logPendingDirectImage(
                "asset prepare failed envelope=\(envelopeId) item=\(itemIndex) error=\(error)"
            )
            return false
        }
    }

    func record(itemId: String) -> PendingDirectImageRecord? {
        try? dbQueue.read { db in
            try PendingDirectImageRecord.fetchOne(db, key: itemId)
        }
    }

    func markUploaded(itemId: String, uploadedImageJSON: String) -> Bool {
        let didChange = (try? dbQueue.write { db in
            guard var record = try PendingDirectImageRecord.fetchOne(db, key: itemId) else {
                return false
            }
            let didChange = record.uploadedImageJSON != uploadedImageJSON
            record.uploadedImageJSON = uploadedImageJSON
            record.updatedAt = Date().timeIntervalSince1970
            try record.save(db)
            return didChange
        }) ?? false

        if didChange {
            logPendingDirectImage(
                "asset uploaded item=\(itemId) uploadedBytes=\(uploadedImageJSON.count)"
            )
        }
        return didChange
    }

    func outboxCandidates(envelopeIds: Set<String>? = nil) -> [PendingDirectImageCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Column("kind") == OutgoingEnvelopeKind.image.rawValue)
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
            let images = try PendingDirectImageRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)
            let imagesByItemId = Dictionary(uniqueKeysWithValues: images.map {
                ($0.itemId, $0)
            })

            return envelopes.compactMap { envelope -> PendingDirectImageCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let transactionId = item.transactionId,
                      !transactionId.isEmpty,
                      let image = imagesByItemId[item.id],
                      Self.isOutboxState(item.transportState) else {
                    return nil
                }
                return PendingDirectImageCandidate(
                    envelope: snapshot,
                    item: item,
                    image: image
                )
            }
        }) ?? []
    }

    func missingAssetCandidates(
        envelopeIds: Set<String>? = nil
    ) -> [PendingDirectImageMissingAssetCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Column("kind") == OutgoingEnvelopeKind.image.rawValue)
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
            let imageItemIds = Set(try PendingDirectImageRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)
                .map(\.itemId))

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)

            return envelopes.compactMap { envelope -> PendingDirectImageMissingAssetCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let transactionId = item.transactionId,
                      !transactionId.isEmpty,
                      !imageItemIds.contains(item.id),
                      Self.isOutboxState(item.transportState) else {
                    return nil
                }
                return PendingDirectImageMissingAssetCandidate(
                    envelope: snapshot,
                    item: item
                )
            }
        }) ?? []
    }

    func originalFileURL(for record: PendingDirectImageRecord) -> URL {
        imageFileURL(fileName: record.originalFileName)
    }

    func thumbnailFileURL(for record: PendingDirectImageRecord) -> URL {
        imageFileURL(fileName: record.thumbnailFileName)
    }

    func deleteAssets(envelopeIds: Set<String>) {
        guard !envelopeIds.isEmpty else { return }
        let fileNames: [String] = (try? dbQueue.read { db in
            let records = try PendingDirectImageRecord
                .filter(envelopeIds.contains(Column("envelopeId")))
                .fetchAll(db)
            return records.flatMap {
                [$0.originalFileName, $0.thumbnailFileName]
            }
        }) ?? []
        for fileName in fileNames {
            try? FileManager.default.removeItem(at: imageFileURL(fileName: fileName))
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

    private func imageDirectoryURL() -> URL {
        let userId = UserDefaults.standard.string(forKey: "com.zyna.matrix.lastUserId")
        let directory = LocalDataProtection.outgoingImageDirectory(for: userId)
        _ = try? LocalDataProtection.createProtectedDirectory(
            at: directory,
            protection: .sensitive,
            excludeFromBackup: true
        )
        return directory
    }

    private func imageFileURL(fileName: String) -> URL {
        imageDirectoryURL().appendingPathComponent(fileName)
    }
}
