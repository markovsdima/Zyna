//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

private let logPendingDirectFile = ScopedLog(.timeline, prefix: "[DirectRawFileTx]")

struct PendingDirectFileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingDirectFile"

    var itemId: String
    var envelopeId: String
    var roomId: String
    var storageDirectoryName: String
    var filename: String
    var mimetype: String
    var size: Int64
    var uploadedFileJSON: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
}

struct PendingDirectFileCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
    let file: PendingDirectFileRecord
    let payload: OutgoingFilePayload
}

struct PendingDirectFileMissingAssetCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
}

final class PendingDirectFileService {

    static let shared = PendingDirectFileService()

    private var dbQueue: DatabaseQueue { DatabaseService.shared.dbQueue }

    private init() {}

    func prepareFile(
        envelopeId: String,
        itemIndex: Int,
        roomId: String,
        sourceURL: URL,
        filename: String,
        mimetype: String,
        size: UInt64
    ) -> Bool {
        let itemId = OutgoingEnvelopeItemRecord.makeId(
            groupId: envelopeId,
            itemIndex: itemIndex
        )
        let storageDirectoryName = itemId
        let storedFilename = sanitizedFilename(filename)
        let directoryURL = fileDirectoryURL(directoryName: storageDirectoryName)
        let fileURL = directoryURL.appendingPathComponent(storedFilename)

        do {
            try LocalDataProtection.createProtectedDirectory(
                at: directoryURL,
                protection: .sensitive,
                excludeFromBackup: true
            )
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.copyItem(at: sourceURL, to: fileURL)
            try? LocalDataProtection.applyProtection(to: fileURL, protection: .sensitive)

            let now = Date().timeIntervalSince1970
            let record = PendingDirectFileRecord(
                itemId: itemId,
                envelopeId: envelopeId,
                roomId: roomId,
                storageDirectoryName: storageDirectoryName,
                filename: storedFilename,
                mimetype: mimetype,
                size: Int64(clamping: size),
                uploadedFileJSON: nil,
                createdAt: now,
                updatedAt: now
            )

            try dbQueue.write { db in
                try record.save(db)
            }
            logPendingDirectFile(
                "asset prepared envelope=\(envelopeId) item=\(itemIndex) filename=\(storedFilename) bytes=\(size)"
            )
            return true
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            logPendingDirectFile(
                "asset prepare failed envelope=\(envelopeId) item=\(itemIndex) error=\(error)"
            )
            return false
        }
    }

    func record(itemId: String) -> PendingDirectFileRecord? {
        try? dbQueue.read { db in
            try PendingDirectFileRecord.fetchOne(db, key: itemId)
        }
    }

    func markUploaded(itemId: String, uploadedFileJSON: String) -> Bool {
        let didChange = (try? dbQueue.write { db in
            guard var record = try PendingDirectFileRecord.fetchOne(db, key: itemId) else {
                return false
            }
            let didChange = record.uploadedFileJSON != uploadedFileJSON
            record.uploadedFileJSON = uploadedFileJSON
            record.updatedAt = Date().timeIntervalSince1970
            try record.save(db)
            return didChange
        }) ?? false

        if didChange {
            logPendingDirectFile(
                "asset uploaded item=\(itemId) uploadedBytes=\(uploadedFileJSON.count)"
            )
        }
        return didChange
    }

    func outboxCandidates(envelopeIds: Set<String>? = nil) -> [PendingDirectFileCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Column("kind") == OutgoingEnvelopeKind.file.rawValue)
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
            let files = try PendingDirectFileRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)
            let filesByItemId = Dictionary(uniqueKeysWithValues: files.map {
                ($0.itemId, $0)
            })

            return envelopes.compactMap { envelope -> PendingDirectFileCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let transactionId = item.transactionId,
                      !transactionId.isEmpty,
                      let file = filesByItemId[item.id],
                      let payload = snapshot.filePayload,
                      Self.isOutboxState(item.transportState) else {
                    return nil
                }
                return PendingDirectFileCandidate(
                    envelope: snapshot,
                    item: item,
                    file: file,
                    payload: payload
                )
            }
        }) ?? []
    }

    func missingAssetCandidates(
        envelopeIds: Set<String>? = nil
    ) -> [PendingDirectFileMissingAssetCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Column("kind") == OutgoingEnvelopeKind.file.rawValue)
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
            let fileItemIds = Set(try PendingDirectFileRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)
                .map(\.itemId))

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)

            return envelopes.compactMap { envelope -> PendingDirectFileMissingAssetCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let transactionId = item.transactionId,
                      !transactionId.isEmpty,
                      !fileItemIds.contains(item.id),
                      item.transportState == .queued else {
                    return nil
                }
                return PendingDirectFileMissingAssetCandidate(
                    envelope: snapshot,
                    item: item
                )
            }
        }) ?? []
    }

    func fileURL(for record: PendingDirectFileRecord) -> URL {
        fileDirectoryURL(directoryName: record.storageDirectoryName)
            .appendingPathComponent(record.filename)
    }

    func deleteAssets(envelopeIds: Set<String>) {
        guard !envelopeIds.isEmpty else { return }
        let directoryNames: [String] = (try? dbQueue.read { db in
            let records = try PendingDirectFileRecord
                .filter(envelopeIds.contains(Column("envelopeId")))
                .fetchAll(db)
            return records.map(\.storageDirectoryName)
        }) ?? []
        for directoryName in directoryNames {
            try? FileManager.default.removeItem(
                at: fileDirectoryURL(directoryName: directoryName)
            )
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

    private func sanitizedFilename(_ filename: String) -> String {
        let lastPathComponent = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lastPathComponent.isEmpty ? "file" : lastPathComponent
    }

    private func fileRootDirectoryURL() -> URL {
        let userId = UserDefaults.standard.string(forKey: "com.zyna.matrix.lastUserId")
        let directory = LocalDataProtection.outgoingFileDirectory(for: userId)
        _ = try? LocalDataProtection.createProtectedDirectory(
            at: directory,
            protection: .sensitive,
            excludeFromBackup: true
        )
        return directory
    }

    private func fileDirectoryURL(directoryName: String) -> URL {
        fileRootDirectoryURL().appendingPathComponent(directoryName, isDirectory: true)
    }
}
