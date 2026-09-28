//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

private let logMediaGroup = ScopedLog(.media, prefix: "[MediaGroup]")
private let logTimelineDB = ScopedLog(.database, prefix: "[TimelineDB]")

/// Accumulates SDK timeline diffs for 50 ms, then persists whole events
/// in bounded transactions on a serial worker. Maintains a shadow
/// array for positional diff handling (SDK diffs reference items by index).
// Pending SDK state belongs to processingQueue, writes to writeQueue, and
// onFlush is installed/read/cleared on main. Dependencies are immutable.
final class TimelineDiffBatcher: @unchecked Sendable {

    private let roomId: String
    private let dbQueue: AccountDatabase
    private let log = ScopedLog(.database)
    /// SDK mapping, JSON extraction and diff bookkeeping must never share
    /// the main queue with Texture scrolling.
    private let processingQueue = DispatchQueue(
        label: "com.zyna.timeline-diff-processing",
        qos: .userInitiated
    )
    private let writeQueue = DispatchQueue(label: "com.zyna.db.write", qos: .userInitiated)

    // MARK: - Shadow positions

    /// Mirrors the SDK timeline length/order so index-based diffs
    /// (`insert`, `set`, `remove`, `truncate`) can be validated against
    /// the previous SDK state. Durable identity lives in `StoredMessage`;
    /// the UTD identity schedules inspections, never positional deletion.
    /// Debug additionally retains identities for on-demand diagnostics.
    private struct ShadowPosition {
        var decryptionEventID: String?
        #if DEBUG
        var eventID: String?
        #endif
    }

    #if DEBUG
    private var diagnosticHistory = MessageDiagnosticHistory()

    func messageDiagnosticHistory(eventID: String?) async -> [String] {
        await withCheckedContinuation { continuation in
            processingQueue.async { [self] in
                continuation.resume(returning: diagnosticHistory.snapshot(eventID: eventID)
                    + ["pendingMappedEvents=\(pendingEvents.count)"])
            }
        }
    }
    #endif

    private var shadowPositions: [ShadowPosition] = []

    // MARK: - Pending ops

    enum DiffOp {
        case upsert(StoredMessage, isPollStart: Bool, senderProfile: PollSenderProfile)
        case deleteAttachment(eventId: String)
        case upsertMatrixRTCCall(StoredMatrixRTCCall)
        case upsertMatrixRTCMembership(StoredMatrixRTCCallMembership)
        case delete(id: String, eventId: String?)
        case inspectDecryption(eventId: String)
    }

    private var pendingEvents: [[DiffOp]] = []
    private var pendingFlushSummary = TimelineFlushSummary()
    private var debounceWork: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.05

    /// Timestamp of the newest own message read by someone else.
    /// Updated from TimelineService when SDK delivers read receipts.
    private var readCursorTimestamp: TimeInterval?

    /// Called on main queue after each successful flush.
    var onFlush: ((TimelineFlushSummary) -> Void)?
    /// Includes positional-only removals: these can hide a decrypted relation.
    var onDecryptionCandidatesChanged: (() -> Void)?
    let historyRevision = TimelineHistoryRevision()
    #if DEBUG
    private(set) var historyPerformance: HistoryPerformanceTrace.Session?
    private var projectionDiagnostics: MessageProjectionDiagnostics?

    func recheckProjectionAfterPagination() {
        guard let probe = projectionDiagnostics else { return }
        Task { await probe.recheckAfterPagination() }
    }

    func startHistoryPerformance() -> HistoryPerformanceTrace.Session? {
        historyPerformance = HistoryPerformanceTrace.start(roomID: roomId, database: dbQueue)
        return historyPerformance
    }
    #endif

    func makeHistoryRecovery() -> ChatHistoryRecovery {
        ChatHistoryRecovery(roomID: roomId, database: dbQueue)
    }

    func makeDecryptionRepair(room: Room, timeline: Timeline? = nil,
        didChange: @escaping @MainActor @Sendable (TimelineFlushSummary) -> Void
    ) -> MessageDecryptionRepair {
        #if DEBUG
        let probe = historyPerformance.map {
            MessageProjectionDiagnostics(roomID: roomId, trace: $0, lookup: timeline.map { timeline in
                { @Sendable eventID in try await timeline.getEventTimelineItemByEventId(eventId: eventID) }
            })
        }
        projectionDiagnostics = probe
        #endif
        return MessageDecryptionRepair(roomID: roomId, database: dbQueue, historyRevision: historyRevision,
            writeQueue: writeQueue,
            inspect: { eventID in
                let result = try await room.inspectTimelineEvent(eventId: eventID)
                #if DEBUG
                await probe?.record(result, requestedID: eventID)
                #endif
                return result
            }, projectionSDK: timeline.map { MessageProjectionRecovery.SDK(timeline: $0) }, didChange: didChange)
    }

    // MARK: - Init

    init(roomId: String, dbQueue: AccountDatabase) {
        self.roomId = roomId
        self.dbQueue = dbQueue
    }

    deinit {
        #if DEBUG
        PollCacheDiagnostics.log("timeline-batcher-deinit db=\(PollCacheDiagnostics.databaseKey(dbQueue.path)) room=\(PollCacheDiagnostics.key(roomId))")
        #endif
    }

    /// Update read cursor from SDK read receipts.
    func updateReadCursor(timestamp: TimeInterval) {
        processingQueue.async { [weak self] in
            guard let self, self.dbQueue.isActive else { return }
            if self.readCursorTimestamp == nil || timestamp > self.readCursorTimestamp! {
                self.readCursorTimestamp = timestamp
                self.pendingFlushSummary.readReceiptCount += 1
                self.scheduleFlush()
            }
        }
    }

    // MARK: - Public

    /// Called from the SDK listener thread with raw timeline diffs.
    func receive(diffs: [TimelineDiff]) {
        #if DEBUG
        let trace = historyPerformance
        let operation = trace?.begin(.mapQueue)
        #endif
        processingQueue.async { [weak self] in
            #if DEBUG
            operation?.move(to: .map)
            defer { operation?.finish() }
            trace?.count(.diffs, diffs.count)
            #endif
            guard let self, self.dbQueue.isActive else { return }
            let types = diffs.map { Self.diffName($0) }
            self.log("Received diffs: \(types.joined(separator: ", "))")
            for diff in diffs {
                self.recordSummary(for: diff)
                self.enqueueDiff(diff)
            }
            self.scheduleFlush()
        }
    }

