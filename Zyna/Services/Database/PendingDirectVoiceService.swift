//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

private let logPendingDirectVoice = ScopedLog(.timeline, prefix: "[DirectRawVoiceTx]")

struct PendingDirectVoiceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingDirectVoice"

    var itemId: String
    var envelopeId: String
    var roomId: String
    var mimetype: String
    var uploadedVoiceJSON: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
}

struct PendingDirectVoiceCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
    let voice: PendingDirectVoiceRecord
    let payload: OutgoingVoicePayload
}

struct PendingDirectVoiceMissingRecordCandidate {
    let envelope: OutgoingEnvelopeSnapshot
    let item: OutgoingEnvelopeItemSnapshot
}

final class PendingDirectVoiceService {

    static let shared = PendingDirectVoiceService()

    private var dbQueue: DatabaseQueue { DatabaseService.shared.dbQueue }

    private init() {}

    func prepareVoice(
        envelopeId: String,
        itemIndex: Int,
        roomId: String,
        mimetype: String
    ) -> Bool {
        let itemId = OutgoingEnvelopeItemRecord.makeId(
            groupId: envelopeId,
            itemIndex: itemIndex
        )
        let now = Date().timeIntervalSince1970
        let record = PendingDirectVoiceRecord(
            itemId: itemId,
            envelopeId: envelopeId,
            roomId: roomId,
            mimetype: mimetype,
            uploadedVoiceJSON: nil,
            createdAt: now,
            updatedAt: now
        )

        do {
            try dbQueue.write { db in
                try record.save(db)
            }
            logPendingDirectVoice(
                "asset prepared envelope=\(envelopeId) item=\(itemIndex) mimetype=\(mimetype)"
            )
            return true
        } catch {
            logPendingDirectVoice(
                "asset prepare failed envelope=\(envelopeId) item=\(itemIndex) error=\(error)"
            )
            return false
        }
    }

    func record(itemId: String) -> PendingDirectVoiceRecord? {
        try? dbQueue.read { db in
            try PendingDirectVoiceRecord.fetchOne(db, key: itemId)
        }
    }

    func markUploaded(itemId: String, uploadedVoiceJSON: String) -> Bool {
        let didChange = (try? dbQueue.write { db in
            guard var record = try PendingDirectVoiceRecord.fetchOne(db, key: itemId) else {
                return false
            }
            let didChange = record.uploadedVoiceJSON != uploadedVoiceJSON
            record.uploadedVoiceJSON = uploadedVoiceJSON
            record.updatedAt = Date().timeIntervalSince1970
            try record.save(db)
            return didChange
        }) ?? false

        if didChange {
            logPendingDirectVoice(
                "asset uploaded item=\(itemId) uploadedBytes=\(uploadedVoiceJSON.count)"
            )
        }
        return didChange
    }

    func outboxCandidates(envelopeIds: Set<String>? = nil) -> [PendingDirectVoiceCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Column("kind") == OutgoingEnvelopeKind.voice.rawValue)
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
            let voices = try PendingDirectVoiceRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)
            let voicesByItemId = Dictionary(uniqueKeysWithValues: voices.map {
                ($0.itemId, $0)
            })

            return envelopes.compactMap { envelope -> PendingDirectVoiceCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let transactionId = item.transactionId,
                      !transactionId.isEmpty,
                      let voice = voicesByItemId[item.id],
                      let payload = snapshot.voicePayload,
                      payload.localFileName?.isEmpty == false,
                      Self.isOutboxState(item.transportState) else {
                    return nil
                }
                return PendingDirectVoiceCandidate(
                    envelope: snapshot,
                    item: item,
                    voice: voice,
                    payload: payload
                )
            }
        }) ?? []
    }

    func missingRecordCandidates(
        envelopeIds: Set<String>? = nil
    ) -> [PendingDirectVoiceMissingRecordCandidate] {
        if let envelopeIds, envelopeIds.isEmpty {
            return []
        }

        return (try? dbQueue.read { db in
            var request = OutgoingEnvelopeRecord
                .filter(Column("kind") == OutgoingEnvelopeKind.voice.rawValue)
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
            let voiceItemIds = Set(try PendingDirectVoiceRecord
                .filter(itemIds.contains(Column("itemId")))
                .fetchAll(db)
                .map(\.itemId))

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)

            return envelopes.compactMap { envelope -> PendingDirectVoiceMissingRecordCandidate? in
                let snapshot = OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
                guard let item = snapshot.primaryItem,
                      item.eventId == nil,
                      let transactionId = item.transactionId,
                      !transactionId.isEmpty,
                      !voiceItemIds.contains(item.id),
                      item.transportState == .queued else {
                    return nil
                }
                return PendingDirectVoiceMissingRecordCandidate(
                    envelope: snapshot,
                    item: item
                )
            }
        }) ?? []
    }

    private static func isOutboxState(_ state: OutgoingTransportState) -> Bool {
        switch state {
        case .queued, .uploading, .uploaded, .sending, .retrying:
            return true
        case .sent, .failed:
            return false
        }
    }
}
