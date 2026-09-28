//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Compact description of one debounced SDK timeline flush.
///
/// These counts are not just logging metadata: `ChatViewModel` uses the
/// shape of the flush to distinguish live updates from bootstrap/history
/// hydration. For example, a focused `set` can animate a newly-redacted
/// visible message, while reset/pagination-shaped flushes must not.
struct TimelineFlushSummary: Equatable {
    var appendCount = 0
    var pushBackCount = 0
    var pushFrontCount = 0
    var insertCount = 0
    var setCount = 0
    var removeCount = 0
    var resetCount = 0
    var truncateCount = 0
    var clearCount = 0
    var readReceiptCount = 0
    var upsertCount = 0
    var deleteCount = 0
    var redactedUpsertCount = 0
    var committedHistoryRevision: UInt64 = 0
    var includesUnreportedHistory = false
    var recoveredEventIDs: Set<String> = []
    /// Outgoing state may change without changing a stored message row.
    var requiresPresentationRefresh = false
    /// Positive proof from repair that no admitted row changed. Ordinary
    /// notifications default to false, including local presentation changes.
    var onlyUnadmittedChanges = false

    var canRefreshBoundsOnly: Bool {
        onlyUnadmittedChanges && !requiresPresentationRefresh && recoveredEventIDs.isEmpty
    }

    /// Preserve history/reset provenance when several flushes are prepared
    /// together; combining them must not enable a remote deletion animation.
    func merging(_ other: Self) -> Self {
        var result = self
        result.appendCount += other.appendCount
        result.pushBackCount += other.pushBackCount
        result.pushFrontCount += other.pushFrontCount
        result.insertCount += other.insertCount
        result.setCount += other.setCount
        result.removeCount += other.removeCount
        result.resetCount += other.resetCount
        result.truncateCount += other.truncateCount
        result.clearCount += other.clearCount
        result.readReceiptCount += other.readReceiptCount
        result.upsertCount += other.upsertCount
        result.deleteCount += other.deleteCount
        result.redactedUpsertCount += other.redactedUpsertCount
        result.committedHistoryRevision = max(committedHistoryRevision, other.committedHistoryRevision)
        result.includesUnreportedHistory = includesUnreportedHistory || other.includesUnreportedHistory
        result.recoveredEventIDs.formUnion(other.recoveredEventIDs)
        result.requiresPresentationRefresh = requiresPresentationRefresh || other.requiresPresentationRefresh
        result.onlyUnadmittedChanges = onlyUnadmittedChanges && other.onlyUnadmittedChanges
        return result
    }

    func coveringSnapshot(historyRevision: UInt64) -> Self {
        var result = self
        result.includesUnreportedHistory = includesUnreportedHistory
            || historyRevision > committedHistoryRevision
        return result
    }

    var hasHistoryOrResetShape: Bool {
        resetCount > 0
            || pushFrontCount > 0
            || appendCount > 0
            || insertCount > 0
            || clearCount > 0
    }

    /// Redactions that arrive as a focused SDK `set` against the currently
    /// retained timeline can be live user-visible changes. Reset/pagination
    /// shapes are treated as history hydration and must not drive splash UI.
    var allowsRemoteRedactionAnimation: Bool {
        setCount > 0 && !hasHistoryOrResetShape && !includesUnreportedHistory
    }

