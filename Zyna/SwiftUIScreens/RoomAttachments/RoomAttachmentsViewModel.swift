//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import GRDB
import MatrixRustSDK
import UIKit

private let log = ScopedLog(.attachments, prefix: "[Attachments]")

/// Queue-confined merge state for the durable catalog plus records whose
/// write is still waiting behind other GRDB work.
struct RoomAttachmentCatalogState {
    private var indexed: [String: StoredRoomAttachment] = [:]
    private var optimistic: [String: StoredRoomAttachment] = [:]
    private var tombstones: Set<String> = []
    private(set) var hasIndexedSnapshot = false

    mutating func replaceIndexed(with records: [StoredRoomAttachment]) {
        var next: [String: StoredRoomAttachment] = [:]
        next.reserveCapacity(records.count)
        for record in records {
            next[record.eventId] = record
        }

        // Presence in an observation acknowledges an optimistic upsert.
        let acknowledged = optimistic.keys.filter { next[$0] != nil }
        for eventId in acknowledged {
            optimistic.removeValue(forKey: eventId)
        }
        // Absence acknowledges an explicit delete. Until then a concurrent
        // unrelated observation must not resurrect the redacted item.
        tombstones.formIntersection(next.keys)
        indexed = next
        hasIndexedSnapshot = true
    }

    @discardableResult
    mutating func upsertOptimistically(_ records: [StoredRoomAttachment]) -> Bool {
        var changed = false
        for record in records {
            if tombstones.remove(record.eventId) != nil {
                changed = true
            }
            // Existing rows can keep their current metadata for the few
            // milliseconds until GRDB confirms the merge. The latency-sensitive
            // case is a newly decrypted event that has no visible tile yet.
            if indexed[record.eventId] == nil {
                let candidate = optimistic[record.eventId]
                    .map { record.mergingMetadata(from: $0) }
                    ?? record
                if optimistic[record.eventId] != candidate {
                    optimistic[record.eventId] = candidate
                    changed = true
                }
            }
        }
        return changed
    }

    @discardableResult
    mutating func invalidate(eventIds: [String]) -> Bool {
        var changed = false
        for eventId in eventIds {
            if optimistic.removeValue(forKey: eventId) != nil {
                changed = true
            }
            if indexed[eventId] != nil, tombstones.insert(eventId).inserted {
                changed = true
            }
        }
        return changed
    }

    var visibleRecords: [StoredRoomAttachment] {
        var records = indexed.compactMap { eventId, record in
            tombstones.contains(eventId) ? nil : record
        }
        records.append(contentsOf: optimistic.values)
        records.sort {
            if $0.timestampMs == $1.timestampMs {
                return $0.eventId > $1.eventId
            }
            return $0.timestampMs > $1.timestampMs
        }
        return records
    }
}

private struct RoomAttachmentCatalogSnapshot: Equatable {
    let recordCount: Int
    let media: [AttachmentMonthGroup]
    let files: [AttachmentMonthGroup]
    let mediaCount: Int
    let fileCount: Int
    let hasIndexedSnapshot: Bool
    let mapMs: Double

    static func == (
        lhs: RoomAttachmentCatalogSnapshot,
        rhs: RoomAttachmentCatalogSnapshot
    ) -> Bool {
        lhs.recordCount == rhs.recordCount
            && lhs.media == rhs.media
            && lhs.files == rhs.files
            && lhs.mediaCount == rhs.mediaCount
            && lhs.fileCount == rhs.fileCount
            && lhs.hasIndexedSnapshot == rhs.hasIndexedSnapshot
    }
}

/// Builds catalog sections away from the main actor. A one-frame coalescing
/// window absorbs bursts of late decryptions without delaying a tile on GRDB.
private final class RoomAttachmentCatalogProjection: @unchecked Sendable {
    private static let publishDelay: TimeInterval = 0.016

    private let queue = DispatchQueue(
        label: "com.zyna.attachments.catalog-projection",
        qos: .userInitiated
    )
    private var state = RoomAttachmentCatalogState()
    private var onChange: ((RoomAttachmentCatalogSnapshot) -> Void)?
    private var lastSnapshot: RoomAttachmentCatalogSnapshot?
    private var publishScheduled = false
    private var isStopped = false

    func setOnChange(_ callback: @escaping (RoomAttachmentCatalogSnapshot) -> Void) {
        queue.async { [self] in
            guard !isStopped else { return }
            onChange = callback
        }
    }

    func replaceIndexed(with records: [StoredRoomAttachment]) {
        queue.async { [self] in
            guard !isStopped else { return }
            state.replaceIndexed(with: records)
            schedulePublish()
        }
    }

    func upsertOptimistically(_ records: [StoredRoomAttachment]) {
        guard !records.isEmpty else { return }
        queue.async { [self] in
            guard !isStopped else { return }
            if state.upsertOptimistically(records) {
                schedulePublish()
            }
        }
    }

    func invalidate(eventIds: [String]) {
        guard !eventIds.isEmpty else { return }
        queue.async { [self] in
            guard !isStopped else { return }
            if state.invalidate(eventIds: eventIds) {
                schedulePublish()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            onChange = nil
        }
    }

    private func schedulePublish() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + Self.publishDelay) { [self] in
            publishScheduled = false
            publishIfChanged()
        }
    }

    private func publishIfChanged() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopped else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let records = state.visibleRecords
        let items = records.compactMap { $0.makeAttachmentItem() }
        let mediaItems = items.filter { $0.kind.isVisual }
        let fileItems = items.filter { !$0.kind.isVisual }
        let snapshot = RoomAttachmentCatalogSnapshot(
            recordCount: records.count,
            media: AttachmentTimelineStore.groupByMonth(mediaItems),
            files: AttachmentTimelineStore.groupByMonth(fileItems),
            mediaCount: mediaItems.count,
            fileCount: fileItems.count,
            hasIndexedSnapshot: state.hasIndexedSnapshot,
            mapMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        guard let onChange else { return }
        DispatchQueue.main.async {
            onChange(snapshot)
        }
    }
}

