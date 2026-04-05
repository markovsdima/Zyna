//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Manages a cursor-based sliding window of messages for a single room.
/// Queries GRDB on demand instead of observing all rows.
/// All methods must be called on the main queue.
final class MessageWindow {

    // MARK: - Configuration

    static let windowSize = 200
    static let pageSize = 50
    private static let trimThreshold = 50

    // MARK: - State

    private(set) var oldestTimestamp: TimeInterval?
    private(set) var newestTimestamp: TimeInterval?
    private(set) var hasOlderInDB = true
    private(set) var hasNewerInDB = false

    var isAtLiveEdge: Bool { !hasNewerInDB }

    // MARK: - Dependencies

    private let roomId: String
    private let dbQueue: DatabaseQueue
    private let log = ScopedLog(.database)

    // MARK: - Callback

    /// Fired after any window content change with (new, previous).
    var onChange: ((_ new: [StoredMessage], _ previous: [StoredMessage]?) -> Void)?

    private var previousStored: [StoredMessage]?

    // MARK: - Init

    init(roomId: String, dbQueue: DatabaseQueue) {
        self.roomId = roomId
        self.dbQueue = dbQueue
    }

    // MARK: - Initial Load

    func loadInitial() {
        let stored = queryNewest(limit: Self.windowSize)
        updateCursors(from: stored)
        hasNewerInDB = false
        hasOlderInDB = stored.count >= Self.windowSize || checkHasOlderInDB()
        emitChange(stored)
        log("loadInitial: \(stored.count) messages")
    }

    // MARK: - Load Older (scroll up)

    /// Result of an older-page GRDB query, ready to be applied on main.
    struct OlderPage {
        let merged: [StoredMessage]
        let fetchedCount: Int
        let trimmed: Bool
    }

    /// Pure GRDB read + merge/sort. Safe to call from any queue.
    /// Returns nil when there's nothing to load.
    func queryOlder(count: Int = pageSize) -> OlderPage? {
        guard let oldestTs = oldestTimestamp else { return nil }

        let older = queryOlderThan(timestamp: oldestTs, limit: count)
        guard !older.isEmpty else { return nil }

        var all = (previousStored ?? []) + older
        all.sort { $0.timestamp > $1.timestamp }

        let maxSize = Self.windowSize + Self.trimThreshold
        var trimmed = false
        if all.count > maxSize {
            all = Array(all.suffix(Self.windowSize))
            trimmed = true
        }
        return OlderPage(
            merged: all, fetchedCount: older.count, trimmed: trimmed
        )
    }

    /// Apply a pre-computed older page on the main thread. Mutates
    /// cursors, flags, and fires onChange.
    func applyOlder(_ page: OlderPage) {
        if page.trimmed { hasNewerInDB = true }
        updateCursors(from: page.merged)
        hasOlderInDB = checkHasOlderInDB()
        emitChange(page.merged)
        log("loadOlder: +\(page.fetchedCount), window=\(page.merged.count)")
    }

    /// Legacy single-shot helper — performs both query and apply
    /// synchronously on the caller's thread. Use for code paths
    /// that are already on main. For bg-queue entry points, call
    /// `queryOlder` then marshal `applyOlder` to main.
    @discardableResult
    func loadOlder(count: Int = pageSize) -> Bool {
        guard let page = queryOlder(count: count) else {
            if oldestTimestamp != nil { hasOlderInDB = false }
            return false
        }
        applyOlder(page)
        return true
    }

    // MARK: - Load Newer (scroll down)

    /// Returns true if messages were loaded.
    @discardableResult
    func loadNewer(count: Int = pageSize) -> Bool {
        guard let newestTs = newestTimestamp, hasNewerInDB else { return false }

        let newer = queryNewerThan(timestamp: newestTs, limit: count)
        guard !newer.isEmpty else {
            hasNewerInDB = false
            return false
        }

        // Build new window: newer + existing
        var all = newer + (previousStored ?? [])
        all.sort { $0.timestamp > $1.timestamp }

        // Trim oldest end if too large
        let maxSize = Self.windowSize + Self.trimThreshold
        if all.count > maxSize {
            all = Array(all.prefix(Self.windowSize))
            hasOlderInDB = true
        }

        updateCursors(from: all)
        hasNewerInDB = checkHasNewerInDB()
        emitChange(all)
        log("loadNewer: +\(newer.count), window=\(all.count)")
        return true
    }

