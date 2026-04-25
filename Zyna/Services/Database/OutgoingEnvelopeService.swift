//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

private let logMediaGroup = ScopedLog(.media, prefix: "[MediaGroup]")

final class OutgoingEnvelopeService {

    static let shared = OutgoingEnvelopeService(dbQueue: DatabaseService.shared.dbQueue)

    private let dbQueue: DatabaseQueue
    private let pendingBindingsQueue = DispatchQueue(
        label: "com.zyna.outgoingEnvelope.pendingBindings"
    )
    private var pendingBindings: [String: DeferredTransportBinding] = [:]

    private struct DeferredTransportBinding {
        var state: OutgoingTransportState?
        var eventId: String?
        var mediaSourceJSON: String?
    }

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    @discardableResult
    func createOutgoingText(
        roomId: String,
        envelopeId: String,
        body: String,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes()
    ) -> String {
        let item = makeEnvelopeItem(groupId: envelopeId, itemIndex: 0)
        createEnvelope(
            roomId: roomId,
            envelopeId: envelopeId,
            kind: .text,
            payload: .text(OutgoingTextPayload(body: body)),
            caption: nil,
            captionPlacement: .bottom,
            expectedItemCount: 1,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            items: [item]
        )
        logMediaGroup("outgoing create kind=text room=\(roomId) envelope=\(envelopeId)")
        return item.bindingToken ?? ""
    }

    @discardableResult
    func createOutgoingImage(
        roomId: String,
        envelopeId: String,
        caption: String?,
        width: UInt64?,
        height: UInt64?,
        previewImageData: Data?,
        previewSource: MediaSource? = nil,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes()
    ) -> String {
        let normalizedCaption = Self.normalizeCaption(caption)
        let item = makeEnvelopeItem(
            groupId: envelopeId,
            itemIndex: 0,
            mediaSource: previewSource,
            previewImageData: previewImageData,
            previewWidth: width,
            previewHeight: height
        )
        createEnvelope(
            roomId: roomId,
            envelopeId: envelopeId,
            kind: .image,
            payload: .image(
                OutgoingImagePayload(
                    caption: normalizedCaption,
                    width: width,
                    height: height
                )
            ),
            caption: normalizedCaption,
            captionPlacement: zynaAttributes.mediaGroup?.captionPlacement ?? .bottom,
            expectedItemCount: 1,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            items: [item]
        )
        logMediaGroup(
            "outgoing create kind=image room=\(roomId) envelope=\(envelopeId) caption=\(normalizedCaption ?? "<nil>")"
        )
        return item.bindingToken ?? ""
    }

    @discardableResult
    func createOutgoingVoice(
        roomId: String,
        envelopeId: String,
        duration: TimeInterval,
        waveform: [UInt16],
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes()
    ) -> String {
        let item = makeEnvelopeItem(groupId: envelopeId, itemIndex: 0)
        createEnvelope(
            roomId: roomId,
            envelopeId: envelopeId,
            kind: .voice,
            payload: .voice(
                OutgoingVoicePayload(
                    duration: duration,
                    waveform: waveform
                )
            ),
            caption: nil,
            captionPlacement: .bottom,
            expectedItemCount: 1,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            items: [item]
        )
        logMediaGroup(
            "outgoing create kind=voice room=\(roomId) envelope=\(envelopeId) duration=\(duration)"
        )
        return item.bindingToken ?? ""
    }

    @discardableResult
    func createOutgoingFile(
        roomId: String,
        envelopeId: String,
        filename: String,
        mimetype: String?,
        size: UInt64?,
        caption: String?,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes()
    ) -> String {
        let normalizedCaption = Self.normalizeCaption(caption)
        let item = makeEnvelopeItem(groupId: envelopeId, itemIndex: 0)
        createEnvelope(
            roomId: roomId,
            envelopeId: envelopeId,
            kind: .file,
            payload: .file(
                OutgoingFilePayload(
                    filename: filename,
                    mimetype: mimetype,
                    size: size,
                    caption: normalizedCaption
                )
            ),
            caption: normalizedCaption,
            captionPlacement: .bottom,
            expectedItemCount: 1,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            items: [item]
        )
        logMediaGroup(
            "outgoing create kind=file room=\(roomId) envelope=\(envelopeId) filename=\(filename)"
        )
        return item.bindingToken ?? ""
    }

