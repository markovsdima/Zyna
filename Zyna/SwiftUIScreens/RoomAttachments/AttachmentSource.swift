//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

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

/// Feeds the attachments screen with month groups. The screen never knows
/// whether rows come from an SDK timeline or a local index.
protocol AttachmentSource: AnyObject, Sendable {
    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)? { get set }
    var onPaginationStatus: ((PaginationStatus) -> Void)? { get set }

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

/// A second live timeline of the room, built with `timelineWithConfiguration`.
/// Main-confined by usage: `start/stop` run on the view model, listeners hop to
/// main before touching state.
final class SDKTimelineAttachmentSource: AttachmentSource, @unchecked Sendable {

    let room: Room
    let filterMode: AttachmentSourceFilterMode

    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)?
    var onPaginationStatus: ((PaginationStatus) -> Void)?

    private let store: AttachmentTimelineStore
    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?
    private var paginationHandle: TaskHandle?

    init(room: Room, filterMode: AttachmentSourceFilterMode, store: AttachmentTimelineStore = AttachmentTimelineStore()) {
        self.room = room
        self.filterMode = filterMode
        self.store = store
    }

    deinit {
        stop()
    }

    func start() async throws {
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

        let statusListener = AttachmentPaginationStatusListener { [weak self] status in
            DispatchQueue.main.async {
                self?.onPaginationStatus?(status)
            }
        }
        paginationHandle = try? await timeline.subscribeToBackPaginationStatus(listener: statusListener)
    }

    func stop() {
        listenerHandle?.cancel()
        paginationHandle?.cancel()
        listenerHandle = nil
        paginationHandle = nil
        timeline = nil
    }

    func loadMore(numEvents: UInt16) async throws -> Bool {
        guard let timeline else { return true }
        return try await timeline.paginateBackwards(numEvents: numEvents)
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