@MainActor
final class RoomAttachmentsViewModel: ObservableObject {

    enum Tab: String, CaseIterable, Identifiable {
        case media
        case files

        var id: String { rawValue }

        var title: String {
            switch self {
            case .media: return String(localized: "Media")
            case .files: return String(localized: "Files")
            }
        }
    }

    enum FillState: Equatable {
        case idle
        case filling(batch: Int)
        /// Pagination is done; waiting for the timeline's item pipeline,
        /// which lags behind the event cache, to stop producing diffs.
        case settling
        /// Start of the room reached; nothing older exists.
        case exhausted
        /// The bounded fill ended before finding a full page.
        case capped
        case failed(String)
    }

    static let mediaPageSize = 45
    static let filesPageSize = 20
    static let batchEvents: UInt16 = 100
    /// Maximum uninterrupted search per fill. Sparse history then requires
    /// an explicit "Load More" instead of being traversed without a bound.
    nonisolated static let defaultFillTimeBudgetSeconds: CFTimeInterval = 2.5
    /// Safety ceiling for unexpectedly fast cached pagination; the time
    /// budget normally ends a fill first.
    static let maxBatchesPerFill = 200
    /// How long a batch waits for its diff. With `.all` every batch yields a
    /// diff and after a network page the SDK first builds ~100 items, so the
    /// wait is generous and normally ends early. With `.onlyMessage` a disk
    /// chunk without attachments yields **no diff at all** (normal SDK
    /// behaviour) and the SDK itself needs only ~15–20 ms per chunk, so the
    /// wait must be a fraction of that: `paginateBackwards` returns once the
    /// chunk is in the event cache and a diff, if any, lands within
    /// milliseconds while the next call is already running. Overshooting the
    /// target by a chunk is cheap; a late diff is attributed to the next batch.
    static let snapshotWaitMsAllFilter = 1000
    /// One poll: with settling guarding the tail, the per-batch wait only
    /// serves attribution and the target check, and 35 chunks × 20 ms was
    /// 40 % of a cold start.
    static let snapshotWaitMsOnlyMessage = 10
    static let snapshotPollMs = 10
    /// `paginateBackwards` returns when the event cache has the chunk; the
    /// timeline turns events into items in its own task and, under a tight
    /// loop, falls seconds behind. A fill therefore ends only after the
    /// snapshots have been quiet for this long (bounded by `settleMaxMs`).
    static let settleQuietMs = 500
    static let settleMaxMs = 6000

    private var snapshotWaitMs: Int {
        filterMode == .sdkOnlyMessage ? Self.snapshotWaitMsOnlyMessage : Self.snapshotWaitMsAllFilter
    }
    static let initialSnapshotWaitMs = 300

    @Published var tab: Tab = .media {
        didSet {
            guard tab != oldValue else { return }
            if needsInitialPage(for: tab) {
                fillIfNeeded(reason: "tab", force: true, intent: .tab)
            }
        }
    }
    @Published private(set) var media: [AttachmentMonthGroup] = []
    @Published private(set) var files: [AttachmentMonthGroup] = []
    @Published private(set) var isInitialLoading = true
    @Published private(set) var fillState: FillState = .idle
    @Published private(set) var sdkPaginationStatus: PaginationStatus?
    @Published private(set) var pendingDecryptionCount = 0
    @Published private(set) var startError: String?
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published var downloadError: String?
    @Published private(set) var forceLoadIds: Set<String> = []
    @Published var fullFileThreshold: UInt64 = AttachmentThumbnailPlan.defaultFullFileThreshold
    #if DEBUG
    @Published private(set) var diagnostics = RoomAttachmentsDiagnostics()
    #endif

    let roomId: String
    let tilePixelSize: Int
    let filterMode: AttachmentSourceFilterMode
    let fillTimeBudgetSeconds: CFTimeInterval

    private let source: AttachmentSource
    private let attachmentIndex: RoomAttachmentIndex?
    private let catalogProjection: RoomAttachmentCatalogProjection?
    private let room: Room?
    private let openedAt = Date()
    private var hasStarted = false
    private var isStopped = false
    private var hitStart = false
    private var sentinelVisible = false
    private var fillTask: Task<Void, Never>?
    private var lateRetryTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var researchObserver: NSObjectProtocol?
    private var attachmentObservation: AnyDatabaseCancellable?
    private var hasReceivedIndexSnapshot = false
    private var indexedMediaCount = 0
    private var indexedFileCount = 0
    private var lastSnapshotGeneration = 0
    private var rowCount = 0
    private var mediaCount = 0
    private var fileCount = 0
    private var pendingSessionIds: [String] = []
    /// Decryptions seen so far; the stall detector watches this, not the
    /// pending count, which keeps growing while the chat paginates.
    private var resolvedUtdCount = 0