    @discardableResult
    func createOutgoingMediaBatch(
        roomId: String,
        envelopeId: String,
        caption: String?,
        captionPlacement: CaptionPlacement,
        items draftItems: [OutgoingMediaDraftItem],
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes()
    ) -> [String] {
        guard draftItems.count > 1 else { return [] }

        let normalizedCaption = Self.normalizeCaption(caption)
        let items = draftItems.enumerated().map { index, draftItem in
            makeEnvelopeItem(
                groupId: envelopeId,
                itemIndex: index,
                previewImageData: draftItem.previewImageData,
                previewWidth: draftItem.width,
                previewHeight: draftItem.height
            )
        }
        createEnvelope(
            roomId: roomId,
            envelopeId: envelopeId,
            kind: .mediaBatch,
            payload: .mediaBatch(
                OutgoingMediaBatchPayload(
                    caption: normalizedCaption,
                    captionPlacement: captionPlacement,
                    expectedItemCount: draftItems.count
                )
            ),
            caption: normalizedCaption,
            captionPlacement: captionPlacement,
            expectedItemCount: draftItems.count,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            items: items
        )
        logMediaGroup(
            "outgoing create kind=mediaBatch room=\(roomId) envelope=\(envelopeId) items=\(draftItems.count) captionPlacement=\(captionPlacement.rawValue) caption=\(normalizedCaption ?? "<nil>")"
        )
        return items.compactMap(\.bindingToken)
    }

    @discardableResult
    func bindTransaction(envelopeId: String, itemIndex: Int, transactionId: String) -> Bool {
        (try? dbQueue.write { db in
            guard var item = try OutgoingEnvelopeItemRecord
                .filter(Column("groupId") == envelopeId && Column("itemIndex") == itemIndex)
                .fetchOne(db) else { return false }
            let pendingBinding = consumePendingBinding(for: transactionId)
            let didChange = item.transactionId != transactionId
                || item.bindingToken != nil
                || item.decodedTransportState != .sending
                || pendingBinding != nil
            item.bindingToken = nil
            item.transactionId = transactionId
            item.transportState = OutgoingTransportState.sending.rawValue
            if let pendingBinding {
                apply(pendingBinding: pendingBinding, to: &item)
            }
            try item.save(db)
            try recomputeEnvelopeState(id: item.groupId, in: db)
            return didChange
        }) ?? false
        .also {
            if $0 {
                logMediaGroup(
                    "outgoing bindTransaction envelope=\(envelopeId) index=\(itemIndex) tx=\(transactionId)"
                )
            }
        }
    }

    @discardableResult
    func bindReservedTransaction(bindingToken: String, transactionId: String) -> Bool {
        (try? dbQueue.write { db in
            guard var item = try OutgoingEnvelopeItemRecord
                .filter(Column("bindingToken") == bindingToken)
                .fetchOne(db) else { return false }
            let pendingBinding = consumePendingBinding(for: transactionId)
            let didChange = item.transactionId != transactionId
                || item.bindingToken != nil
                || item.decodedTransportState != .sending
                || pendingBinding != nil
            item.bindingToken = nil
            item.transactionId = transactionId
            item.transportState = OutgoingTransportState.sending.rawValue
            if let pendingBinding {
                apply(pendingBinding: pendingBinding, to: &item)
            }
            try item.save(db)
            try recomputeEnvelopeState(id: item.groupId, in: db)
            return didChange
        }) ?? false
        .also {
            if $0 {
                logMediaGroup("outgoing bindReserved token=\(bindingToken) tx=\(transactionId)")
            }
        }
    }

