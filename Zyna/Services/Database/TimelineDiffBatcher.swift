//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK

/// Accumulates SDK timeline diffs and flushes them to GRDB in a single
/// transaction after a 50 ms debounce window. Maintains a shadow
/// array for positional diff handling (SDK diffs reference items by index).
final class TimelineDiffBatcher {

    private let roomId: String
    private let dbQueue: DatabaseQueue
    private let log = ScopedLog(.database)
    private let writeQueue = DispatchQueue(label: "com.zyna.db.write", qos: .userInitiated)

    // MARK: - Shadow array

    /// Mirrors SDK timeline positions. Stores ChatMessage.id if mappable, nil otherwise.
    private var shadowItems: [String?] = []

    // MARK: - Pending ops

    private enum DiffOp {
        case upsert(StoredMessage)
        case delete(String)
    }

    private var pendingOps: [DiffOp] = []
    private var debounceWork: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.05

    /// Timestamp of the newest own message read by someone else.
    /// Updated from TimelineService when SDK delivers read receipts.
    private var readCursorTimestamp: TimeInterval?

    /// Called on main queue after each successful flush.
    var onFlush: (() -> Void)?

    // MARK: - Init

    init(roomId: String, dbQueue: DatabaseQueue) {
        self.roomId = roomId
        self.dbQueue = dbQueue
    }

    /// Update read cursor from SDK read receipts. Called from main queue.
    func updateReadCursor(timestamp: TimeInterval) {
        if readCursorTimestamp == nil || timestamp > readCursorTimestamp! {
            readCursorTimestamp = timestamp
            scheduleFlush()
        }
    }

    // MARK: - Public

    /// Called from the SDK listener thread with raw timeline diffs.
    func receive(diffs: [TimelineDiff]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let types = diffs.map { Self.diffName($0) }
            self.log("Received diffs: \(types.joined(separator: ", "))")
            for diff in diffs {
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

    // MARK: - Debounce

    private func scheduleFlush() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    // MARK: - Flush

    private func flush() {
        let ops = pendingOps
        pendingOps.removeAll()
        let cursorTs = readCursorTimestamp
        readCursorTimestamp = nil

        guard !ops.isEmpty || cursorTs != nil else { return }

        let roomId = self.roomId
        let dbQueue = self.dbQueue

        writeQueue.async { [weak self] in
            do {
                try dbQueue.write { db in
                    // Collect eventIds already marked as read so upserts don't downgrade them
                    let readEventIds = try Set(String.fetchAll(db,
                        sql: "SELECT eventId FROM storedMessage WHERE roomId = ? AND sendStatus = 'read' AND isOutgoing = 1 AND eventId IS NOT NULL",
                        arguments: [roomId]))

                    for op in ops {
                        switch op {
                        case .upsert(var record):
                            if record.sendStatus != "read",
                               let eventId = record.eventId,
                               readEventIds.contains(eventId) {
                                record.sendStatus = "read"
                            }

                            if let eventId = record.eventId {
                                try StoredMessage
                                    .filter(Column("roomId") == record.roomId && Column("eventId") == eventId && Column("id") != record.id)
                                    .deleteAll(db)
                            }
                            if let txnId = record.transactionId {
                                try StoredMessage
                                    .filter(Column("roomId") == record.roomId && Column("transactionId") == txnId && Column("id") != record.id)
                                    .deleteAll(db)
                            }
                            try record.save(db)
                        case .delete(let id):
                            _ = try StoredMessage.deleteOne(db, key: id)
                        }
                    }

                    // Mark all outgoing messages up to the read cursor as "read"
                    if let cursorTs {
                        try db.execute(
                            sql: """
                                UPDATE storedMessage
                                SET sendStatus = 'read'
                                WHERE roomId = ? AND isOutgoing = 1
                                  AND timestamp <= ? AND sendStatus != 'read'
                                """,
                            arguments: [roomId, cursorTs]
                        )
                    }
                }

                let total = try dbQueue.read { db in
                    try StoredMessage.filter(Column("roomId") == roomId).fetchCount(db)
                }

                let upserts = ops.filter { if case .upsert = $0 { return true }; return false }.count
                let deletes = ops.count - upserts

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onFlush?()
                    self.log("Flushed \(ops.count) ops (\(upserts)↑ \(deletes)↓) for room \(roomId) — \(total) stored")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.log("Flush failed: \(error)")
                }
            }
        }
    }

    // MARK: - Enqueue

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
            shadowItems.insert(msg.map { storedId($0.id) }, at: 0)
            if let msg {
                pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
            }

        case .insert(let index, let item):
            let idx = Int(index)
            guard idx <= shadowItems.count else { return }
            let msg = TimelineService.mapTimelineItem(item)
            shadowItems.insert(msg.map { storedId($0.id) }, at: idx)
            if let msg {
                pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
            }

        case .set(let index, let item):
            let idx = Int(index)
            guard idx < shadowItems.count else { return }
            let oldId = shadowItems[idx]
            let msg = TimelineService.mapTimelineItem(item)
            shadowItems[idx] = msg.map { storedId($0.id) }

            if let msg {
                let newStoredId = storedId(msg.id)
                if let oldId, oldId != newStoredId {
                    pendingOps.append(.delete(oldId))
                }
                pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
            }

        case .remove(let index):
            let idx = Int(index)
            guard idx < shadowItems.count else { return }
            shadowItems.remove(at: idx)

        case .popBack:
            guard !shadowItems.isEmpty else { return }
            shadowItems.removeLast()

        case .popFront:
            guard !shadowItems.isEmpty else { return }
            shadowItems.removeFirst()

        case .reset(let items):
            shadowItems.removeAll()
            for item in items {
                appendItem(item)
            }

        case .truncate(let length):
            let len = Int(length)
            while shadowItems.count > len {
                shadowItems.removeLast()
            }

        case .clear:
            shadowItems.removeAll()
        }
    }

    // MARK: - Helpers

    private func storedId(_ msgId: String) -> String {
        "\(roomId):\(msgId)"
    }

    private func appendItem(_ item: TimelineItem) {
        let msg = TimelineService.mapTimelineItem(item)
        shadowItems.append(msg.map { storedId($0.id) })
        if let msg {
            pendingOps.append(.upsert(StoredMessage(from: msg, roomId: roomId)))
        }
    }
}