    private static func diffName(_ diff: TimelineDiff) -> String {
        switch diff {
        case .append(let items): return "append(\(items.count))"
        case .pushBack: return "pushBack"
        case .pushFront: return "pushFront"
        case .insert(let idx, _): return "insert(\(idx))"
        case .set(let idx, _): return "set(\(idx))"
        case .remove(let idx): return "remove(\(idx))"
        case .popBack: return "popBack"
        case .popFront: return "popFront"
        case .reset(let items): return "reset(\(items.count))"
        case .truncate(let len): return "truncate(\(len))"
        case .clear: return "clear"
        }
    }

    /// Wait for mapped diffs and their pending writes without occupying the
    /// database connection. Used to backpressure background pagination.
    func synchronize() async {
        #if DEBUG
        let operation = historyPerformance?.begin(.barrier)
        defer { operation?.finish() }
        #endif
        await withCheckedContinuation { continuation in
            processingQueue.async { [self] in
                debounceWork?.cancel()
                debounceWork = nil
                flush()
                writeQueue.async { continuation.resume() }
            }
        }
    }

    // MARK: - Debounce

    private func scheduleFlush() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        debounceWork = work
        processingQueue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    // MARK: - Flush

    private func flush() {
        let events = pendingEvents
        pendingEvents.removeAll()
        let summary = pendingFlushSummary
        pendingFlushSummary = TimelineFlushSummary()
        let cursorTs = readCursorTimestamp
        readCursorTimestamp = nil
        guard !events.isEmpty || cursorTs != nil else { return }

        let roomId = self.roomId
        let dbQueue = self.dbQueue
        let historyRevision = self.historyRevision
        let currentUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        #if DEBUG
        let trace = historyPerformance
        let operation = trace?.begin(.writerQueue)
        #endif
        writeQueue.async { [weak self] in
            #if DEBUG
            operation?.move(to: .flush)
            defer { operation?.finish() }
            #endif
            defer {
                DispatchQueue.main.async { [weak self] in
                    guard dbQueue.isActive else { return }
                    self?.onDecryptionCandidatesChanged?()
                }
            }
            do {
                try Self.writeMappedEvents(events, roomId: roomId, database: dbQueue,
                    currentUserId: currentUserId, summary: summary, cursorTs: cursorTs,
                    historyRevision: historyRevision) { summary in
                    #if DEBUG
                    trace?.count(.upserts, summary.upsertCount)
                    #endif
                    DispatchQueue.main.async { [weak self] in
                        guard dbQueue.isActive else { return }
                        self?.onFlush?(summary)
                    }
                }
            } catch AccountDatabase.AccessError.retired {
                // The account was retired between enqueue or chunk boundaries.
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.log("Flush failed: \(error)")
                }
            }
        }
    }

    /// The SDK mapper groups each event with its derived records. A chunk
    /// boundary must never split a poll, attachment, or call from its message.
    /// This entry point also lets tests exercise the real persistence path.
    static func writeMappedEvents(
        _ events: [[DiffOp]], roomId: String, database: AccountDatabase,
        currentUserId: String, summary: TimelineFlushSummary,
        cursorTs: TimeInterval? = nil, historyRevision: TimelineHistoryRevision,
        limits: DatabaseWriteBatch.Limits = .init(),
        didCommit: (TimelineFlushSummary) -> Void
    ) throws {
        var committedSummary: TimelineFlushSummary?
        var chunkSummary = summary
        defer {
            // Preserve one UI refresh per SDK batch. If a later chunk fails,
            // publish the committed prefix instead of hiding valid changes.
            if let committedSummary { didCommit(committedSummary) }
        }
        var internalDeleteCount = 0
        var detachedIdentityCount = 0
        var admissionChanged = false
        var recoveredEventIDs = Set<String>()
        try DatabaseWriteBatch.write(events, to: database, source: "timeline", limits: limits,
            prepare: { db in
                internalDeleteCount = 0
                detachedIdentityCount = 0
                admissionChanged = false
                recoveredEventIDs.removeAll(keepingCapacity: true)
                historyRevision.observeCommit(summary, in: db)
            }, apply: { db, event in
                for op in event {
                    switch op {
                    case .upsert(var record, let isPollStart, let senderProfile):
                        if try MessageDecryptionRepairStore.suppresses(record, in: db) { continue }
                        var existing = try Self.existingStoredMessage(for: record, in: db)
                        Self.inheritExistingZynaAttributesIfNeeded(for: &record, existing: existing)
                        Self.inheritExistingPendingEditIfNeeded(for: &record, existing: existing)
                        let previousGroupDescription: String?
                        if record.isOutgoing, record.contentType == "image", LogConfig.enabled.contains(.media) {
                            previousGroupDescription = existing.flatMap {
                                StoredMessage.decodeZynaAttributes($0.zynaAttributesJSON).mediaGroup.map(describe(group:))
                            }
                        } else {
                            previousGroupDescription = nil
                        }
                        if record.eventId != nil, record.transactionId == nil, record.isOutgoing {
                            record.transactionId = try existing?.transactionId
                                ?? Self.findMatchingPendingTransactionId(for: record, in: db)
                            // Matching a new server echo may have revealed a local
                            // transaction row that was absent from the first lookup.
                            if existing == nil, record.transactionId != nil {
                                existing = try Self.existingStoredMessage(for: record, in: db)
                            }
                        }

                        let shouldLogDirectRawTextBind = Self.shouldLogDirectRawTextBind(
                            incoming: record,
                            existing: existing
                        )
                        let wasUnresolved = try existing.map {
                            try $0.decryptionFailure != nil || MessageDecryptionRepairStore.isPendingLegacy($0, in: db)
                        } ?? false
                        if let existing {
                            Self.applyMonotonicMerge(
                                existing: existing,
                                incoming: &record,
                                existingIsLegacyPlaceholder: wasUnresolved
                            )
                        }

                        if wasUnresolved, record.decryptionFailure == nil, let eventID = record.eventId {
                            recoveredEventIDs.insert(eventID)
                        }
                        if existing != nil, wasUnresolved != (record.decryptionFailure != nil), !admissionChanged {
                            admissionChanged = true
                            if !summary.hasHistoryOrResetShape && !summary.includesUnreportedHistory {
                                historyRevision.observeCommit(.init(includesUnreportedHistory: true), in: db)
                            }
                        }

                        if let eventId = record.eventId,
                           record.isOutgoing,
                           record.contentType == "text",
                           let transactionId = record.transactionId,
                           !transactionId.isEmpty,
                           shouldLogDirectRawTextBind {
                            logTimelineDB(
                                "DirectRawTx db bind text event=\(eventId) tx=\(transactionId) status=\(record.sendStatus)"
                            )
                        }

                        if let eventId = record.eventId {
                            let result = try Self.resolveEventIdDuplicates(
                                for: record,
                                eventId: eventId,
                                in: db
                            )
                            internalDeleteCount += result.deleted
                            detachedIdentityCount += result.detached
                        }
                        if let txnId = record.transactionId {
                            internalDeleteCount += try Self.deleteSafeTransactionDuplicates(
                                for: record,
                                transactionId: txnId,
                                in: db
                            )
                        }
                        Self.logMediaGroupUpsert(
                            record,
                            previousGroupDescription: previousGroupDescription
                        )
                        try PollStore.ingest(&record, isPollStart: isPollStart, senderProfile: senderProfile, in: db)
                        if record != existing || record.decryptionFailure != nil || record.isLegacyDecryptionCandidate {
                            try MessageDecryptionRepairStore.didProject(record, in: db)
                        }
                        if record != existing { try record.save(db) }
                        if let attachment = StoredRoomAttachment(storedMessage: record) {
                            try attachment.saveIfChanged(in: db)
                        }
                        if record.contentType == "redacted",
                           let eventId = record.eventId {
                            try Self.deleteMatrixRTCSidecars(
                                eventId: eventId,
                                currentUserId: currentUserId,
                                in: db
                            )
                        }
                    case .inspectDecryption(let eventId):
                        try MessageDecryptionRepairStore.retrySoon(eventID: eventId, roomID: roomId, in: db)
                    case .deleteAttachment(let eventId):
                        _ = try StoredRoomAttachment.deleteOne(
                            db,
                            key: ["roomId": roomId, "eventId": eventId]
                        )
                    case .upsertMatrixRTCCall(let record):
                        try StoredMatrixRTCCall.upsertAndRefreshProjection(
                            record,
                            currentUserId: currentUserId,
                            in: db
                        )
                    case .upsertMatrixRTCMembership(let record):
                        try StoredMatrixRTCCall.upsertMembershipAndRefreshCallProjections(
                            record,
                            currentUserId: currentUserId,
                            in: db
                        )
                    case .delete(let id, let eventId):
                        if let eventId,
                           !eventId.isEmpty {
                            try Self.deleteMatrixRTCSidecars(
                                eventId: eventId,
                                currentUserId: currentUserId,
                                in: db
                            )
                        }
                        _ = try StoredMessage.deleteOne(db, key: id)
                    }
                }
            }, finish: { db, range in
                // Mark all outgoing messages up to the read cursor as "read"
                if range.upperBound == events.count, let cursorTs {
                    try db.execute(
                        sql: """
                            UPDATE storedMessage
                            SET sendStatus = 'read'
                            WHERE roomId = ? AND isOutgoing = 1
                              AND eventId IS NOT NULL
                              AND eventId != ''
                              AND timestamp <= ? AND sendStatus != 'read'
                            """,
                        arguments: [roomId, cursorTs]
                    )
                }
                // Keep the source's live/history shape for every chunk;
                // row counts describe only this committed range.
                chunkSummary = summary
                chunkSummary.includesUnreportedHistory = summary.includesUnreportedHistory || admissionChanged
                chunkSummary.recoveredEventIDs.formUnion(recoveredEventIDs)
                chunkSummary.readReceiptCount = range.upperBound == events.count ? summary.readReceiptCount : 0
                let ops = events[range].flatMap { $0 }
                chunkSummary.upsertCount = ops.filter { if case .upsert = $0 { return true }; return false }.count
                chunkSummary.deleteCount = ops.filter { if case .delete = $0 { return true }; return false }.count
                chunkSummary.redactedUpsertCount = ops.filter {
                    if case .upsert(let record, _, _) = $0 { return record.contentType == "redacted" }
                    return false
                }.count
            }, didCommit: { _ in
                // The writer stays serial across chunks and complete flushes.
                // Revision changes remain visible to intervening snapshots
                // even though the UI notification waits for the whole batch.
                chunkSummary.committedHistoryRevision = historyRevision.current
                if var committed = committedSummary {
                    committed.upsertCount += chunkSummary.upsertCount
                    committed.deleteCount += chunkSummary.deleteCount
                    committed.redactedUpsertCount += chunkSummary.redactedUpsertCount
                    committed.readReceiptCount += chunkSummary.readReceiptCount
                    committed.committedHistoryRevision = chunkSummary.committedHistoryRevision
                    committed.includesUnreportedHistory = committed.includesUnreportedHistory || chunkSummary.includesUnreportedHistory
                    committed.recoveredEventIDs.formUnion(chunkSummary.recoveredEventIDs)
                    committedSummary = committed
                } else {
                    committedSummary = chunkSummary
                }
                logTimelineDB("Committed \(chunkSummary.upsertCount) upserts, \(chunkSummary.deleteCount) deletes; dedupe=\(internalDeleteCount) detached=\(detachedIdentityCount)")
            })
    }

    // MARK: - Enqueue

    private func recordSummary(for diff: TimelineDiff) {
        switch diff {
        case .append:
            pendingFlushSummary.appendCount += 1
        case .pushBack:
            pendingFlushSummary.pushBackCount += 1
        case .pushFront:
            pendingFlushSummary.pushFrontCount += 1
        case .insert:
            pendingFlushSummary.insertCount += 1
        case .set:
            pendingFlushSummary.setCount += 1
        case .remove:
            pendingFlushSummary.removeCount += 1
        case .popBack:
            pendingFlushSummary.removeCount += 1
        case .popFront:
            pendingFlushSummary.removeCount += 1
        case .reset:
            pendingFlushSummary.resetCount += 1
        case .truncate:
            pendingFlushSummary.truncateCount += 1
        case .clear:
            pendingFlushSummary.clearCount += 1
        }
    }

    private func enqueueDiff(_ diff: TimelineDiff) {
        switch diff {

        case .append(let items):
            for item in items {
                appendItem(item)
            }

        case .pushBack(let item):
            appendItem(item)

        case .pushFront(let item):
            let msg = TimelineService.mapTimelineItem(item)
            shadowPositions.insert(shadowPosition(for: item), at: 0)
            enqueueSidecarEvents(for: item, message: msg)

        case .insert(let index, let item):
            let idx = Int(index)
            guard idx <= shadowPositions.count else { return }
            let msg = TimelineService.mapTimelineItem(item)
            shadowPositions.insert(shadowPosition(for: item), at: idx)
            enqueueSidecarEvents(for: item, message: msg)

        case .set(let index, let item):
            let idx = Int(index)
            guard idx < shadowPositions.count else { return }
            let msg = TimelineService.mapTimelineItem(item)
            #if DEBUG
            diagnosticHistory.record("set/replacement", eventID: shadowPositions[idx].eventID)
            #endif
            let position = shadowPosition(for: item)
            if position.decryptionEventID != shadowPositions[idx].decryptionEventID {
                enqueueInspection(shadowPositions[idx])
            }
            shadowPositions[idx] = position
            enqueueSidecarEvents(for: item, message: msg)

        case .remove(let index):
            let idx = Int(index)
            guard idx < shadowPositions.count else { return }
            #if DEBUG
            diagnosticHistory.record("remove (DB row retained)", eventID: shadowPositions[idx].eventID)
            #endif
            enqueueInspection(shadowPositions.remove(at: idx))

        case .popBack:
            guard !shadowPositions.isEmpty else { return }
            #if DEBUG
            diagnosticHistory.record("popBack (DB row retained)", eventID: shadowPositions.last?.eventID)
            #endif
            enqueueInspection(shadowPositions.removeLast())

        case .popFront:
            guard !shadowPositions.isEmpty else { return }
            #if DEBUG
            diagnosticHistory.record("popFront (DB row retained)", eventID: shadowPositions.first?.eventID)
            #endif
            enqueueInspection(shadowPositions.removeFirst())

        case .reset(let items):
            #if DEBUG
            diagnosticHistory.record("reset previous=\(shadowPositions.count) incoming=\(items.count)")
            #endif
            let retained = Set(items.compactMap(Self.decryptionEventID))
            for position in shadowPositions where position.decryptionEventID.map({ !retained.contains($0) }) == true {
                enqueueInspection(position)
            }
            shadowPositions.removeAll()
            for item in items {
                appendItem(item)
            }

        case .truncate(let length):
            #if DEBUG
            diagnosticHistory.record("truncate previous=\(shadowPositions.count) incoming=\(length)")
            #endif
            let len = Int(length)
            while shadowPositions.count > len {
                enqueueInspection(shadowPositions.removeLast())
            }

        case .clear:
            #if DEBUG
            diagnosticHistory.record("clear previous=\(shadowPositions.count)")
            #endif
            for position in shadowPositions { enqueueInspection(position) }
            shadowPositions.removeAll()
        }
    }

    // MARK: - Helpers

    private func appendItem(_ item: TimelineItem) {
        let msg = TimelineService.mapTimelineItem(item)
        shadowPositions.append(shadowPosition(for: item))
        enqueueSidecarEvents(for: item, message: msg)
    }

    private func enqueueSidecarEvents(for item: TimelineItem, message: ChatMessage?) {
        var operations: [DiffOp] = []
        defer { if !operations.isEmpty { pendingEvents.append(operations) } }
        if let message {
            let record = StoredMessage(from: message, roomId: roomId)
            let isPollStart = message.content.isPoll || (message.content.isRedacted
                && PollStore.isPollStartEvent(originalJSON: item.asEvent()?.lazyProvider.debugInfo().originalJson))
            let senderProfile: PollSenderProfile
            if message.content.isPoll, case .ready(let name, _, _) = item.asEvent()?.senderProfile {
                senderProfile = .ready(name: name)
            } else {
                senderProfile = .unavailable
            }
            operations.append(.upsert(record, isPollStart: isPollStart, senderProfile: senderProfile))

            if let call = StoredMatrixRTCCall(from: message, roomId: roomId) {
                operations.append(.upsertMatrixRTCCall(call))
            }
        }

        guard let event = item.asEvent() else { return }

        if case .eventId(let eventId) = event.eventOrTransactionId,
           case .msgLike(let msgLike) = event.content,
           case .redacted = msgLike.kind {
            // Positional timeline removals only change the SDK window and
            // must not shrink the durable catalog. A redaction is the one
            // event-level removal that does invalidate the projection.
            operations.append(.deleteAttachment(eventId: eventId))
        }

        guard let membership = StoredMatrixRTCCallMembership.parse(
                from: event,
                roomId: roomId
              ) else {
            return
        }
        operations.append(.upsertMatrixRTCMembership(membership))
    }

    private func shadowPosition(for item: TimelineItem) -> ShadowPosition {
        var position = ShadowPosition(decryptionEventID: Self.decryptionEventID(item))
        #if DEBUG
        guard let event = item.asEvent(), case .eventId(let eventID) = event.eventOrTransactionId else {
            return position
        }
        diagnosticHistory.record("map kind=\(MessageDiagnostics.kind(event))", eventID: eventID)
        position.eventID = eventID
        #endif
        return position
    }

    private static func decryptionEventID(_ item: TimelineItem) -> String? {
        guard let event = item.asEvent(), case .eventId(let id) = event.eventOrTransactionId,
              case .msgLike(let message) = event.content, case .unableToDecrypt = message.kind else { return nil }
        return id
    }

    private func enqueueInspection(_ position: ShadowPosition) {
        if let id = position.decryptionEventID { pendingEvents.append([.inspectDecryption(eventId: id)]) }
    }

    private static func deleteMatrixRTCSidecars(
        eventId: String,
        currentUserId: String,
        in db: Database
    ) throws {
        _ = try StoredMatrixRTCCall.deleteOne(db, key: eventId)
        try StoredMatrixRTCCall.deleteMembershipAndRefreshCallProjections(
            eventId: eventId,
            currentUserId: currentUserId,
            in: db
        )
    }

    private static func inheritExistingZynaAttributesIfNeeded(
        for record: inout StoredMessage,
        existing: StoredMessage?
    ) {
        guard record.contentType == "redacted",
              (record.zynaAttributesJSON ?? "").isEmpty,
              let existing,
              let existingAttrs = existing.zynaAttributesJSON,
              !existingAttrs.isEmpty
        else {
            return
        }

        record.zynaAttributesJSON = existingAttrs
        if LogConfig.enabled.contains(.media),
           let group = StoredMessage.decodeZynaAttributes(existing.zynaAttributesJSON).mediaGroup {
            logMediaGroup(
                "db preserve redacted attrs item=\(record.eventId ?? record.transactionId ?? record.id) group=\(describe(group: group))"
            )
        }
    }

    private static func inheritExistingPendingEditIfNeeded(
        for record: inout StoredMessage,
        existing: StoredMessage?
    ) {
        guard record.isOutgoing else {
            return
        }

        if record.latestEditEventId?.isEmpty == false {
            record.isEditPending = false
            record.isEditFailed = false
            record.editTransactionId = nil
            record.pendingEditBody = nil
            record.pendingEditFormattedBody = nil
            record.pendingEditZynaAttributesJSON = nil
            return
        }

        guard let existing,
              existing.isEditPending || existing.isEditFailed
        else {
            return
        }

        if existing.isEditPending && !record.isEditPending {
            record.isEditPending = true
        }
        if existing.isEditFailed && !record.isEditPending {
            record.isEditFailed = true
        }
        if record.editTransactionId == nil {
            record.editTransactionId = existing.editTransactionId
        }
        if record.pendingEditBody == nil {
            record.pendingEditBody = existing.pendingEditBody
            record.pendingEditFormattedBody = existing.pendingEditFormattedBody
        }
        if record.pendingEditZynaAttributesJSON == nil {
            record.pendingEditZynaAttributesJSON = existing.pendingEditZynaAttributesJSON
        }
    }

    private static func existingStoredMessage(
        for record: StoredMessage,
        in db: Database
    ) throws -> StoredMessage? {
        if let existing = try StoredMessage.fetchOne(db, key: record.id) {
            return existing
        }
        if let eventId = record.eventId,
           !eventId.isEmpty {
            let candidates = try StoredMessage
            .filter(Column("roomId") == record.roomId && Column("eventId") == eventId)
            .fetchAll(db)
            if let existing = preferredExistingEventMessage(
                for: record,
                candidates: candidates
            ) {
                return existing
            }
        }
        if let transactionId = record.transactionId,
           !transactionId.isEmpty {
            let candidates = try StoredMessage
            .filter(Column("roomId") == record.roomId && Column("transactionId") == transactionId)
            .fetchAll(db)
            if let existing = candidates.first(where: {
                isSafeTransactionDuplicate($0, of: record)
            }) {
                return existing
            }
        }
        return nil
    }

    private static func shouldLogDirectRawTextBind(
        incoming: StoredMessage,
        existing: StoredMessage?
    ) -> Bool {
        guard incoming.isOutgoing,
              incoming.contentType == "text",
              incoming.eventId?.isEmpty == false,
              incoming.transactionId?.isEmpty == false else {
            return false
        }
        guard let existing else { return true }
        return existing.eventId != incoming.eventId
            || existing.transactionId != incoming.transactionId
    }

    private struct DedupeResult {
        var deleted = 0
        var detached = 0
    }

    private static func preferredExistingEventMessage(
        for record: StoredMessage,
        candidates: [StoredMessage]
    ) -> StoredMessage? {
        if let sameEvent = candidates.first(where: {
            isSafeEventDuplicate($0, of: record)
        }) {
            return sameEvent
        }
        return nil
    }

    private static func resolveEventIdDuplicates(
        for record: StoredMessage,
        eventId: String,
        in db: Database
    ) throws -> DedupeResult {
        let candidates = try StoredMessage
            .filter(
                Column("roomId") == record.roomId
                    && Column("eventId") == eventId
                    && Column("id") != record.id
            )
            .fetchAll(db)

        var result = DedupeResult()
        for candidate in candidates {
            if isSafeEventDuplicate(candidate, of: record) {
                logTimelineDB(
                    "event duplicate delete existing=\(describeForDedupe(candidate)) incoming=\(describeForDedupe(record))"
                )
                _ = try StoredMessage.deleteOne(db, key: candidate.id)
                result.deleted += 1
            } else {
                logTimelineDB(
                    "event duplicate detach existing=\(describeForDedupe(candidate)) incoming=\(describeForDedupe(record))"
                )
                if candidate.transactionId != nil,
                   candidate.transactionId == record.transactionId {
                    try db.execute(
                        sql: """
                            UPDATE storedMessage
                            SET eventId = NULL, transactionId = NULL
                            WHERE id = ?
                            """,
                        arguments: [candidate.id]
                    )
                } else {
                    try db.execute(
                        sql: """
                            UPDATE storedMessage
                            SET eventId = NULL
                            WHERE id = ?
                            """,
                        arguments: [candidate.id]
                    )
                }
                result.detached += 1
            }
        }
        return result
    }

    private static func deleteSafeTransactionDuplicates(
        for record: StoredMessage,
        transactionId: String,
        in db: Database
    ) throws -> Int {
        guard record.isOutgoing else { return 0 }

        let candidates = try StoredMessage
            .filter(
                Column("roomId") == record.roomId
                    && Column("transactionId") == transactionId
                    && Column("id") != record.id
                    && Column("isOutgoing") == true
                    && Column("senderId") == record.senderId
            )
            .fetchAll(db)

        var deleted = 0
        for candidate in candidates where isSafeTransactionDuplicate(
            candidate,
            of: record
        ) {
            logTimelineDB(
                "tx duplicate delete existing=\(describeForDedupe(candidate)) incoming=\(describeForDedupe(record))"
            )
            _ = try StoredMessage.deleteOne(db, key: candidate.id)
            deleted += 1
        }
        return deleted
    }

    private static func isSafeEventDuplicate(
        _ candidate: StoredMessage,
        of record: StoredMessage
    ) -> Bool {
        guard candidate.senderId == record.senderId else {
            return false
        }
        if abs(candidate.timestamp - record.timestamp) <= 0.05 {
            return true
        }
        return contentFingerprint(candidate) == contentFingerprint(record)
    }

    private static func isSafeTransactionDuplicate(
        _ candidate: StoredMessage,
        of record: StoredMessage
    ) -> Bool {
        guard candidate.senderId == record.senderId,
              candidate.isOutgoing == record.isOutgoing
        else {
            return false
        }
        if let candidateEventId = candidate.eventId,
           let recordEventId = record.eventId,
           candidateEventId != recordEventId {
            return false
        }
        if candidate.isOutgoing,
           candidate.transactionId != nil,
           candidate.transactionId == record.transactionId {
            return true
        }
        if candidate.contentType != record.contentType {
            return false
        }
        return contentFingerprint(candidate) == contentFingerprint(record)
    }

    private struct ContentFingerprint: Equatable {
        let contentType: String
        let body: String
        let caption: String
        let filename: String
        let mimetype: String
        let fileSize: Int64
        let imageWidth: Int64
        let imageHeight: Int64
        let videoWidth: Int64
        let videoHeight: Int64
        let videoDuration: TimeInterval
        let zynaAttributesJSON: String
    }

    private static func contentFingerprint(_ message: StoredMessage) -> ContentFingerprint {
        ContentFingerprint(
            contentType: message.contentType,
            body: message.contentBody ?? "",
            caption: message.contentCaption ?? "",
            filename: message.contentFilename ?? "",
            mimetype: message.contentMimetype ?? "",
            fileSize: message.contentFileSize ?? -1,
            imageWidth: message.contentImageWidth ?? -1,
            imageHeight: message.contentImageHeight ?? -1,
            videoWidth: message.contentVideoWidth ?? -1,
            videoHeight: message.contentVideoHeight ?? -1,
            videoDuration: message.contentVideoDuration ?? -1,
            zynaAttributesJSON: message.zynaAttributesJSON ?? ""
        )
    }

    private static func describeForDedupe(_ message: StoredMessage) -> String {
        let timestamp = String(format: "%.3f", message.timestamp)
        let detail = message.contentBody
            ?? message.contentCaption
            ?? message.contentFilename
            ?? "-"
        return "id=\(shortForDedupe(message.id)) event=\(shortForDedupe(message.eventId)) tx=\(shortForDedupe(message.transactionId)) type=\(message.contentType) out=\(message.isOutgoing) status=\(message.sendStatus) ts=\(timestamp) detail=\(shortForDedupe(detail))"
    }

    private static func shortForDedupe(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "-" }
        guard value.count > 22 else { return value }
        return "\(value.prefix(10))...\(value.suffix(8))"
    }

    private static func applyMonotonicMerge(
        existing: StoredMessage,
        incoming record: inout StoredMessage,
        existingIsLegacyPlaceholder: Bool
    ) {
        // Matrix eventId is the stable identity. The SDK timeline item id
        // can change after reset/pagination, so keep the first stored row id
        // and treat later snapshots of the same event/transaction as updates.
        record.id = existing.id
        if record.eventId == nil {
            record.eventId = existing.eventId
        }
        if record.transactionId == nil {
            record.transactionId = existing.transactionId
        }

        if record.decryptionFailure == .unavailable,
           existing.decryptionFailure == nil,
           !existingIsLegacyPlaceholder {
            // Cache replay can lack keys that were previously available.
            // Preserve the entire resolved projection, including relations,
            // pending edits, and media. Explicit trust failures still apply.
            var preserved = existing
            preserved.eventId = record.eventId
            preserved.transactionId = record.transactionId
            preserved.senderDisplayName = record.senderDisplayName ?? existing.senderDisplayName
            preserved.senderAvatarUrl = record.senderAvatarUrl ?? existing.senderAvatarUrl
            preserved.sendStatus = preferredSendStatus(existing.sendStatus, record.sendStatus)
            record = preserved
            return
        }

        if existing.contentType == "redacted",
           record.contentType != "redacted" {
            var preserved = existing
            preserved.senderDisplayName = record.senderDisplayName ?? existing.senderDisplayName
            preserved.senderAvatarUrl = record.senderAvatarUrl ?? existing.senderAvatarUrl
            preserved.sendStatus = preferredSendStatus(existing.sendStatus, record.sendStatus)
            preserved.reactionsJSON = record.reactionsJSON
            if preserved.eventId == nil {
                preserved.eventId = record.eventId
            }
            if preserved.transactionId == nil {
                preserved.transactionId = record.transactionId
            }
            record = preserved
            return
        }

        record.sendStatus = preferredSendStatus(existing.sendStatus, record.sendStatus)
        record.senderDisplayName = record.senderDisplayName ?? existing.senderDisplayName
        record.senderAvatarUrl = record.senderAvatarUrl ?? existing.senderAvatarUrl
        if (record.zynaAttributesJSON ?? "").isEmpty,
           let existingAttrs = existing.zynaAttributesJSON,
           !existingAttrs.isEmpty {
            record.zynaAttributesJSON = existingAttrs
        }

        if let sourceJSON = record.contentMediaJSON,
           sourceJSON == existing.contentMediaJSON {
            record.contentFilename = record.contentFilename ?? existing.contentFilename
            record.contentMimetype = record.contentMimetype ?? existing.contentMimetype
            record.contentFileSize = record.contentFileSize ?? existing.contentFileSize
            record.contentImageWidth = record.contentImageWidth ?? existing.contentImageWidth
            record.contentImageHeight = record.contentImageHeight ?? existing.contentImageHeight
            record.contentVideoWidth = record.contentVideoWidth ?? existing.contentVideoWidth
            record.contentVideoHeight = record.contentVideoHeight ?? existing.contentVideoHeight
            record.contentVideoDuration = record.contentVideoDuration ?? existing.contentVideoDuration
            record.contentVoiceDuration = record.contentVoiceDuration ?? existing.contentVoiceDuration
            record.contentVoiceWaveform = record.contentVoiceWaveform ?? existing.contentVoiceWaveform
            record.contentBlurhash = record.contentBlurhash ?? existing.contentBlurhash
            if existing.contentIsAnimated == true {
                record.contentIsAnimated = true
            }
            record.contentMediaIsEncrypted = record.contentMediaIsEncrypted
                ?? existing.contentMediaIsEncrypted

            if record.contentThumbnailMediaJSON == nil {
                record.contentThumbnailMediaJSON = existing.contentThumbnailMediaJSON
                record.contentThumbnailIsEncrypted = existing.contentThumbnailIsEncrypted
                record.contentThumbnailWidth = existing.contentThumbnailWidth
                record.contentThumbnailHeight = existing.contentThumbnailHeight
                record.contentThumbnailSize = existing.contentThumbnailSize
                record.contentThumbnailMimetype = existing.contentThumbnailMimetype
            } else if record.contentThumbnailMediaJSON == existing.contentThumbnailMediaJSON {
                record.contentThumbnailIsEncrypted = record.contentThumbnailIsEncrypted
                    ?? existing.contentThumbnailIsEncrypted
                record.contentThumbnailWidth = record.contentThumbnailWidth
                    ?? existing.contentThumbnailWidth
                record.contentThumbnailHeight = record.contentThumbnailHeight
                    ?? existing.contentThumbnailHeight
                record.contentThumbnailSize = record.contentThumbnailSize
                    ?? existing.contentThumbnailSize
                record.contentThumbnailMimetype = record.contentThumbnailMimetype
                    ?? existing.contentThumbnailMimetype
            }
        }

        guard existing.latestEditEventId?.isEmpty == false,
              record.latestEditEventId == nil,
              existing.contentType == record.contentType,
              record.contentType != "redacted"
        else {
            return
        }

        preserveContentFields(from: existing, into: &record)
        record.isEdited = true
        record.latestEditEventId = existing.latestEditEventId
    }

    private static func preferredSendStatus(_ existing: String, _ incoming: String) -> String {
        sendStatusRank(existing) >= sendStatusRank(incoming) ? existing : incoming
    }

    private static func sendStatusRank(_ status: String) -> Int {
        switch status {
        case "failed":
            return 0
        case "sending":
            return 1
        case "sent", "synced":
            return 2
        case "read":
            return 3
        default:
            return 1
        }
    }

    private static func preserveContentFields(
        from existing: StoredMessage,
        into record: inout StoredMessage
    ) {
        record.contentBody = existing.contentBody
        record.contentFormat = existing.contentFormat
        record.contentFormattedBody = existing.contentFormattedBody
        record.contentMediaJSON = existing.contentMediaJSON
        record.contentMediaIsEncrypted = existing.contentMediaIsEncrypted
        record.contentImageWidth = existing.contentImageWidth
        record.contentImageHeight = existing.contentImageHeight
        record.contentCaption = existing.contentCaption
        record.contentVoiceDuration = existing.contentVoiceDuration
        record.contentVoiceWaveform = existing.contentVoiceWaveform
        record.contentFilename = existing.contentFilename
        record.contentMimetype = existing.contentMimetype
        record.contentFileSize = existing.contentFileSize
        record.contentBlurhash = existing.contentBlurhash
        record.contentIsAnimated = existing.contentIsAnimated
        record.contentThumbnailMediaJSON = existing.contentThumbnailMediaJSON
        record.contentThumbnailIsEncrypted = existing.contentThumbnailIsEncrypted
        record.contentThumbnailWidth = existing.contentThumbnailWidth
        record.contentThumbnailHeight = existing.contentThumbnailHeight
        record.contentThumbnailSize = existing.contentThumbnailSize
        record.contentThumbnailMimetype = existing.contentThumbnailMimetype
        record.contentVideoWidth = existing.contentVideoWidth
        record.contentVideoHeight = existing.contentVideoHeight
        record.contentVideoDuration = existing.contentVideoDuration
        record.zynaAttributesJSON = existing.zynaAttributesJSON
    }

    private static func findMatchingPendingTransactionId(
        for record: StoredMessage,
        in db: Database
    ) throws -> String? {
        guard record.eventId != nil,
              record.transactionId == nil,
              record.isOutgoing,
              record.contentType != "redacted" else {
            return record.transactionId
        }

        if let transactionId = try findOutgoingEnvelopeTransactionId(
            for: record,
            in: db
        ) {
            logMediaGroup(
                "db match tx explicit item=\(record.eventId ?? record.id) tx=\(transactionId)"
            )
            return transactionId
        }

        if record.contentType == "image" {
            return try String.fetchOne(
                db,
                sql: """
                    SELECT transactionId
                    FROM storedMessage
                    WHERE roomId = ?
                      AND eventId IS NULL
                      AND transactionId IS NOT NULL
                      AND isOutgoing = 1
                      AND senderId = ?
                      AND contentType = 'image'
                      AND ABS(timestamp - ?) < 3
                      AND ifnull(contentCaption, '') = ?
                      AND ifnull(zynaAttributesJSON, '') = ?
                      AND (? = -1 OR ifnull(contentImageWidth, -1) = ? OR ifnull(contentImageWidth, -1) = -1)
                      AND (? = -1 OR ifnull(contentImageHeight, -1) = ? OR ifnull(contentImageHeight, -1) = -1)
                    ORDER BY ABS(timestamp - ?) ASC
                    LIMIT 1
                    """,
                arguments: [
                    record.roomId,
                    record.senderId,
                    record.timestamp,
                    record.contentCaption ?? "",
                    record.zynaAttributesJSON ?? "",
                    record.contentImageWidth ?? -1,
                    record.contentImageWidth ?? -1,
                    record.contentImageHeight ?? -1,
                    record.contentImageHeight ?? -1,
                    record.timestamp
                ]
            )
        }

        if record.contentType == "video" {
            return try String.fetchOne(
                db,
                sql: """
                    SELECT transactionId
                    FROM storedMessage
                    WHERE roomId = ?
                      AND eventId IS NULL
                      AND transactionId IS NOT NULL
                      AND isOutgoing = 1
                      AND senderId = ?
                      AND contentType = 'video'
                      AND ABS(timestamp - ?) < 600
                      AND ifnull(contentCaption, '') = ?
                      AND ifnull(contentFilename, '') = ?
                      AND ifnull(zynaAttributesJSON, '') = ?
                      AND (? = -1 OR ifnull(contentVideoWidth, -1) = ? OR ifnull(contentVideoWidth, -1) = -1)
                      AND (? = -1 OR ifnull(contentVideoHeight, -1) = ? OR ifnull(contentVideoHeight, -1) = -1)
                      AND (? < 0 OR ifnull(contentVideoDuration, -1) < 0 OR ABS(ifnull(contentVideoDuration, -1) - ?) < 0.5)
                      AND (? = '' OR ifnull(contentMimetype, '') = '' OR ifnull(contentMimetype, '') = ?)
                      AND (? = -1 OR ifnull(contentFileSize, -1) = ? OR ifnull(contentFileSize, -1) = -1)
                    ORDER BY ABS(timestamp - ?) ASC
                    LIMIT 1
                    """,
                arguments: [
                    record.roomId,
                    record.senderId,
                    record.timestamp,
                    record.contentCaption ?? "",
                    record.contentFilename ?? "",
                    record.zynaAttributesJSON ?? "",
                    record.contentVideoWidth ?? -1,
                    record.contentVideoWidth ?? -1,
                    record.contentVideoHeight ?? -1,
                    record.contentVideoHeight ?? -1,
                    record.contentVideoDuration ?? -1,
                    record.contentVideoDuration ?? -1,
                    record.contentMimetype ?? "",
                    record.contentMimetype ?? "",
                    record.contentFileSize ?? -1,
                    record.contentFileSize ?? -1,
                    record.timestamp
                ]
            )
        }

        return try String.fetchOne(
            db,
            sql: """
                SELECT transactionId
                FROM storedMessage
                WHERE roomId = ?
                  AND eventId IS NULL
                  AND transactionId IS NOT NULL
                  AND isOutgoing = 1
                  AND senderId = ?
                  AND contentType = ?
                  AND ABS(timestamp - ?) < 1
                  AND ifnull(contentBody, '') = ?
                  AND ifnull(contentCaption, '') = ?
                  AND ifnull(contentFilename, '') = ?
                  AND ifnull(contentMediaJSON, '') = ?
                  AND ifnull(zynaAttributesJSON, '') = ?
                ORDER BY ABS(timestamp - ?) ASC
                LIMIT 1
                """,
            arguments: [
                record.roomId,
                record.senderId,
                record.contentType,
                record.timestamp,
                record.contentBody ?? "",
                record.contentCaption ?? "",
                record.contentFilename ?? "",
                record.contentMediaJSON ?? "",
                record.zynaAttributesJSON ?? "",
                record.timestamp
            ]
        )
    }

    private static func findOutgoingEnvelopeTransactionId(
        for record: StoredMessage,
        in db: Database
    ) throws -> String? {
        guard record.isOutgoing,
              let eventId = record.eventId
        else {
            return nil
        }

        if let transactionId = try String.fetchOne(
            db,
            sql: """
                SELECT item.transactionId
                FROM pendingMediaGroupItem AS item
                JOIN pendingMediaGroup AS groupRecord
                  ON groupRecord.id = item.groupId
                WHERE groupRecord.roomId = ?
                  AND item.eventId = ?
                  AND item.transactionId IS NOT NULL
                LIMIT 1
                """,
            arguments: [record.roomId, eventId]
        ) {
            return transactionId
        }

        guard record.contentType == "image",
              let mediaGroup = StoredMessage.decodeZynaAttributes(record.zynaAttributesJSON).mediaGroup
        else {
            return nil
        }

        return try String.fetchOne(
            db,
            sql: """
                SELECT item.transactionId
                FROM pendingMediaGroupItem AS item
                JOIN pendingMediaGroup AS groupRecord
                  ON groupRecord.id = item.groupId
                WHERE groupRecord.roomId = ?
                  AND ifnull(groupRecord.kind, 'mediaBatch') = 'mediaBatch'
                  AND item.groupId = ?
                  AND item.itemIndex = ?
                  AND item.transactionId IS NOT NULL
                LIMIT 1
                """,
            arguments: [record.roomId, mediaGroup.id, mediaGroup.index]
        )
    }

    private static func logMediaGroupUpsert(
        _ record: StoredMessage,
        previousGroupDescription: String?
    ) {
        guard record.isOutgoing, record.contentType == "image", LogConfig.enabled.contains(.media) else { return }

        let newGroupDescription = StoredMessage.decodeZynaAttributes(record.zynaAttributesJSON).mediaGroup.map(describe(group:))
        let itemId = record.eventId ?? record.transactionId ?? record.id

        if previousGroupDescription != newGroupDescription {
            logMediaGroup(
                "db upsert image item=\(itemId) group=\(previousGroupDescription ?? "none")->\(newGroupDescription ?? "none") status=\(record.sendStatus)"
            )
        } else {
            logMediaGroup(
                "db upsert image item=\(itemId) group=\(newGroupDescription ?? "none") status=\(record.sendStatus)"
            )
        }
    }

    private static func describe(group: MediaGroupInfo) -> String {
        "\(group.id)#\(group.index + 1)/\(group.total) \(group.captionPlacement.rawValue)"
    }
}