    @discardableResult
    func markDispatchFailed(envelopeId: String, itemIndex: Int) -> Bool {
        (try? dbQueue.write { db in
            guard var item = try OutgoingEnvelopeItemRecord
                .filter(Column("groupId") == envelopeId && Column("itemIndex") == itemIndex)
                .fetchOne(db) else { return false }
            guard item.decodedTransportState != .failed else { return false }
            item.bindingToken = nil
            item.transportState = OutgoingTransportState.failed.rawValue
            try item.save(db)
            try recomputeEnvelopeState(id: item.groupId, in: db)
            return true
        }) ?? false
        .also {
            if $0 {
                logMediaGroup("outgoing markFailed envelope=\(envelopeId) index=\(itemIndex)")
            }
        }
    }

    @discardableResult
    func markDispatchStarted(envelopeId: String, itemIndex: Int) -> Bool {
        (try? dbQueue.write { db in
            guard var item = try OutgoingEnvelopeItemRecord
                .filter(Column("groupId") == envelopeId && Column("itemIndex") == itemIndex)
                .fetchOne(db) else { return false }
            guard item.decodedTransportState == .queued else { return false }
            item.transportState = OutgoingTransportState.sending.rawValue
            try item.save(db)
            try recomputeEnvelopeState(id: item.groupId, in: db)
            return true
        }) ?? false
        .also {
            if $0 {
                logMediaGroup("outgoing markStarted envelope=\(envelopeId) index=\(itemIndex)")
            }
        }
    }

    @discardableResult
    func handleSendQueueUpdate(roomId: String, update: RoomSendQueueUpdate) -> Bool {
        switch update {
        case .newLocalEvent(let transactionId):
            return updateTransportState(transactionId: transactionId, state: .sending)
        case .replacedLocalEvent(let transactionId):
            return updateTransportState(transactionId: transactionId, state: .sending)
        case .sendError(let transactionId, _, let isRecoverable):
            return updateTransportState(
                transactionId: transactionId,
                state: isRecoverable ? .retrying : .failed
            )
        case .retryEvent(let transactionId):
            return updateTransportState(transactionId: transactionId, state: .retrying)
        case .sentEvent(let transactionId, let eventId):
            return bindEvent(transactionId: transactionId, eventId: eventId)
        case .mediaUpload(let relatedTo, let file, _, _):
            if let file {
                return bindMediaSource(transactionId: relatedTo, mediaSource: file)
            }
            return updateTransportState(transactionId: relatedTo, state: .uploading)
        case .cancelledLocalEvent(let transactionId):
            return deleteEnvelope(containingTransactionId: transactionId, roomId: roomId)
        }
    }

    func mediaBatchEnvelopes(roomId: String) -> [OutgoingEnvelopeSnapshot] {
        envelopes(roomId: roomId, kind: .mediaBatch)
    }

    func envelopes(roomId: String, kind: OutgoingEnvelopeKind? = nil) -> [OutgoingEnvelopeSnapshot] {
        (try? dbQueue.read { db in
            let envelopes = try OutgoingEnvelopeRecord
                .filter(Column("roomId") == roomId)
                .order(Column("createdAt").desc)
                .fetchAll(db)

            guard !envelopes.isEmpty else { return [] }

            let groupIds = envelopes.map(\.id)
            let items = try OutgoingEnvelopeItemRecord
                .filter(groupIds.contains(Column("groupId")))
                .order(Column("itemIndex").asc)
                .fetchAll(db)

            let itemsByGroupId = Dictionary(grouping: items, by: \.groupId)
            let snapshots = envelopes.map { envelope in
                OutgoingEnvelopeSnapshot(
                    record: envelope,
                    items: itemsByGroupId[envelope.id] ?? []
                )
            }
            guard let kind else { return snapshots }
            return snapshots.filter { $0.kind == kind }
        }) ?? []
    }