    var compactDescription: String {
        [
            appendCount > 0 ? "append=\(appendCount)" : nil,
            pushBackCount > 0 ? "pushBack=\(pushBackCount)" : nil,
            pushFrontCount > 0 ? "pushFront=\(pushFrontCount)" : nil,
            insertCount > 0 ? "insert=\(insertCount)" : nil,
            setCount > 0 ? "set=\(setCount)" : nil,
            removeCount > 0 ? "remove=\(removeCount)" : nil,
            resetCount > 0 ? "reset=\(resetCount)" : nil,
            truncateCount > 0 ? "truncate=\(truncateCount)" : nil,
            clearCount > 0 ? "clear=\(clearCount)" : nil,
            readReceiptCount > 0 ? "read=\(readReceiptCount)" : nil,
            upsertCount > 0 ? "upsert=\(upsertCount)" : nil,
            deleteCount > 0 ? "delete=\(deleteCount)" : nil,
            redactedUpsertCount > 0 ? "redacted=\(redactedUpsertCount)" : nil,
            includesUnreportedHistory ? "unreported" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

/// Why `MessageWindow` emitted a snapshot; controls UI interpretation
/// of the same data diff, especially redaction animation eligibility.
enum MessageWindowChangeOrigin: Equatable {
    case initialLoad
    case databasePagination
    case jump
    case localMutation
    case timelineFlush(TimelineFlushSummary)

    var preservesHistoryViewport: Bool {
        if case .databasePagination = self { return true }
        if case .timelineFlush(let summary) = self { return summary.includesUnreportedHistory }
        return false
    }

    var allowsRemoteRedactionAnimation: Bool {
        if case .timelineFlush(let summary) = self {
            return summary.allowsRemoteRedactionAnimation
        }
        return false
    }

    var compactDescription: String {
        switch self {
        case .initialLoad:
            return "initial"
        case .databasePagination:
            return "dbPage"
        case .jump:
            return "jump"
        case .localMutation:
            return "local"
        case .timelineFlush(let summary):
            return "flush(\(summary.compactDescription))"
        }
    }
}

enum MessageWindowPosition {
    case inCurrentWindow
    case olderThanCurrentWindow
    case newerThanCurrentWindow
    case missing
}

/// Manages the session-retained messages for one room. Mutations and
/// callbacks run on main; immutable requests can be fetched on a worker.
final class MessageWindow {

    private struct PendingDuplicateFingerprint: Hashable {
        let senderId: String
        let contentType: String
        let body: String
        let caption: String
        let filename: String
        let imageWidth: Int64
        let imageHeight: Int64
        let zynaAttributesJSON: String
    }

    // MARK: - Configuration

    /// Initial bootstrapping / jump window size. Once older pages are
    /// loaded during the session, they remain retained until an
    /// explicit reset path such as `jumpTo`.
    static let windowSize = 200
    static let pageSize = 50

    // MARK: - State

    private(set) var hasOlderInDB = true
    private(set) var hasNewerInDB = false

    var isAtLiveEdge: Bool { !hasNewerInDB }

    // MARK: - Dependencies

    private let roomId: String
    private let dbQueue: AccountDatabase
    private let log = ScopedLog(.database)

    // MARK: - Callback

    /// Fired after any window content change with (new, previous, origin).
    var onChange: ((_ new: [StoredMessage], _ previous: [StoredMessage]?, _ origin: MessageWindowChangeOrigin) -> Void)?
    var onOlderHistoryAvailable: (() -> Void)?
    var onRecoveryFocusChange: ((MessageDecryptionRepairStore.Focus) -> Void)?
    private(set) var recoveryFocus: MessageDecryptionRepairStore.Focus?

    private var previousStored: [StoredMessage]?
    private(set) var revision: UInt64 = 0
    private(set) var generation: UInt64 = 0
    private var olderCursor: Cursor?
    private var newerCursor: Cursor?
    fileprivate struct Neighbors: Equatable {
        let older: ClusterNeighbor?
        let newer: ClusterNeighbor?
        let hasOlder: Bool
        let hasNewer: Bool
    }

    private var cachedNeighbors: Neighbors?

    // MARK: - Init

    init(roomId: String, dbQueue: AccountDatabase) {
        self.roomId = roomId
        self.dbQueue = dbQueue
    }

    #if DEBUG
    func messageDiagnosticRequest(for message: ChatMessage) -> MessageDiagnostics.Request {
        .init(database: dbQueue, roomID: roomId, rowID: message.id, eventID: message.eventId,
              displayedPlaceholder: MessageDiagnostics.placeholderTextMatches(message.content.textBody))
    }
    #endif

    // MARK: - Initial Load

    // Synchronous conveniences for isolated window tests. The chat uses
    // replacementRequest and prepares its snapshot on historyPageQueue.
    func loadInitial() { replaceSynchronously(.newest) }

    enum Destination { case newest, oldest, live, event(String) }

    struct ReplacementRequest {
        fileprivate let revision: UInt64
        fileprivate let destination: Destination
        fileprivate let oldest: Cursor?
        fileprivate let live: Bool
        fileprivate let roomId: String
        fileprivate let database: AccountDatabase

        func fetch(includingLocalState: Bool = false) throws -> ReplacementPage? {
            try database.read { db in
                let query = StoredMessage.filter(Column("roomId") == roomId && Column("contentType") != "call")
                let raw: [StoredMessage]
                let origin: MessageWindowChangeOrigin
                let atLive: Bool
                switch destination {
                case .newest:
                    raw = try query.order(Column("timestamp").desc, Column("id").desc)
                        .limit(MessageWindow.windowSize).fetchAll(db)
                    origin = .initialLoad; atLive = true
                case .oldest:
                    raw = try query.order(Column("timestamp").asc, Column("id").asc)
                        .limit(MessageWindow.windowSize).fetchAll(db).reversed()
                    origin = .jump; atLive = false
                case .live:
                    var tail = query.order(Column("timestamp").desc, Column("id").desc)
                    if live, let oldest { tail = tail.filter(oldest.atOrNewerPredicate) }
                    else { tail = tail.limit(MessageWindow.windowSize) }
                    raw = try tail.fetchAll(db)
                    origin = .jump; atLive = true
                case .event(let eventId):
                    guard let target = try query.filter(Column("eventId") == eventId).fetchOne(db) else { return nil }
                    let cursor = Cursor(target)
                    let before = try query.filter(cursor.olderPredicate)
                        .order(Column("timestamp").desc, Column("id").desc)
                        .limit(MessageWindow.windowSize / 2 - 1).fetchAll(db)
                    let after = try query.filter(cursor.newerPredicate)
                        .order(Column("timestamp").asc, Column("id").asc)
                        .limit(MessageWindow.windowSize / 2).fetchAll(db)
                    raw = before + [target] + after
                    origin = .jump; atLive = false
                }
                let oldest = raw.map(Cursor.init).min { $0.precedes($1) }
                let newest = raw.map(Cursor.init).max { $0.precedes($1) }
                let rawOlder = try MessageWindow.olderNeighbor(in: db, roomId: roomId, cursor: oldest)
                let rawNewer = try MessageWindow.newerNeighbor(in: db, roomId: roomId, cursor: newest, live: atLive)
                return ReplacementPage(revision: revision,
                    stored: MessageWindow.normalizedStored(try MessageDecryptionRepairStore.admitted(raw, in: db)),
                    oldest: oldest, newest: newest,
                    neighbors: try MessageWindow.neighbors(in: db, roomId: roomId, oldest: oldest,
                        newest: newest, rawOlder: rawOlder, rawNewer: rawNewer),
                    origin: origin, focus: MessageWindow.focus(for: raw),
                    localState: includingLocalState ? try ChatTimelineLocalState.fetch(roomId: roomId, in: db) : ChatTimelineLocalState())
            }
        }
    }

    struct ReplacementPage {
        fileprivate let revision: UInt64
        let stored: [StoredMessage]
        fileprivate let oldest: Cursor?
        fileprivate let newest: Cursor?
        fileprivate let neighbors: Neighbors
        let origin: MessageWindowChangeOrigin
        fileprivate let focus: MessageDecryptionRepairStore.Focus?
        let localState: ChatTimelineLocalState
        var olderNeighbor: ClusterNeighbor? { neighbors.older }
        var newerNeighbor: ClusterNeighbor? { neighbors.newer }
    }

    func replacementRequest(_ destination: Destination) -> ReplacementRequest {
        dispatchPrecondition(condition: .onQueue(.main))
        return ReplacementRequest(revision: revision, destination: destination,
            oldest: olderCursor, live: isAtLiveEdge, roomId: roomId, database: dbQueue)
    }

    func canApply(_ page: ReplacementPage) -> Bool {
        dbQueue.isActive && page.revision == revision
    }

    @discardableResult
    func applyReplacement(_ page: ReplacementPage) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard canApply(page) else { return false }
        let previous = previousStored
        let wasAvailable = hasOlderInDB
        previousStored = page.stored
        olderCursor = page.oldest; newerCursor = page.newest
        cachedNeighbors = page.neighbors
        hasOlderInDB = page.neighbors.hasOlder; hasNewerInDB = page.neighbors.hasNewer
        revision &+= 1
        generation &+= 1
        updateRecoveryFocus(page.focus)
        onChange?(page.stored, previous, page.origin)
        notifyOlderHistoryAvailable(wasAvailable: wasAvailable)
        return true
    }

    private func replaceSynchronously(_ destination: Destination) {
        if let page = try? replacementRequest(destination).fetch() { applyReplacement(page) }
    }

    // MARK: - Local Pagination

    /// Stable order also paginates messages with identical timestamps.
    struct Cursor: Equatable {
        let timestamp: TimeInterval
        let id: String

        init(_ message: StoredMessage) {
            timestamp = message.timestamp
            id = message.id
        }

        func precedes(_ other: Cursor) -> Bool {
            timestamp < other.timestamp || (timestamp == other.timestamp && id < other.id)
        }

        var olderPredicate: SQLExpression {
            // The outer bound lets SQLite seek with the existing
            // (roomId, timestamp) index instead of scanning the room.
            Column("timestamp") <= timestamp
                && (Column("timestamp") < timestamp || Column("id") < id)
        }

        var newerPredicate: SQLExpression {
            Column("timestamp") >= timestamp
                && (Column("timestamp") > timestamp || Column("id") > id)
        }

        var atOrNewerPredicate: SQLExpression {
            Column("timestamp") >= timestamp
                && (Column("timestamp") > timestamp || Column("id") >= id)
        }

        var atOrOlderPredicate: SQLExpression {
            Column("timestamp") <= timestamp
                && (Column("timestamp") < timestamp || Column("id") <= id)
        }

        static func oldest(_ lhs: Self?, _ rhs: Self?) -> Self? {
            guard let lhs else { return rhs }
            guard let rhs else { return lhs }
            return lhs.precedes(rhs) ? lhs : rhs
        }

        static func newest(_ lhs: Self?, _ rhs: Self?) -> Self? {
            guard let lhs else { return rhs }
            guard let rhs else { return lhs }
            return lhs.precedes(rhs) ? rhs : lhs
        }
    }

    enum PageDirection { case older, newer }

    /// Captured on main; the worker never reads mutable window state.
    struct PageRequest {
        fileprivate let revision: UInt64
        fileprivate let direction: PageDirection
        fileprivate let cursor: Cursor
        fileprivate let stored: [StoredMessage]
        fileprivate let roomId: String
        fileprivate let database: AccountDatabase
        fileprivate let count: Int
        fileprivate let oldest: Cursor?
        fileprivate let newest: Cursor?
        fileprivate let live: Bool

        func fetch(includingLocalState: Bool = false) throws -> Page {
            let (records, admitted, neighbors, localState) = try database.read { db in
                let query = StoredMessage
                    .filter(Column("roomId") == roomId && Column("contentType") != "call")
                let fetched: [StoredMessage]
                let older: StoredMessage?
                let newer: StoredMessage?
                switch direction {
                case .older:
                    fetched = try query.filter(cursor.olderPredicate)
                        .order(Column("timestamp").desc, Column("id").desc)
                        .limit(count + 1).fetchAll(db)
                    older = fetched.dropFirst(count).first
                    newer = try MessageWindow.newerNeighbor(
                        in: db, roomId: roomId, cursor: newest, live: live
                    )
                case .newer:
                    fetched = try query.filter(cursor.newerPredicate)
                        .order(Column("timestamp").asc, Column("id").asc)
                        .limit(count + 1).fetchAll(db)
                    older = try MessageWindow.olderNeighbor(in: db, roomId: roomId, cursor: oldest)
                    newer = fetched.dropFirst(count).first
                }
                let records = Array(fetched.prefix(count))
                let nextOldest = direction == .older ? records.last.map(Cursor.init) ?? cursor : oldest
                let nextNewest = direction == .newer ? records.last.map(Cursor.init) ?? cursor : newest
                return (records, try MessageDecryptionRepairStore.admitted(records, in: db),
                        try MessageWindow.neighbors(in: db, roomId: roomId,
                            oldest: nextOldest, newest: nextNewest, rawOlder: older, rawNewer: newer),
                        includingLocalState ? try ChatTimelineLocalState.fetch(roomId: roomId, in: db) : ChatTimelineLocalState())
            }
            let merged = admitted.isEmpty ? stored : MessageWindow.normalizedStored(stored + admitted)
            #if DEBUG
            let trace = HistoryPerformanceTrace.capture(database: database)
            trace?.count(.pageRaw, records.count)
            trace?.count(.pageShown, admitted.count)
            if let trace { trace.count(.pageRedacted, admitted.filter { $0.contentType == "redacted" }.count) }
            if admitted.isEmpty { trace?.count(.pageEmpty) }
            #endif
            return Page(
                revision: revision, direction: direction,
                merged: merged, fetchedCount: records.count,
                cursor: records.last.map(Cursor.init) ?? cursor,
                neighbors: neighbors, focus: MessageWindow.focus(for: records), localState: localState
            )
        }
    }

    /// Normalization and both boundary reads are already complete.
    struct Page {
        fileprivate let revision: UInt64
        fileprivate let direction: PageDirection
        let merged: [StoredMessage]
        let fetchedCount: Int
        fileprivate let cursor: Cursor
        fileprivate let neighbors: Neighbors
        fileprivate let focus: MessageDecryptionRepairStore.Focus?
        let localState: ChatTimelineLocalState
        var olderNeighbor: ClusterNeighbor? { neighbors.older }
        var newerNeighbor: ClusterNeighbor? { neighbors.newer }
    }

    func pageRequest(_ direction: PageDirection, count: Int = pageSize) -> PageRequest? {
        dispatchPrecondition(condition: .onQueue(.main))
        let cursor = direction == .older ? olderCursor : newerCursor
        guard count > 0, let cursor, let stored = previousStored else { return nil }
        if direction == .newer && isAtLiveEdge { return nil }
        return PageRequest(
            revision: revision, direction: direction, cursor: cursor, stored: stored,
            roomId: roomId, database: dbQueue, count: count,
            oldest: olderCursor, newest: newerCursor, live: isAtLiveEdge
        )
    }

    func canApply(_ page: Page) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return dbQueue.isActive && page.revision == revision
    }

    /// A refresh, opposite page, or jump invalidates a prepared page.
    @discardableResult
    func applyPage(_ page: Page) -> Bool {
        guard canApply(page) else { return false }
        let wasAvailable = hasOlderInDB
        defer { notifyOlderHistoryAvailable(wasAvailable: wasAvailable) }
        let neighborsChanged = cachedNeighbors != page.neighbors
        switch page.direction {
        case .older: olderCursor = page.cursor
        case .newer: newerCursor = page.cursor
        }
        hasOlderInDB = page.neighbors.hasOlder
        hasNewerInDB = page.neighbors.hasNewer
        cachedNeighbors = page.neighbors
        updateRecoveryFocus(page.focus)
        // Even an empty read can reach live after the remaining rows were
        // deleted. Retire requests that still carry the old window bounds.
        if page.fetchedCount > 0 || neighborsChanged { revision &+= 1 }
        guard page.fetchedCount > 0 || neighborsChanged else { return true }

        let previous = previousStored
        previousStored = page.merged
        onChange?(page.merged, previous, .databasePagination)
        log("load \(page.direction): +\(page.fetchedCount), window=\(page.merged.count)")
        return true
    }

    // MARK: - Refresh (batcher flush callback)

    /// SDK flushes use a value snapshot just like backward pagination.
    /// Fetching, normalization and equality checks run on the page worker.
    struct RefreshRequest {
        fileprivate let revision: UInt64
        fileprivate let previous: [StoredMessage]?
        fileprivate let oldest: Cursor?
        fileprivate let newest: Cursor?
        fileprivate let live: Bool
        fileprivate let neighbors: Neighbors?
        fileprivate let roomId: String
        fileprivate let database: AccountDatabase

        var canRefreshBoundsOnly: Bool { previous != nil && oldest != nil && neighbors != nil }

        /// Cleanup cannot change an admitted cluster neighbor. Read only
        /// raw paging eligibility, leaving the retained messages untouched.
        func fetchBounds() throws -> BoundsPage {
            try database.read { db in
                let room = StoredMessage.filter(Column("roomId") == roomId && Column("contentType") != "call")
                    .select(Column("id"))
                let hasOlder = try oldest.map {
                    try room.filter($0.olderPredicate).limit(1).asRequest(of: String.self).fetchOne(db) != nil
                } ?? false
                let hasNewer = try !live && (newest.map {
                    try room.filter($0.newerPredicate).limit(1).asRequest(of: String.self).fetchOne(db) != nil
                } ?? false)
                return BoundsPage(revision: revision, hasOlder: hasOlder, hasNewer: hasNewer)
            }
        }

        func fetch(historyRevision: TimelineHistoryRevision? = nil, includingLocalState: Bool = false) throws -> RefreshPage {
            let (records, nextOlder, nextNewer, neighbors, committedHistoryRevision, localState) = try database.read { db in
                let room = StoredMessage
                    .filter(Column("roomId") == roomId && Column("contentType") != "call")
                var query = room.order(Column("timestamp").desc, Column("id").desc)
                if let oldest {
                    query = query.filter(oldest.atOrNewerPredicate)
                    if !live, let newest {
                        query = query.filter(newest.atOrOlderPredicate)
                    }
                } else {
                    query = query.limit(MessageWindow.windowSize)
                }
                let records = try query.fetchAll(db)
                let nextOlder = Cursor.oldest(oldest, records.last.map(Cursor.init))
                let nextNewer = Cursor.newest(newest, records.first.map(Cursor.init))
                let older = try MessageWindow.olderNeighbor(in: db, roomId: roomId, cursor: nextOlder)
                let newer = try MessageWindow.newerNeighbor(
                    in: db, roomId: roomId, cursor: nextNewer, live: live
                )
                return (try MessageDecryptionRepairStore.admitted(records, in: db), nextOlder, nextNewer,
                    try MessageWindow.neighbors(in: db, roomId: roomId, oldest: nextOlder,
                        newest: nextNewer, rawOlder: older, rawNewer: newer), historyRevision?.current ?? 0,
                    includingLocalState ? try ChatTimelineLocalState.fetch(roomId: roomId, in: db) : ChatTimelineLocalState())
            }
            let normalized = previous == records ? records : MessageWindow.normalizedStored(records)
            return RefreshPage(
                revision: revision, stored: normalized,
                cursor: nextOlder, newerCursor: nextNewer,
                neighbors: neighbors, initializesWindow: oldest == nil,
                contentChanged: previous != normalized,
                neighborsChanged: self.neighbors != neighbors,
                committedHistoryRevision: committedHistoryRevision, localState: localState
            )
        }

    }

    struct BoundsPage {
        fileprivate let revision: UInt64
        fileprivate let hasOlder: Bool
        fileprivate let hasNewer: Bool
    }

    @discardableResult
    func applyBounds(_ page: BoundsPage) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard dbQueue.isActive, revision == page.revision, let neighbors = cachedNeighbors else { return false }
        let wasAvailable = hasOlderInDB
        if hasOlderInDB != page.hasOlder || hasNewerInDB != page.hasNewer { revision &+= 1 }
        hasOlderInDB = page.hasOlder
        hasNewerInDB = page.hasNewer
        cachedNeighbors = Neighbors(older: neighbors.older, newer: neighbors.newer,
                                   hasOlder: page.hasOlder, hasNewer: page.hasNewer)
        notifyOlderHistoryAvailable(wasAvailable: wasAvailable)
        return true
    }