    init(
        roomId: String,
        source: AttachmentSource,
        filterMode: AttachmentSourceFilterMode,
        tilePixelSize: Int,
        attachmentIndex: RoomAttachmentIndex? = nil,
        room: Room? = nil,
        fillTimeBudgetSeconds: CFTimeInterval = RoomAttachmentsViewModel.defaultFillTimeBudgetSeconds
    ) {
        self.roomId = roomId
        self.source = source
        self.attachmentIndex = attachmentIndex
        catalogProjection = attachmentIndex == nil
            ? nil
            : RoomAttachmentCatalogProjection()
        self.filterMode = filterMode
        self.tilePixelSize = tilePixelSize
        self.room = room
        self.fillTimeBudgetSeconds = fillTimeBudgetSeconds
    }

    convenience init(room: Room, filterMode: AttachmentSourceFilterMode, tilePixelSize: Int) {
        let attachmentIndex = RoomAttachmentIndex(
            roomId: room.id(),
            dbQueue: DatabaseService.shared.dbQueue
        )
        self.init(
            roomId: room.id(),
            source: SDKTimelineAttachmentSource(
                room: room,
                filterMode: filterMode,
                attachmentIndex: attachmentIndex
            ),
            filterMode: filterMode,
            tilePixelSize: tilePixelSize,
            attachmentIndex: attachmentIndex,
            room: room
        )
    }

    deinit {
        fillTask?.cancel()
        lateRetryTask?.cancel()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let researchObserver {
            NotificationCenter.default.removeObserver(researchObserver)
        }
        attachmentObservation?.cancel()
        catalogProjection?.stop()
        source.stop()
        log("deinit room=\(roomId)")
    }

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true