    func deleteEnvelopes(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        try? dbQueue.write { db in
            _ = try OutgoingEnvelopeRecord
                .filter(ids.contains(Column("id")))
                .deleteAll(db)
        }
        logMediaGroup("outgoing retire ids=\(ids.sorted().joined(separator: ","))")
    }

    private func createEnvelope(
        roomId: String,
        envelopeId: String,
        kind: OutgoingEnvelopeKind,
        payload: OutgoingEnvelopePayload,
        caption: String?,
        captionPlacement: CaptionPlacement,
        expectedItemCount: Int,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes,
        items: [OutgoingEnvelopeItemRecord]
    ) {
        let envelope = OutgoingEnvelopeRecord(
            id: envelopeId,
            roomId: roomId,
            caption: caption,
            captionPlacement: captionPlacement.rawValue,
            expectedItemCount: expectedItemCount,
            createdAt: Date().timeIntervalSince1970,
            replyEventId: replyInfo?.eventId,
            replySenderId: replyInfo?.senderId,
            replySenderName: replyInfo?.senderDisplayName,
            replyBody: replyInfo?.body,
            kind: kind.rawValue,
            state: OutgoingTransportState.queued.rawValue,
            payloadJSON: payload.encodeJSON(),
            zynaAttributesJSON: StoredMessage.encodeZynaAttributes(zynaAttributes)
        )

        try? dbQueue.write { db in
            try envelope.save(db)
            for item in items {
                try item.save(db)
            }
        }
    }

    private func makeEnvelopeItem(
        groupId: String,
        itemIndex: Int,
        mediaSource: MediaSource? = nil,
        previewImageData: Data? = nil,
        previewWidth: UInt64? = nil,
        previewHeight: UInt64? = nil
    ) -> OutgoingEnvelopeItemRecord {
        OutgoingEnvelopeItemRecord(
            id: OutgoingEnvelopeItemRecord.makeId(groupId: groupId, itemIndex: itemIndex),
            groupId: groupId,
            itemIndex: itemIndex,
            bindingToken: UUID().uuidString,
            transactionId: nil,
            eventId: nil,
            mediaSourceJSON: mediaSource?.toJson(),
            previewImageData: previewImageData,
            previewWidth: previewWidth.map { Int64(clamping: $0) },
            previewHeight: previewHeight.map { Int64(clamping: $0) },
            transportState: OutgoingTransportState.queued.rawValue
        )
    }

    private static func normalizeCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bindEvent(transactionId: String, eventId: String) -> Bool {
        (try? dbQueue.write { db in
            guard var item = try OutgoingEnvelopeItemRecord
                .filter(Column("transactionId") == transactionId)
                .fetchOne(db) else {
                    stashPendingBinding(
                        for: transactionId,
                        mutate: { binding in
                            binding.eventId = eventId
                            binding.state = .sent
                        }
                    )
                    return false
                }
            let didChange = item.eventId != eventId
                || item.decodedTransportState != .sent
            item.eventId = eventId
            item.transportState = OutgoingTransportState.sent.rawValue
            try item.save(db)
            try recomputeEnvelopeState(id: item.groupId, in: db)
            return didChange
        }) ?? false
        .also {
            if $0 {
                logMediaGroup("outgoing bindEvent tx=\(transactionId) event=\(eventId)")
            }
        }
    }

    private func bindMediaSource(transactionId: String, mediaSource: MediaSource) -> Bool {
        let mediaSourceJSON = mediaSource.toJson()
        return (try? dbQueue.write { db in
            guard var item = try OutgoingEnvelopeItemRecord
                .filter(Column("transactionId") == transactionId)
                .fetchOne(db) else {
                    stashPendingBinding(
                        for: transactionId,
                        mutate: { binding in
                            binding.mediaSourceJSON = mediaSourceJSON
                            binding.state = .uploading
                        }
                    )
                    return false
                }
            let didChange = item.mediaSourceJSON != mediaSourceJSON
                || item.decodedTransportState != .uploading
            item.mediaSourceJSON = mediaSourceJSON
            item.transportState = OutgoingTransportState.uploading.rawValue
            try item.save(db)
            try recomputeEnvelopeState(id: item.groupId, in: db)
            return didChange
        }) ?? false
        .also {
            if $0 {
                logMediaGroup("outgoing bindMediaSource tx=\(transactionId) url=\(mediaSource.url())")
            }
        }
    }