    // MARK: - Refresh (batcher flush callback)

    func refresh() {
        guard let oldestTs = oldestTimestamp else {
            loadInitial()
            return
        }

        if isAtLiveEdge {
            // Extend to include new messages
            let stored = queryNewest(limit: Self.windowSize)
            updateCursors(from: stored)
            hasNewerInDB = false
            hasOlderInDB = stored.count >= Self.windowSize || checkHasOlderInDB()
            emitChange(stored)
        } else {
            // Re-query existing bounds (picks up updates/redactions)
            guard let newestTs = newestTimestamp else { return }
            let stored = queryRange(from: oldestTs, to: newestTs)
            updateCursors(from: stored)
            emitChange(stored)
        }
    }

    // MARK: - Jump

    func jumpTo(eventId: String) {
        guard let target = queryByEventId(eventId) else { return }
        let targetTs = target.timestamp
        let half = Self.windowSize / 2

        let olderHalf = queryOlderThan(timestamp: targetTs + 0.001, limit: half)
        let newerHalf = queryNewerThan(timestamp: targetTs - 0.001, limit: half)

        var combined = newerHalf + olderHalf
        if !combined.contains(where: { $0.id == target.id }) {
            combined.append(target)
        }
        combined.sort { $0.timestamp > $1.timestamp }

        updateCursors(from: combined)
        hasOlderInDB = checkHasOlderInDB()
        hasNewerInDB = checkHasNewerInDB()
        emitChange(combined)
        log("jumpTo \(eventId): window=\(combined.count)")
    }

    func jumpToLive() {
        loadInitial()
    }

    func jumpToOldest() {
        let stored = queryOldest(limit: Self.windowSize)
        updateCursors(from: stored)
        hasOlderInDB = false
        hasNewerInDB = checkHasNewerInDB()
        emitChange(stored)
        log("jumpToOldest: window=\(stored.count)")
    }

    // MARK: - GRDB Queries

    private func queryNewest(limit: Int) -> [StoredMessage] {
        (try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == self.roomId)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    private func queryOldest(limit: Int) -> [StoredMessage] {
        let asc = (try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == self.roomId)
                .order(Column("timestamp").asc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        return asc.reversed()
    }

    private func queryOlderThan(timestamp: TimeInterval, limit: Int) -> [StoredMessage] {
        (try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == self.roomId && Column("timestamp") < timestamp)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    private func queryNewerThan(timestamp: TimeInterval, limit: Int) -> [StoredMessage] {
        let asc = (try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == self.roomId && Column("timestamp") > timestamp)
                .order(Column("timestamp").asc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        return asc.reversed()
    }

    private func queryRange(from oldest: TimeInterval, to newest: TimeInterval) -> [StoredMessage] {
        (try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == self.roomId
                    && Column("timestamp") >= oldest
                    && Column("timestamp") <= newest)
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }) ?? []
    }

    private func queryByEventId(_ eventId: String) -> StoredMessage? {
        try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("eventId") == eventId && Column("roomId") == self.roomId)
                .fetchOne(db)
        }
    }

    private func checkHasOlderInDB() -> Bool {
        guard let oldestTs = oldestTimestamp else { return false }
        return ((try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == self.roomId && Column("timestamp") < oldestTs)
                .limit(1)
                .fetchCount(db)
        }) ?? 0) > 0
    }

    private func checkHasNewerInDB() -> Bool {
        guard let newestTs = newestTimestamp else { return false }
        return ((try? dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == self.roomId && Column("timestamp") > newestTs)
                .limit(1)
                .fetchCount(db)
        }) ?? 0) > 0
    }

    // MARK: - Helpers

    private func updateCursors(from stored: [StoredMessage]) {
        newestTimestamp = stored.first?.timestamp
        oldestTimestamp = stored.last?.timestamp
    }

    private func emitChange(_ stored: [StoredMessage]) {
        let prev = previousStored
        previousStored = stored
        onChange?(stored, prev)
    }
}
