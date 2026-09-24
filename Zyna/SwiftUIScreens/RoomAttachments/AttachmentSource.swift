//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

#if DEBUG
private let logAttachmentSourceTrace = ScopedLog(
    .attachments,
    prefix: "[Attachments][trace][filtered]"
)
#endif

/// Which SDK filter feeds the attachments timeline.
///
/// `.sdkOnlyMessage` is cheaper: text items never cross the FFI and the
/// Rust timeline does not build them. Stock upstream drops
/// `m.room.encrypted` in that mode, so late-decrypted media would never
/// appear; the fork (`26.5.13-zyna.5-beta.12`) keeps undecrypted events in
/// the timeline, which makes this mode safe. `.allWithSwiftFilter` remains
/// for A/B measurements. See `Zyna/Chat/ATTACHMENTS.md`.
enum AttachmentSourceFilterMode: String, CaseIterable {
    case allWithSwiftFilter
    case sdkOnlyMessage
}

/// Discovers attachment events independently of the durable local catalog.
protocol AttachmentSource: AnyObject, Sendable {
    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)? { get set }
    var onPaginationStatus: ((PaginationStatus) -> Void)? { get set }
    /// Durable-shaped values discovered by the live timeline. The catalog
    /// may publish these optimistically while the same records wait for GRDB.
    var onAttachmentsDiscovered: (([StoredRoomAttachment]) -> Void)? { get set }
    /// Explicit invalidations (normally redactions), never SDK window trims.
    var onAttachmentsInvalidated: (([String]) -> Void)? { get set }

    func start() async throws
    func stop()
    /// Returns true once the start of the room has been reached.
    func loadMore(numEvents: UInt16) async throws -> Bool
    func retryDecryption(sessionIds: [String])
    /// Research probe: does the underlying timeline hold an item for this
    /// event at all (visible or hidden)? nil when it does not.
    func describeTimelineItem(eventId: String) async -> String?
    /// Research probe: does the store hold a row for this timeline unique id?
    func storeRowDescription(uniqueId: String) -> String?
}

/// A filtered room timeline used for live discovery and backward pagination.
/// Diffs are processed in order off-main; UI snapshots are published on main.
final class SDKTimelineAttachmentSource: AttachmentSource, @unchecked Sendable {