    private func updateTransportState(transactionId: String, state: OutgoingTransportState) -> Bool {
        (try? dbQueue.write { db in
            guard var item = try OutgoingEnvelopeItemRecord
                .filter(Column("transactionId") == transactionId)
                .fetchOne(db) else {
                    stashPendingBinding(
                        for: transactionId,
                        mutate: { binding in
                            binding.state = state
                        }
                    )
                    return false
                }
            guard item.decodedTransportState != state else { return false }
            item.transportState = state.rawValue
            try item.save(db)
            try recomputeEnvelopeState(id: item.groupId, in: db)
            return true
        }) ?? false
        .also {
            if $0 {
                logMediaGroup("outgoing state tx=\(transactionId) state=\(state.rawValue)")
            }
        }
    }

    private func deleteEnvelope(containingTransactionId transactionId: String, roomId: String) -> Bool {
        (try? dbQueue.write { db in
            guard let item = try OutgoingEnvelopeItemRecord
                .filter(Column("transactionId") == transactionId)
                .fetchOne(db),
                  let envelope = try OutgoingEnvelopeRecord
                    .filter(Column("id") == item.groupId && Column("roomId") == roomId)
                    .fetchOne(db) else { return false }
            return try OutgoingEnvelopeRecord.deleteOne(db, key: envelope.id)
        }) ?? false
        .also {
            if $0 {
                logMediaGroup("outgoing delete cancelled room=\(roomId) tx=\(transactionId)")
            }
        }
    }

    private func stashPendingBinding(
        for transactionId: String,
        mutate: (inout DeferredTransportBinding) -> Void
    ) {
        pendingBindingsQueue.sync {
            var binding = pendingBindings[transactionId] ?? DeferredTransportBinding()
            mutate(&binding)
            pendingBindings[transactionId] = binding
        }
    }

    private func consumePendingBinding(for transactionId: String) -> DeferredTransportBinding? {
        pendingBindingsQueue.sync {
            let binding = pendingBindings[transactionId]
            pendingBindings[transactionId] = nil
            return binding
        }
    }

    private func apply(
        pendingBinding: DeferredTransportBinding,
        to item: inout OutgoingEnvelopeItemRecord
    ) {
        if let eventId = pendingBinding.eventId {
            item.eventId = eventId
        }
        if let mediaSourceJSON = pendingBinding.mediaSourceJSON {
            item.mediaSourceJSON = mediaSourceJSON
        }
        if let state = pendingBinding.state {
            item.transportState = state.rawValue
        }
    }

    private func recomputeEnvelopeState(id: String, in db: Database) throws {
        guard var envelope = try OutgoingEnvelopeRecord.fetchOne(db, key: id) else { return }
        let items = try OutgoingEnvelopeItemRecord
            .filter(Column("groupId") == id)
            .fetchAll(db)
        let itemStates = items.map(\.decodedTransportState)
        let nextState: OutgoingTransportState
        if itemStates.contains(.failed) {
            nextState = .failed
        } else if itemStates.contains(.retrying) {
            nextState = .retrying
        } else if itemStates.contains(.uploading) {
            nextState = .uploading
        } else if itemStates.contains(.sending) {
            nextState = .sending
        } else if !itemStates.isEmpty && itemStates.allSatisfy({ $0 == .sent }) {
            nextState = .sent
        } else {
            nextState = .queued
        }

        guard envelope.decodedState != nextState else { return }
        envelope.state = nextState.rawValue
        try envelope.save(db)
    }
}

private extension Bool {
    func also(_ body: (Bool) -> Void) -> Bool {
        body(self)
        return self
    }
}