        source.onSnapshot = { [weak self] snapshot, summary in
            self?.handle(snapshot, summary)
        }
        source.onPaginationStatus = { [weak self] status in
            self?.handlePaginationStatus(status)
        }
        if let attachmentIndex, let catalogProjection {
            catalogProjection.setOnChange { [weak self] snapshot in
                self?.handleCatalogSnapshot(snapshot)
            }
            source.onAttachmentsDiscovered = { [weak catalogProjection] records in
                catalogProjection?.upsertOptimistically(records)
            }
            source.onAttachmentsInvalidated = { [weak catalogProjection] eventIds in
                catalogProjection?.invalidate(eventIds: eventIds)
            }
            attachmentObservation = attachmentIndex.observe(
                onError: { [weak self] error in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isStopped else { return }
                        self.startError = error.localizedDescription
                        self.isInitialLoading = false
                        log("index observation failed room=\(self.roomId) error=\(error)")
                    }
                },
                onChange: { [weak catalogProjection] records in
                    catalogProjection?.replaceIndexed(with: records)
                }
            )
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.retryDecryption(reason: "foreground")
            }
        }

        do {
            try await source.start()
        } catch {
            startError = error.localizedDescription
            isInitialLoading = false
            log("start failed room=\(roomId) error=\(error)")
            return
        }
        guard !isStopped else {
            // `stop()` ran while the timeline was being built; its
            // `source.stop()` came too early to see these listeners.
            source.stop()
            return
        }

        #if DEBUG
        diagnostics.filterMode = filterMode.rawValue
        diagnostics.chatHistorySyncPaused = AttachmentsResearchSettings.isChatHistorySyncPaused
        researchObserver = NotificationCenter.default.addObserver(
            forName: AttachmentsResearchSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshResearchDiagnostics()
            }
        }
        if let room {
            diagnostics.roomEncrypted = await room.isEncrypted()
        }
        #endif

        // The initial `.reset` lands within the store's debounce; waiting for
        // it avoids paginating for items that are already loaded.
        _ = await Self.waitForSnapshot(after: 0, timeoutMs: Self.initialSnapshotWaitMs) { [weak self] in
            self?.lastSnapshotGeneration
        }
        guard !isStopped else { return }

        log("started room=\(roomId) filter=\(filterMode.rawValue) tilePx=\(tilePixelSize)")
        if needsInitialPage(for: tab) {
            fillIfNeeded(reason: "start", force: true)
        }
    }

    /// Idempotent teardown. Called when the screen leaves the navigation
    /// stack; `deinit` alone can lag behind an in-flight download that still
    /// references the model.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        fillTask?.cancel()
        fillTask = nil
        lateRetryTask?.cancel()
        lateRetryTask = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
        if let researchObserver {
            NotificationCenter.default.removeObserver(researchObserver)
            self.researchObserver = nil
        }
        pendingFill = nil
        attachmentObservation?.cancel()
        attachmentObservation = nil
        source.onSnapshot = nil
        source.onPaginationStatus = nil
        source.onAttachmentsDiscovered = nil
        source.onAttachmentsInvalidated = nil
        catalogProjection?.stop()
        source.stop()
        log("stopped room=\(roomId)")
    }

    private func handle(_ snapshot: AttachmentTimelineStore.Snapshot, _ summary: AttachmentTimelineStore.ApplySummary) {
        guard !isStopped else { return }
        lastSnapshotGeneration = snapshot.generation
        rowCount = snapshot.rowCount
        mediaCount = snapshot.mediaCount
        fileCount = snapshot.fileCount
        if attachmentIndex == nil {
            media = snapshot.media
            files = snapshot.files
        }
        pendingDecryptionCount = snapshot.pendingCount
        pendingSessionIds = snapshot.pendingSessionIds
        if attachmentIndex == nil, isInitialLoading {
            isInitialLoading = false
        }

        let elapsed = Date().timeIntervalSince(openedAt)
        resolvedUtdCount += summary.utdResolvedToMedia.count + summary.utdResolvedToOther
        for eventId in summary.utdResolvedToMedia {
            log("late decryption → media event=\(eventId) after=\(String(format: "%.1f", elapsed))s")
        }
        if summary.indexErrors > 0 {
            log("diff index errors=\(summary.indexErrors) rows=\(snapshot.rowCount)")
        }
        if summary.appended + summary.inserted + summary.set + summary.removed > 0 {
            log(
                "diffs appended=\(summary.appended) inserted=\(summary.inserted) set=\(summary.set) "
                + "removed=\(summary.removed) mediaRemoved=\(summary.mediaRemoved.count) "
                + "utdResolved=\(summary.utdResolvedToMedia.count) rows=\(snapshot.rowCount)"
            )
        }
        if summary.clears > 0 || summary.resets > 0 {
            // A clear usually means a limited sync unloaded the room's linked
            // chunk; the SDK then hides everything but the last 20 items until
            // the next paginateBackwards (see ATTACHMENTS.md).
            log("timeline clears=\(summary.clears) resets=\(summary.resets) rows=\(snapshot.rowCount)")
        }

        #if DEBUG
        diagnostics.snapshots += 1
        if diagnostics.timeToFirstSnapshotMs == nil {
            diagnostics.timeToFirstSnapshotMs = elapsed * 1000
        }
        diagnostics.rowCount = snapshot.rowCount
        diagnostics.mediaCount = snapshot.mediaCount
        diagnostics.fileCount = snapshot.fileCount
        diagnostics.pendingCount = snapshot.pendingCount
        diagnostics.lastMapMs = summary.mapMs
        diagnostics.maxMapMs = max(diagnostics.maxMapMs, summary.mapMs)
        diagnostics.lastApplyMs = summary.applyMs
        diagnostics.indexErrors += summary.indexErrors
        diagnostics.utdResolved += summary.utdResolvedToMedia.count
        diagnostics.utdResolveDelaysSeconds += summary.utdResolvedToMedia.map { _ in elapsed }
        #endif

        scheduleLateRetryIfNeeded()
        if sentinelVisible {
            fillIfNeeded(reason: "snapshot")
        }
    }

    private func handleCatalogSnapshot(_ snapshot: RoomAttachmentCatalogSnapshot) {
        guard !isStopped else { return }
        if media != snapshot.media {
            media = snapshot.media
        }
        if files != snapshot.files {
            files = snapshot.files
        }
        indexedMediaCount = snapshot.mediaCount
        indexedFileCount = snapshot.fileCount
        hasReceivedIndexSnapshot = snapshot.hasIndexedSnapshot
        if isInitialLoading, snapshot.hasIndexedSnapshot || snapshot.recordCount > 0 {
            isInitialLoading = false
        }
        #if DEBUG
        log(
            "trace index mapped room=\(roomId) records=\(snapshot.recordCount) "
            + "media=\(snapshot.mediaCount) files=\(snapshot.fileCount) "
            + "ms=\(String(format: "%.0f", snapshot.mapMs))"
        )
        #endif
        log(
            "index snapshot room=\(roomId) records=\(snapshot.recordCount) "
            + "media=\(indexedMediaCount) files=\(indexedFileCount)"
        )
    }

    /// Spinner and diagnostics only. The status is shared per room and, for
    /// this timeline, mapped through the SDK's skip count; the fill loop
    /// establishes `hitStart` itself with a confirming call.
    private func handlePaginationStatus(_ status: PaginationStatus) {
        guard !isStopped else { return }
        sdkPaginationStatus = status
        #if DEBUG
        // The status is shared per room. A `.paginating` while no fill of
        // ours is running belongs to the chat screen underneath; one that
        // overlaps our fill is indistinguishable, so this is a lower bound.
        if case .paginating = status, fillTask == nil {
            diagnostics.foreignPaginations += 1
        }
        #endif
    }

    // MARK: - Pagination

    func sentinelAppeared() {
        sentinelVisible = true
        fillIfNeeded(reason: "sentinel", force: true, intent: .sentinel)
    }

    func sentinelDisappeared() {
        sentinelVisible = false
    }

    func loadMoreTapped() {
        fillIfNeeded(reason: "manual", force: true, intent: .manual)
    }

    private func currentCount(for tab: Tab) -> Int {
        if attachmentIndex != nil, hasReceivedIndexSnapshot {
            return indexedCount(for: tab)
        }
        return tab == .media ? mediaCount : fileCount
    }

    private func indexedCount(for tab: Tab) -> Int {
        tab == .media ? indexedMediaCount : indexedFileCount
    }

    private func needsInitialPage(for tab: Tab) -> Bool {
        guard attachmentIndex != nil, hasReceivedIndexSnapshot else { return true }
        return indexedCount(for: tab) < pageSize(for: tab)
    }

    private func pageSize(for tab: Tab) -> Int {
        tab == .media ? Self.mediaPageSize : Self.filesPageSize
    }

    private struct BatchContext {
        let batch: Int
        let generation: Int
        let rowsBefore: Int
        let start: CFTimeInterval
        /// The previous batch already reported the room start.
        let confirmingStart: Bool
    }

    private enum FillStopReason: String {
        case pageFilled
        case hitStart
        case timeBudget
        case batchCap
        case stopped
    }

    private var fillStopReason: FillStopReason = .pageFilled
    /// Set when `loadMore` reported the room start; `hitStart` is only
    /// committed after one more call confirms it. `Timeline.paginateBackwards`
    /// returns true straight from the event cache, even while the timeline
    /// still hides older items behind its lazy-reveal skip count (after a
    /// `Clear`, e.g. a limited sync); the confirming call reveals them.
    private var startReportedByLastBatch = false

    /// One fill at a time. A fill paginates in batches until the active tab
    /// gained a page, the room start was reached, or the time budget ran
    /// out. A batch already in flight always completes: `paginateBackwards`
    /// cannot be cancelled, and its rows are still worth keeping.
    /// `force` re-arms after a cap (sentinel re-appeared, manual tap).
    ///
    /// The task only reaches the model through weak hops between awaits, so
    /// a popped screen is released right away rather than after the last
    /// batch returns.
    /// Explicit user intents that may wait for a running fill and be
    /// replayed once. Snapshot-driven re-arms are never queued: replaying
    /// them with `force` would bypass the time budget and turn the screen
    /// into an unbounded history pump.
    private enum FillIntent: String {
        case tab
        case sentinel
        case manual
    }

    private var pendingFill: FillIntent?

    /// True while a fill is running or one is queued behind it.
    var isFillActive: Bool {
        fillTask != nil || pendingFill != nil
    }

    private func fillIfNeeded(reason: String, force: Bool = false, intent: FillIntent? = nil) {
        guard hasStarted, !isStopped, !hitStart else { return }
        guard force || sentinelVisible || isInitialLoading else { return }
        if fillTask != nil {
            if let intent {
                pendingFill = intent
            }
            return
        }
        if case .capped = fillState, !force { return }
        if case .failed = fillState, !force { return }

        let tab = self.tab
        let target = currentCount(for: tab) + pageSize(for: tab)
        let source = self.source

        fillTask = Task { [weak self] in
            let fillStart = CACurrentMediaTime()
            var batch = 0
            var failure: String?

            while !Task.isCancelled {
                guard let context = self?.beginBatch(
                    tab: tab, target: target, previousBatch: batch, fillStart: fillStart
                ) else {
                    break
                }
                batch = context.batch

                let reachedStart: Bool
                do {
                    reachedStart = try await source.loadMore(numEvents: Self.batchEvents)
                } catch {
                    failure = error.localizedDescription
                    log("fill \(reason) batch=\(batch) failed error=\(error)")
                    break
                }

                let waitMs = self?.snapshotWaitMs ?? Self.snapshotWaitMsOnlyMessage
                let noDiff = await Self.waitForSnapshot(
                    after: context.generation,
                    timeoutMs: waitMs
                ) { [weak self] in
                    self?.lastSnapshotGeneration
                }
                self?.finishBatch(context, reachedStart: reachedStart, noDiff: noDiff, reason: reason)
            }

            self?.beginSettling()
            let settled = await Self.settle(quietMs: Self.settleQuietMs, maxMs: Self.settleMaxMs) { [weak self] in
                self?.lastSnapshotGeneration
            }
            self?.finishFill(
                tab: tab, target: target, failure: failure, fillStart: fillStart, batches: batch, settled: settled
            )
        }
    }

    private func beginSettling() {
        guard !isStopped else { return }
        fillState = .settling
    }

    /// Waits until no snapshot has arrived for `quietMs`. Returns
    /// `(waitedMs, lateGenerations)`; `settledCleanly` is false when the cap hit.
    private static func settle(
        quietMs: Int,
        maxMs: Int,
        current: @MainActor () -> Int?
    ) async -> (waitedMs: Double, lateSnapshots: Int, settledCleanly: Bool) {
        let start = CACurrentMediaTime()
        guard var lastSeen = current() else { return (0, 0, true) }
        let startGeneration = lastSeen
        var quietSince = CACurrentMediaTime()
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            if (now - start) * 1000 >= Double(maxMs) {
                return ((now - start) * 1000, lastSeen - startGeneration, false)
            }
            guard let value = current() else { return ((now - start) * 1000, 0, true) }
            if value != lastSeen {
                lastSeen = value
                quietSince = now
            } else if (now - quietSince) * 1000 >= Double(quietMs) {
                return ((now - start) * 1000, lastSeen - startGeneration, true)
            }
            try? await Task.sleep(for: .milliseconds(snapshotPollMs * 5))
        }
        return ((CACurrentMediaTime() - start) * 1000, lastSeen - startGeneration, true)
    }

    /// Decides whether another batch may start. Order matters: reaching the
    /// page or the room start is success, the budget is the normal stop,
    /// the batch cap is a safety net that should never be the reason.
    private func beginBatch(tab: Tab, target: Int, previousBatch: Int, fillStart: CFTimeInterval) -> BatchContext? {
        guard !isStopped else {
            fillStopReason = .stopped
            return nil
        }
        guard !hitStart else {
            fillStopReason = .hitStart
            return nil
        }
        guard startReportedByLastBatch || currentCount(for: tab) < target else {
            fillStopReason = .pageFilled
            return nil
        }
        guard startReportedByLastBatch || CACurrentMediaTime() - fillStart < fillTimeBudgetSeconds else {
            fillStopReason = .timeBudget
            return nil
        }
        guard previousBatch < Self.maxBatchesPerFill else {
            fillStopReason = .batchCap
            return nil
        }
        let batch = previousBatch + 1
        fillState = .filling(batch: batch)
        return BatchContext(
            batch: batch,
            generation: lastSnapshotGeneration,
            rowsBefore: rowCount,
            start: CACurrentMediaTime(),
            confirmingStart: startReportedByLastBatch
        )
    }

    private func finishBatch(_ context: BatchContext, reachedStart: Bool, noDiff: Bool, reason: String) {
        let ms = (CACurrentMediaTime() - context.start) * 1000
        let rowsAdded = rowCount - context.rowsBefore
        if reachedStart && context.confirmingStart && rowsAdded == 0 {
            hitStart = true
        } else if reachedStart && context.confirmingStart {
            log("start confirmation revealed \(rowsAdded) hidden rows; confirming again")
        }
        startReportedByLastBatch = reachedStart
        log(
            "fill \(reason) batch=\(context.batch) rows=\(rowCount) (+\(rowsAdded)) "
            + "media=\(mediaCount) files=\(fileCount) utd=\(pendingDecryptionCount) "
            + "reachedStart=\(reachedStart) confirming=\(context.confirmingStart) hitStart=\(hitStart) "
            + "noDiff=\(noDiff) ms=\(String(format: "%.0f", ms))"
        )
        #if DEBUG
        diagnostics.batches += 1
        diagnostics.rowsFromBatches += max(0, rowsAdded)
        diagnostics.lastBatchMs = ms
        diagnostics.totalBatchMs += ms
        if rowsAdded <= 0 {
            diagnostics.zeroRowBatches += 1
        }
        if noDiff {
            diagnostics.noDiffBatches += 1
        }
        diagnostics.hitStart = hitStart
        #endif
    }

    private func finishFill(
        tab: Tab,
        target: Int,
        failure: String?,
        fillStart: CFTimeInterval,
        batches: Int,
        settled: (waitedMs: Double, lateSnapshots: Int, settledCleanly: Bool)
    ) {
        fillTask = nil
        guard !isStopped else { return }
        let elapsedMs = (CACurrentMediaTime() - fillStart) * 1000
        log(
            "fill settled waited=\(String(format: "%.0f", settled.waitedMs))ms "
            + "lateSnapshots=\(settled.lateSnapshots) clean=\(settled.settledCleanly) rows=\(rowCount)"
        )
        if let failure {
            fillState = .failed(failure)
        } else if hitStart {
            // The room start is a fact even when the settle hit its cap;
            // items still landing arrive through the listener regardless.
            fillState = .exhausted
        } else if currentCount(for: tab) < target {
            fillState = .capped
        } else {
            fillState = .idle
        }
        let reason = failure != nil ? "failed" : fillStopReason.rawValue
        let status: String
        switch sdkPaginationStatus {
        case .idle(let hitTimelineStart): status = "idle(hitStart=\(hitTimelineStart))"
        case .paginating: status = "paginating"
        case .none: status = "unknown"
        }
        log(
            "fill ended reason=\(reason) batches=\(batches) "
            + "\(tab.rawValue)=\(currentCount(for: tab))/\(target) elapsed=\(String(format: "%.0f", elapsedMs))ms "
            + "sdkStatus=\(status)"
        )
        #if DEBUG
        diagnostics.fills += 1
        diagnostics.lastFillMs = elapsedMs
        diagnostics.lateSnapshotsAfterFill += settled.lateSnapshots
        if !settled.settledCleanly {
            diagnostics.settleCapHits += 1
        }
        if hitStart {
            // Coverage comparison only means something once the whole
            // history is in the timeline; after an unclean settle give the
            // pipeline a little longer first.
            if settled.settledCleanly {
                refreshGRDBCrossCheck()
            } else {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.refreshGRDBCrossCheck()
                }
            }
        }
        if failure == nil {
            switch fillStopReason {
            case .timeBudget: diagnostics.fillsEndedByTimeBudget += 1
            case .batchCap: diagnostics.fillsEndedByBatchCap += 1
            default: break
            }
        }
        #endif

        // An explicit intent that arrived while this fill ran gets its turn
        // now; a sentinel only if it is still on screen.
        if let pending = pendingFill {
            pendingFill = nil
            if pending != .sentinel || sentinelVisible {
                #if DEBUG
                diagnostics.pendingFillsReplayed += 1
                #endif
                fillIfNeeded(reason: "pending(\(pending.rawValue))", force: true, intent: pending)
            }
        }
    }

    /// Diffs land on the listener after `paginateBackwards` returns and are
    /// published with a short debounce; poll rather than guess. Returns true
    /// when the wait timed out, which the diagnostics count: a late diff is
    /// then attributed to the next batch. `current` yields nil once the model
    /// is gone.
    private static func waitForSnapshot(
        after generation: Int,
        timeoutMs: Int,
        current: @MainActor () -> Int?
    ) async -> Bool {
        let deadline = CACurrentMediaTime() + Double(timeoutMs) / 1000
        while !Task.isCancelled, CACurrentMediaTime() < deadline {
            guard let value = current() else { return false }
            if value > generation { return false }
            try? await Task.sleep(for: .milliseconds(snapshotPollMs))
        }
        guard let value = current() else { return false }
        return value <= generation
    }

    // MARK: - Decryption

    func retryDecryption(reason: String) {
        guard hasStarted, !isStopped, !pendingSessionIds.isEmpty else { return }
        log("retryDecryption reason=\(reason) sessions=\(pendingSessionIds.count) utd=\(pendingDecryptionCount)")
        source.retryDecryption(sessionIds: pendingSessionIds)
        #if DEBUG
        diagnostics.retryCount += 1
        #endif
    }

    /// Keys that arrived before this timeline existed, or in another process,
    /// are only picked up by an explicit retry. Retrying while the backup
    /// download is visibly making progress just adds work for the
    /// redecryptor (after a relogin keys land in waves for ~45 s), so the
    /// retry fires only on a stall: not a single decryption within the
    /// window. The pending count is the wrong signal — it keeps growing
    /// while the chat below paginates. Re-armed on the next snapshot.
    private func scheduleLateRetryIfNeeded() {
        guard lateRetryTask == nil, pendingDecryptionCount > 0 else { return }
        let resolvedAtSchedule = resolvedUtdCount
        lateRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.lateRetryTask = nil
            if self.pendingDecryptionCount > 0, self.resolvedUtdCount == resolvedAtSchedule {
                self.retryDecryption(reason: "stall")
            }
        }
    }

    // MARK: - Tiles

    func plan(for item: AttachmentItem) -> AttachmentThumbnailPlan {
        AttachmentThumbnailPlan.make(
            for: item,
            tilePixelSize: tilePixelSize,
            fullFileThreshold: fullFileThreshold,
            forceLoad: forceLoadIds.contains(item.id)
        )
    }

    func requestLoad(_ item: AttachmentItem) {
        forceLoadIds.insert(item.id)
    }

    /// Memory-only lookup for viewer transitions.
    func previewImage(for item: AttachmentItem) -> UIImage? {
        guard let request = plan(for: item).request else { return nil }
        return MediaCache.shared.cachedAttachmentThumbnail(mxc: request.mxc, tilePixelSize: tilePixelSize)
    }

    var allImages: [AttachmentItem] {
        media.flatMap(\.items).filter { $0.kind == .image }
    }

    /// Tile tiers describe UI behaviour: `.sdk` means this tile's producer
    /// made the call, `.coalesced` joined someone else's, memory/disk never
    /// left the app. The number of SDK calls itself comes from
    /// `AttachmentFetchMeter`, counted at the producer, because a cancelled
    /// owner tile never reports and the viewer is not a tile at all.
    func recordTile(_ item: AttachmentItem, plan: AttachmentThumbnailPlan, stats: AttachmentFetchStats?) {
        #if DEBUG
        switch plan {
        case .fetch(_, let reason):
            diagnostics.recordTile(reason: reason.rawValue, stats: stats)
        case .deferred(let reason):
            diagnostics.deferredByReason[reason.rawValue, default: 0] += 1
        }
        diagnostics.fetchMeter = AttachmentFetchMeter.shared.current()
        #endif
        if let stats {
            log(
                "tile event=\(item.id) kind=\(item.kind.rawValue) encrypted=\(item.isSourceEncrypted) "
                + "thumb=\(item.thumbnail != nil) tier=\(stats.tier.rawValue) "
                + "request=\(stats.request) bytes=\(stats.bytes) "
                + "date=\(item.date.formatted(date: .abbreviated, time: .shortened)) sender=\(item.senderName ?? item.sender) "
                + "queue=\(String(format: "%.0f", stats.queueMs))ms fetch=\(String(format: "%.0f", stats.fetchMs))ms "
                + "prep=\(String(format: "%.0f", stats.prepareMs))ms"
            )
        } else if stats == nil, plan.request != nil {
            log("tile event=\(item.id) kind=\(item.kind.rawValue) load failed plan=\(plan)")
        }
    }

    // MARK: - Downloads

    /// Reserves the item synchronously so two quick taps cannot start two
    /// downloads; released by `.finished`/`.failed`.
    func beginDownload(_ itemId: String) -> Bool {
        guard downloadProgress[itemId] == nil else { return false }
        downloadProgress[itemId] = -1
        return true
    }

    func handleDownloadEvent(_ event: AttachmentDownloadEvent, for itemId: String) {
        switch event {
        case .progress(let value):
            downloadProgress[itemId] = value
        case .finished:
            downloadProgress.removeValue(forKey: itemId)
        case .failed(let message):
            downloadProgress.removeValue(forKey: itemId)
            downloadError = message
            log("download failed event=\(itemId) error=\(message)")
        }
    }

    // MARK: - Research diagnostics

    #if DEBUG
    /// Exercises the chat bubble's call sequence on an original the grid has
    /// not fetched: `getMediaThumbnail` (which the SDK turns into a full
    /// download for encrypted media) followed by `getMediaContent`. With the
    /// fork's cache-key normalisation the second call must be a cache hit.
    func probeEncryptedThumbnailNormalization() {
        guard let client = MatrixClientService.shared.client else {
            log("patch2: no client")
            return
        }
        // The original must be something the grid has not fetched: a distinct
        // mxc from the sender thumbnail and clearly larger than it (small
        // photos ship a thumbnail identical to the original). Smallest such
        // original keeps the test cheap.
        let candidates = (media + files).flatMap(\.items)
            .filter { item in
                guard item.kind == .image, item.isSourceEncrypted,
                      let thumbnail = item.thumbnail, thumbnail.mxc != item.sourceMxc,
                      let size = item.sizeBytes else { return false }
                let thumbnailSize = thumbnail.sizeBytes ?? 0
                return size >= max(200_000, thumbnailSize * 2)
            }
            .sorted { ($0.sizeBytes ?? .max) < ($1.sizeBytes ?? .max) }
        guard let item = candidates.first else {
            log("patch2: no encrypted image whose original is untouched and larger than its thumbnail")
            return
        }
        let source = item.source
        let side = UInt64(tilePixelSize)
        log(
            "patch2: testing event=\(item.id) size=\(item.sizeBytes.map(String.init) ?? "?") mxc=\(item.sourceMxc) "
            + "thumbMxc=\(item.thumbnail?.mxc ?? "-") thumbBytes=\(item.thumbnail?.sizeBytes.map(String.init) ?? "?")"
        )
        Task {
            do {
                let firstStart = CACurrentMediaTime()
                let thumbnail = try await client.getMediaThumbnail(mediaSource: source, width: side, height: side)
                let firstMs = (CACurrentMediaTime() - firstStart) * 1000
                log("patch2: getMediaThumbnail bytes=\(thumbnail.count) ms=\(String(format: "%.0f", firstMs))")

                let secondStart = CACurrentMediaTime()
                let content = try await client.getMediaContent(mediaSource: source)
                let secondMs = (CACurrentMediaTime() - secondStart) * 1000
                let verdict: String
                if firstMs < 100 {
                    verdict = "inconclusive: the first call was already a cache hit, pick another room"
                } else if content.count == thumbnail.count && secondMs < 100 {
                    verdict = "cache hit, one download"
                } else {
                    verdict = "second download or slow cache"
                }
                log(
                    "patch2: getMediaContent bytes=\(content.count) ms=\(String(format: "%.0f", secondMs)) "
                    + "sameBytes=\(content.count == thumbnail.count) verdict=\(verdict)"
                )
            } catch {
                log("patch2: failed error=\(error)")
            }
        }
    }

    /// Asks the SDK for each attachment GRDB knows but the timeline does not.
    /// `loadOrFetchEvent` reads the event cache first and falls back to
    /// `/event`: the latency says which one answered (cache: a few ms,
    /// network: hundreds), the content says whether the copy is decrypted.
    func probeMissingAttachments() {
        guard let room else {
            log("probe: no room handle")
            return
        }
        let eventIds = Array(diagnostics.onlyInGRDB.prefix(10))
        guard !eventIds.isEmpty else {
            log("probe: nothing missing")
            return
        }
        Task {
            for eventId in eventIds {
                let start = CACurrentMediaTime()
                let inTimeline = await source.describeTimelineItem(eventId: eventId) ?? "no item"
                let inStore = (source as? SDKTimelineAttachmentSource)?.storeRowDescription(eventId: eventId) ?? "?"
                do {
                    let event = try await room.loadOrFetchEvent(eventId: eventId)
                    let ms = (CACurrentMediaTime() - start) * 1000
                    log(
                        "probe event=\(eventId) ms=\(String(format: "%.0f", ms)) "
                        + "ts=\(event.timestamp()) sender=\(event.senderId()) content=\(Self.describe(event)) "
                        + "timeline=\(inTimeline) store=\(inStore)"
                    )
                } catch {
                    let ms = (CACurrentMediaTime() - start) * 1000
                    log("probe event=\(eventId) ms=\(String(format: "%.0f", ms)) failed error=\(error)")
                }
            }
        }
    }

    private static func describe(_ event: TimelineEvent) -> String {
        do {
            switch try event.content() {
            case .messageLike(let content):
                switch content {
                case .roomMessage(let messageType, _):
                    switch messageType {
                    case .image: return "message/image"
                    case .video: return "message/video"
                    case .file: return "message/file"
                    case .audio: return "message/audio"
                    case .text: return "message/text"
                    default: return "message/other"
                    }
                case .roomEncrypted:
                    return "encrypted(UTD)"
                case .roomRedaction:
                    return "redaction"
                default:
                    return "messageLike/other"
                }
            case .state:
                return "state"
            }
        } catch {
            return "content unavailable: \(error)"
        }
    }

    func refreshResearchDiagnostics() {
        diagnostics.chatHistorySyncPaused = AttachmentsResearchSettings.isChatHistorySyncPaused
        diagnostics.fetchMeter = AttachmentFetchMeter.shared.current()
    }

    func resetFetchMeter() {
        AttachmentFetchMeter.shared.reset()
        diagnostics.fetchMeter = AttachmentFetchMeter.shared.current()
    }
    #endif

    // MARK: - GRDB cross-check

    #if DEBUG
    /// Compares what the SDK timeline found with what the chat's own GRDB
    /// mirror already holds for this room. Undecrypted rows are stored as
    /// text with a fixed body, hence the body match.
    func refreshGRDBCrossCheck() {
        // Headless/test instances have no room; the mirror check needs the app database.
        guard room != nil else { return }
        let roomId = self.roomId
        let utdBody = String(localized: "Unable to decrypt message")
        let sdkIds = Set((media + files).flatMap(\.items).map(\.id))

        Task.detached(priority: .utility) {
            let result = Self.fetchGRDBMediaState(roomId: roomId, utdBody: utdBody)

            await MainActor.run { [weak self] in
                guard let self, let result else { return }
                let grdbIds = Set(result.mediaIds)
                self.diagnostics.grdbMediaCount = grdbIds.count
                self.diagnostics.grdbUtdCount = result.utdCount
                self.diagnostics.onlyInGRDB = Array(grdbIds.subtracting(sdkIds)).sorted()
                self.diagnostics.onlyInSDK = Array(sdkIds.subtracting(grdbIds)).sorted()
                log(
                    "grdb check media=\(grdbIds.count) utd=\(result.utdCount) sdkMedia=\(sdkIds.count) "
                    + "onlyGRDB=\(self.diagnostics.onlyInGRDB.prefix(5)) onlySDK=\(self.diagnostics.onlyInSDK.prefix(5))"
                )
            }
        }
    }

    /// Synchronous on purpose: inside an async context GRDB resolves
    /// `read` to its async overload.
    private nonisolated static func fetchGRDBMediaState(
        roomId: String,
        utdBody: String
    ) -> (mediaIds: [String], utdCount: Int)? {
        try? DatabaseService.shared.dbQueue.read { db in
            let mediaIds = try String.fetchAll(
                db,
                sql: """
                    SELECT eventId FROM storedMessage
                    WHERE roomId = ? AND contentType IN ('image', 'video', 'file', 'audio', 'voice')
                      AND eventId IS NOT NULL AND eventId != ''
                    """,
                arguments: [roomId]
            )
            let utdCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM storedMessage WHERE roomId = ? AND contentType = 'text' AND contentBody = ?",
                arguments: [roomId, utdBody]
            ) ?? 0
            return (mediaIds, utdCount)
        }
    }
    #endif
}