    let room: Room
    let filterMode: AttachmentSourceFilterMode

    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)?
    var onPaginationStatus: ((PaginationStatus) -> Void)?
    var onAttachmentsDiscovered: (([StoredRoomAttachment]) -> Void)?
    var onAttachmentsInvalidated: (([String]) -> Void)?

    private let store: AttachmentTimelineStore
    private let attachmentIndex: RoomAttachmentIndex?
    private let roomId: String
    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?
    private var paginationHandle: TaskHandle?

    init(
        room: Room,
        filterMode: AttachmentSourceFilterMode,
        store: AttachmentTimelineStore = AttachmentTimelineStore(),
        attachmentIndex: RoomAttachmentIndex? = nil
    ) {
        self.room = room
        self.filterMode = filterMode
        self.store = store
        self.attachmentIndex = attachmentIndex
        roomId = room.id()
        store.onAttachmentsDiscovered = { [weak self] items in
            guard let self else { return }
            let records = items.map {
                StoredRoomAttachment(roomId: self.roomId, item: $0)
            }
            self.attachmentIndex?.upsert(records)
            self.onAttachmentsDiscovered?(records)
        }
        store.onAttachmentsInvalidated = { [weak self] eventIds in
            guard let self else { return }
            self.attachmentIndex?.remove(eventIds: eventIds)
            self.onAttachmentsInvalidated?(eventIds)
        }
    }

    deinit {
        stop()
    }

    func start() async throws {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        logAttachmentSourceTrace(
            "source.start BEGIN room=\(room.id()) filter=\(filterMode.rawValue)"
        )
        #endif
        let filter: TimelineFilter
        switch filterMode {
        case .allWithSwiftFilter:
            filter = .all
        case .sdkOnlyMessage:
            filter = .onlyMessage(types: [.image, .video, .file, .audio])
        }
        let configuration = TimelineConfiguration(
            focus: .live(hideThreadedEvents: false),
            filter: filter,
            internalIdPrefix: "attachments",
            dateDividerMode: .monthly,
            trackReadReceipts: .disabled,
            reportUtds: false
        )
        let timeline = try await room.timelineWithConfiguration(configuration: configuration)
        self.timeline = timeline
        #if DEBUG
        logAttachmentSourceTrace(
            "timeline BUILT room=\(room.id()) ms=\(Self.traceMs(since: started))"
        )
        #endif

        store.onSnapshot = { [weak self] snapshot, summary in
            self?.onSnapshot?(snapshot, summary)
        }

        // Rust holds the listener until the handle is cancelled; a strong
        // reference here would keep the store, and through it nothing else,
        // but stay weak so a dropped source never keeps mapping.
        let listener = AttachmentTimelineListener { [weak store] diffs in
            store?.enqueue(diffs)
        }
        listenerHandle = await timeline.addListener(listener: listener)
        #if DEBUG
        logAttachmentSourceTrace(
            "listener ATTACHED room=\(room.id()) ms=\(Self.traceMs(since: started))"
        )
        #endif

        let statusListener = AttachmentPaginationStatusListener { [weak self] status in
            DispatchQueue.main.async {
                self?.onPaginationStatus?(status)
            }
        }
        paginationHandle = try? await timeline.subscribeToBackPaginationStatus(listener: statusListener)
        #if DEBUG
        logAttachmentSourceTrace(
            "source.start END room=\(room.id()) ms=\(Self.traceMs(since: started))"
        )
        #endif
    }

    func stop() {
        listenerHandle?.cancel()
        paginationHandle?.cancel()
        listenerHandle = nil
        paginationHandle = nil
        timeline = nil
    }

    func loadMore(numEvents: UInt16) async throws -> Bool {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        #endif
        guard let timeline else {
            #if DEBUG
            logAttachmentSourceTrace(
                "paginate NOT_READY room=\(room.id()) requested=\(numEvents) returningHitStart=true"
            )
            #endif
            return true
        }
        #if DEBUG
        logAttachmentSourceTrace(
            "paginate BEGIN room=\(room.id()) requested=\(numEvents)"
        )
        #endif
        let reachedStart = try await timeline.paginateBackwards(numEvents: numEvents)
        #if DEBUG
        logAttachmentSourceTrace(
            "paginate END room=\(room.id()) requested=\(numEvents) "
            + "reachedStart=\(reachedStart) ms=\(Self.traceMs(since: started))"
        )
        #endif
        return reachedStart
    }

    func retryDecryption(sessionIds: [String]) {
        guard !sessionIds.isEmpty else { return }
        timeline?.retryDecryption(sessionIds: sessionIds)
    }

    func describeTimelineItem(eventId: String) async -> String? {
        guard let timeline else { return nil }
        guard let item = try? await timeline.getEventTimelineItemByEventId(eventId: eventId) else {
            return nil
        }
        let kind: String
        switch item.content {
        case .msgLike(let msgLike):
            switch msgLike.kind {
            case .message(let message):
                switch message.msgType {
                case .image: kind = "message/image"
                case .video: kind = "message/video"
                case .file: kind = "message/file"
                case .audio: kind = "message/audio"
                default: kind = "message/other"
                }
            case .unableToDecrypt: kind = "UTD"
            case .redacted: kind = "redacted"
            default: kind = "msgLike/other"
            }
        default:
            kind = "non-message"
        }
        let id: String
        switch item.eventOrTransactionId {
        case .eventId(let eventId): id = "event:\(eventId.suffix(8))"
        case .transactionId(let txnId): id = "txn:\(txnId.suffix(8))"
        }
        return "item \(kind) remote=\(item.isRemote) \(id)"
    }

    func storeRowDescription(uniqueId: String) -> String? {
        store.currentRows.first { $0.uniqueId == uniqueId }.map { row in
            switch row {
            case .attachment(let item): return "row attachment/\(item.kind.rawValue)"
            case .pendingDecryption: return "row UTD"
            case .other: return "row other"
            }
        }
    }

    /// Research probe: the store's view by event id.
    func storeRowDescription(eventId: String) -> String {
        for row in store.currentRows {
            switch row {
            case .attachment(let item) where item.id == eventId: return "row attachment/\(item.kind.rawValue)"
            case .pendingDecryption(let pending) where pending.eventId == eventId: return "row UTD"
            default: continue
            }
        }
        return "no row"
    }

    #if DEBUG
    private static func traceMs(since start: TimeInterval) -> String {
        String(
            format: "%.0f",
            (ProcessInfo.processInfo.systemUptime - start) * 1000
        )
    }
    #endif
}

private final class AttachmentTimelineListener: TimelineListener {
    private let handler: @Sendable ([TimelineDiff]) -> Void

    init(handler: @escaping @Sendable ([TimelineDiff]) -> Void) {
        self.handler = handler
    }

    func onUpdate(diff: [TimelineDiff]) {
        handler(diff)
    }
}

private final class AttachmentPaginationStatusListener: PaginationStatusListener {
    private let handler: @Sendable (PaginationStatus) -> Void

    init(handler: @escaping @Sendable (PaginationStatus) -> Void) {
        self.handler = handler
    }

    func onUpdate(status: PaginationStatus) {
        handler(status)
    }
}