    struct RefreshPage {
        fileprivate let revision: UInt64
        let stored: [StoredMessage]
        fileprivate let cursor: Cursor?
        fileprivate let newerCursor: Cursor?
        fileprivate let neighbors: Neighbors
        fileprivate let initializesWindow: Bool
        let contentChanged: Bool
        fileprivate let neighborsChanged: Bool
        let committedHistoryRevision: UInt64
        let localState: ChatTimelineLocalState
        var olderNeighbor: ClusterNeighbor? { neighbors.older }
        var newerNeighbor: ClusterNeighbor? { neighbors.newer }

        func origin(summary: TimelineFlushSummary) -> MessageWindowChangeOrigin {
            initializesWindow ? .initialLoad : .timelineFlush(summary)
        }
        func needsPresentation(force: Bool) -> Bool { contentChanged || neighborsChanged || force }
    }

    func refreshRequest() -> RefreshRequest {
        dispatchPrecondition(condition: .onQueue(.main))
        return RefreshRequest(
            revision: revision, previous: previousStored,
            oldest: olderCursor, newest: newerCursor, live: isAtLiveEdge,
            neighbors: cachedNeighbors, roomId: roomId, database: dbQueue
        )
    }

    func canApply(_ page: RefreshPage) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return dbQueue.isActive && revision == page.revision
    }

    @discardableResult
    func applyRefresh(
        _ page: RefreshPage,
        summary: TimelineFlushSummary,
        forceNotify: Bool = false
    ) -> Bool {
        applyRefresh(page, origin: .timelineFlush(summary),
                     forceNotify: forceNotify || summary.requiresPresentationRefresh)
    }

    @discardableResult
    private func applyRefresh(
        _ page: RefreshPage, origin: MessageWindowChangeOrigin, forceNotify: Bool
    ) -> Bool {
        guard canApply(page) else { return false }
        let wasAvailable = hasOlderInDB
        defer { notifyOlderHistoryAvailable(wasAvailable: wasAvailable) }
        let cursorChanged = olderCursor != page.cursor || newerCursor != page.newerCursor
        olderCursor = page.cursor
        newerCursor = page.newerCursor
        hasOlderInDB = page.neighbors.hasOlder
        hasNewerInDB = page.neighbors.hasNewer
        cachedNeighbors = page.neighbors

        if recoveryFocus == nil, let oldest = page.cursor, let newest = page.newerCursor {
            updateRecoveryFocus(.init(oldest: oldest.timestamp, newest: newest.timestamp))
        }
        // Even an unchanged window may have gained history beyond its edge.
        // Update eligibility above without rebuilding the table. Don't retire
        // an in-flight local page when the complete snapshot is unchanged.
        if page.contentChanged || cursorChanged || page.neighborsChanged { revision &+= 1 }
        guard page.contentChanged || page.neighborsChanged || forceNotify else { return true }

        let previous = previousStored
        previousStored = page.stored
        if page.initializesWindow { generation &+= 1 }
        onChange?(page.stored, previous, page.initializesWindow ? .initialLoad : origin)
        return true
    }

    func refresh(origin: MessageWindowChangeOrigin = .localMutation) {
        guard let page = try? refreshRequest().fetch() else { return }
        applyRefresh(page, origin: origin, forceNotify: true)
    }

    // MARK: - Jump

    func jumpTo(eventId: String) { replaceSynchronously(.event(eventId)) }
    func jumpToLive() { replaceSynchronously(.live) }
    func jumpToOldest() { replaceSynchronously(.oldest) }

    func position(of eventId: String) -> MessageWindowPosition {
        guard let target = queryByEventId(eventId) else {
            return .missing
        }
        guard let olderCursor, let newerCursor else {
            return .inCurrentWindow
        }
        if Cursor(target).precedes(olderCursor) {
            return .olderThanCurrentWindow
        }
        if newerCursor.precedes(Cursor(target)) {
            return .newerThanCurrentWindow
        }
        return .inCurrentWindow
    }

    // MARK: - Cluster Peek

    /// Presentation-only mutations reuse the accepted window boundaries.
    /// Unlike navigation peeks, this never performs a synchronous DB read.
    var presentationNeighbors: (older: ClusterNeighbor?, newer: ClusterNeighbor?) {
        (cachedNeighbors?.older, cachedNeighbors?.newer)
    }

    /// One row just outside the top edge of the window, used by
    /// cluster decoration so the oldest visible message sees its
    /// real predecessor instead of nil.
    func peekOlderNeighbor() -> ClusterNeighbor? {
        boundaryNeighbors(live: isAtLiveEdge).older
    }

    /// Bottom-edge mirror of peekOlderNeighbor. Non-nil when the
    /// session-retained set is not currently at the live edge.
    func peekNewerNeighbor() -> ClusterNeighbor? {
        boundaryNeighbors(live: isAtLiveEdge).newer
    }

    private func boundaryNeighbors(live: Bool) -> Neighbors {
        if let cachedNeighbors { return cachedNeighbors }
        let neighbors = (try? dbQueue.read { db in
            try Self.neighbors(in: db, roomId: roomId, oldest: olderCursor, newest: newerCursor,
                rawOlder: Self.olderNeighbor(in: db, roomId: roomId, cursor: olderCursor),
                rawNewer: Self.newerNeighbor(in: db, roomId: roomId, cursor: newerCursor, live: live))
        }) ?? Neighbors(older: nil, newer: nil, hasOlder: false, hasNewer: false)
        cachedNeighbors = neighbors
        return neighbors
    }

    private static func neighbors(in db: Database, roomId: String, oldest: Cursor?, newest: Cursor?,
                                  rawOlder: StoredMessage?, rawNewer: StoredMessage?) throws -> Neighbors {
        func admittedNeighbor(_ raw: StoredMessage?, cursor: Cursor?, older: Bool) throws -> ClusterNeighbor? {
            guard let raw, let cursor else { return nil }
            if try !MessageDecryptionRepairStore.admitted([raw], in: db).isEmpty { return clusterNeighbor(raw) }
            let query = StoredMessage.filter(Column("roomId") == roomId && Column("contentType") != "call")
                .filter(sql: MessageDecryptionRepairStore.admittedSQL)
            let record = try (older
                ? query.filter(cursor.olderPredicate).order(Column("timestamp").desc, Column("id").desc)
                : query.filter(cursor.newerPredicate).order(Column("timestamp").asc, Column("id").asc)).fetchOne(db)
            return record.map(clusterNeighbor)
        }
        return Neighbors(older: try admittedNeighbor(rawOlder, cursor: oldest, older: true),
            newer: try admittedNeighbor(rawNewer, cursor: newest, older: false),
            hasOlder: rawOlder != nil, hasNewer: rawNewer != nil)
    }

    private static func focus(for records: [StoredMessage]) -> MessageDecryptionRepairStore.Focus? {
        guard let oldest = records.map(\.timestamp).min(), let newest = records.map(\.timestamp).max() else { return nil }
        return .init(oldest: oldest, newest: newest)
    }

    private func updateRecoveryFocus(_ focus: MessageDecryptionRepairStore.Focus?) {
        guard let focus, recoveryFocus != focus else { return }
        recoveryFocus = focus
        onRecoveryFocusChange?(focus)
    }

    private static func clusterNeighbor(_ msg: StoredMessage) -> ClusterNeighbor {
        ClusterNeighbor(
            senderId: msg.senderId,
            timestamp: Date(timeIntervalSince1970: msg.timestamp),
            isStandaloneEvent: Self.isStandaloneEventContentType(msg.contentType),
            mediaGroupId: msg.toChatMessage()?.zynaAttributes.mediaGroup?.id
        )
    }

    func currentStoredMessages() -> [StoredMessage] {
        previousStored ?? []
    }

    // MARK: - GRDB Queries

    private func queryByEventId(_ eventId: String) -> StoredMessage? {
        try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("eventId") == eventId && Column("roomId") == self.roomId)
                .filter(Column("contentType") != "call")
                .fetchOne(db)
        }
    }

    private static func olderNeighbor(in db: Database, roomId: String, cursor: Cursor?) throws -> StoredMessage? {
        guard let cursor else { return nil }
        return try StoredMessage
            .filter(Column("roomId") == roomId && Column("contentType") != "call")
            .filter(cursor.olderPredicate)
            .order(Column("timestamp").desc, Column("id").desc)
            .fetchOne(db)
    }

    private static func newerNeighbor(
        in db: Database, roomId: String, cursor: Cursor?, live: Bool
    ) throws -> StoredMessage? {
        guard !live, let cursor else { return nil }
        return try StoredMessage
            .filter(Column("roomId") == roomId && Column("contentType") != "call")
            .filter(cursor.newerPredicate)
            .order(Column("timestamp").asc, Column("id").asc)
            .fetchOne(db)
    }

    // MARK: - Helpers

    private static func isStandaloneEventContentType(_ contentType: String) -> Bool {
        contentType == "system" || contentType == "matrix_rtc_call"
    }

    private func notifyOlderHistoryAvailable(wasAvailable: Bool) {
        if !wasAvailable && hasOlderInDB { onOlderHistoryAvailable?() }
    }

    private static func normalizedStored(_ stored: [StoredMessage]) -> [StoredMessage] {
        guard stored.count > 1 else { return stored }

        let sorted = stored.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id > rhs.id
            }
            return lhs.timestamp > rhs.timestamp
        }

        func winner(_ lhs: StoredMessage, _ rhs: StoredMessage) -> StoredMessage {
            let lhsScore = messageScore(lhs)
            let rhsScore = messageScore(rhs)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore ? lhs : rhs
            }
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp ? lhs : rhs
            }
            return lhs.id > rhs.id ? lhs : rhs
        }

        var bestByEventId: [String: StoredMessage] = [:]
        var bestByTransactionId: [String: StoredMessage] = [:]

        for message in sorted {
            if let eventId = message.eventId, !eventId.isEmpty {
                if let existing = bestByEventId[eventId] {
                    bestByEventId[eventId] = winner(existing, message)
                } else {
                    bestByEventId[eventId] = message
                }
            }
            if let transactionId = message.transactionId, !transactionId.isEmpty {
                if let existing = bestByTransactionId[transactionId] {
                    bestByTransactionId[transactionId] = winner(existing, message)
                } else {
                    bestByTransactionId[transactionId] = message
                }
            }
        }

        let exactDeduped = sorted.filter { message in
            if let eventId = message.eventId, !eventId.isEmpty {
                return bestByEventId[eventId]?.id == message.id
            }
            if let transactionId = message.transactionId, !transactionId.isEmpty {
                return bestByTransactionId[transactionId]?.id == message.id
            }
            return true
        }

        var syncedTimestampsByFingerprint: [PendingDuplicateFingerprint: [TimeInterval]] = [:]
        for message in exactDeduped
        where message.isOutgoing && message.eventId != nil {
            let fingerprint = PendingDuplicateFingerprint(
                senderId: message.senderId,
                contentType: message.contentType,
                body: message.contentBody ?? "",
                caption: message.contentCaption ?? "",
                filename: message.contentFilename ?? "",
                imageWidth: message.contentImageWidth ?? -1,
                imageHeight: message.contentImageHeight ?? -1,
                zynaAttributesJSON: message.zynaAttributesJSON ?? ""
            )
            syncedTimestampsByFingerprint[fingerprint, default: []].append(message.timestamp)
        }

        return exactDeduped.filter { message in
            guard message.isOutgoing,
                  message.eventId == nil,
                  message.transactionId != nil else {
                return true
            }

            let fingerprint = PendingDuplicateFingerprint(
                senderId: message.senderId,
                contentType: message.contentType,
                body: message.contentBody ?? "",
                caption: message.contentCaption ?? "",
                filename: message.contentFilename ?? "",
                imageWidth: message.contentImageWidth ?? -1,
                imageHeight: message.contentImageHeight ?? -1,
                zynaAttributesJSON: message.zynaAttributesJSON ?? ""
            )
            guard let timestamps = syncedTimestampsByFingerprint[fingerprint] else {
                return true
            }
            return !timestamps.contains(where: { abs($0 - message.timestamp) < 3 })
        }
    }

    private static func messageScore(_ message: StoredMessage) -> Int {
        var score = 0
        if message.contentType == "redacted" { score += 1_000 }
        if message.eventId != nil { score += 100 }
        if message.transactionId != nil { score += 20 }
        switch message.sendStatus {
        case "read":
            score += 12
        case "synced":
            score += 10
        case "sent":
            score += 8
        case "sending":
            score += 2
        default:
            score += 4
        }
        if !(message.zynaAttributesJSON ?? "").isEmpty {
            score += 1
        }
        return score
    }
}
