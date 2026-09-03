//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK
import QuartzCore

/// One row per SDK timeline item, kept in SDK order (index 0 = oldest) so
/// `VectorDiff` indices stay aligned. Non-media rows survive as `.other`.
enum AttachmentRow: Equatable {
    case attachment(AttachmentItem)
    case pendingDecryption(PendingDecryption)
    case other(uniqueId: String)

    var uniqueId: String {
        switch self {
        case .attachment(let item): return item.uniqueId
        case .pendingDecryption(let pending): return pending.uniqueId
        case .other(let uniqueId): return uniqueId
        }
    }

    var attachment: AttachmentItem? {
        if case .attachment(let item) = self { return item }
        return nil
    }

    var pendingDecryption: PendingDecryption? {
        if case .pendingDecryption(let pending) = self { return pending }
        return nil
    }
}

/// `TimelineDiff` with items already mapped to rows. Tests feed these
/// directly; production maps from the SDK on the store queue.
enum AttachmentRowDiff {
    case append([AttachmentRow])
    case clear
    case pushFront(AttachmentRow)
    case pushBack(AttachmentRow)
    case popFront
    case popBack
    case insert(Int, AttachmentRow)
    case set(Int, AttachmentRow)
    case remove(Int)
    case truncate(Int)
    case reset([AttachmentRow])
}

/// Ordered applier for the attachments timeline.
///
/// The SDK listener is synchronous and diffs are positional, so they are
/// applied on one serial queue in arrival order; `Task {}` per callback
/// would not preserve that. Snapshots are published on the main queue,
/// coalesced so a pagination burst yields one update.
final class AttachmentTimelineStore {

    struct Snapshot: Equatable {
        let generation: Int
        let rowCount: Int
        let media: [AttachmentMonthGroup]
        let files: [AttachmentMonthGroup]
        let mediaCount: Int
        let fileCount: Int
        let pendingCount: Int
        /// Sorted, unique Megolm session ids of undecrypted rows.
        let pendingSessionIds: [String]

        static let empty = Snapshot(
            generation: 0, rowCount: 0, media: [], files: [],
            mediaCount: 0, fileCount: 0, pendingCount: 0, pendingSessionIds: []
        )
    }

    struct ApplySummary: Equatable {
        var diffs = 0
        var appended = 0
        var inserted = 0
        var set = 0
        var removed = 0
        var resets = 0
        var clears = 0
        var indexErrors = 0
        /// Event ids whose row went from `.pendingDecryption` to `.attachment`.
        var utdResolvedToMedia: [String] = []
        /// Pending rows replaced by non-attachments or removed: decrypted into
        /// text (the SDK removes those from a message-only timeline).
        var utdResolvedToOther = 0
        /// Event ids whose attachment row was replaced by a non-attachment or removed.
        var mediaRemoved: [String] = []
        var mapMs: Double = 0
        var applyMs: Double = 0

        mutating func merge(_ other: ApplySummary) {
            diffs += other.diffs
            appended += other.appended
            inserted += other.inserted
            set += other.set
            removed += other.removed
            resets += other.resets
            clears += other.clears
            indexErrors += other.indexErrors
            utdResolvedToMedia += other.utdResolvedToMedia
            utdResolvedToOther += other.utdResolvedToOther
            mediaRemoved += other.mediaRemoved
            mapMs += other.mapMs
            applyMs += other.applyMs
        }
    }

    /// Called on the main queue.
    var onSnapshot: ((Snapshot, ApplySummary) -> Void)?

    private let queue = DispatchQueue(label: "com.zyna.attachments.store", qos: .userInitiated)
    private let publishDelay: TimeInterval
    private var rows: [AttachmentRow] = []
    private var generation = 0
    private var pendingSummary = ApplySummary()
    private var publishWorkItem: DispatchWorkItem?
    private var lastPublishTime: CFTimeInterval = 0

    init(publishDelay: TimeInterval = 0.05) {
        self.publishDelay = publishDelay
    }

    // MARK: - Input

    /// Entry point for the SDK listener (any thread).
    func enqueue(_ diffs: [TimelineDiff]) {
        queue.async { [weak self] in
            guard let self else { return }
            let mapStart = CACurrentMediaTime()
            let rowDiffs = diffs.map(Self.rowDiff(from:))
            let mapMs = (CACurrentMediaTime() - mapStart) * 1000
            var summary = self.applyOnQueue(rowDiffs)
            summary.mapMs = mapMs
            self.pendingSummary.merge(summary)
            self.schedulePublish()
        }
    }

    /// Synchronous apply; the test seam.
    @discardableResult
    func apply(_ diffs: [AttachmentRowDiff]) -> ApplySummary {
        queue.sync {
            let summary = applyOnQueue(diffs)
            pendingSummary.merge(summary)
            schedulePublish()
            return summary
        }
    }

    func currentSnapshot() -> Snapshot {
        queue.sync { makeSnapshot() }
    }

    var currentRows: [AttachmentRow] {
        queue.sync { rows }
    }

    // MARK: - Mapping

    static func row(from item: TimelineItem) -> AttachmentRow {
        let uniqueId = item.uniqueId().id
        guard let event = item.asEvent() else {
            return .other(uniqueId: uniqueId)
        }
        if let attachment = AttachmentItem.make(from: event, uniqueId: uniqueId) {
            return .attachment(attachment)
        }
        if let pending = PendingDecryption.make(from: event, uniqueId: uniqueId) {
            return .pendingDecryption(pending)
        }
        return .other(uniqueId: uniqueId)
    }

    private static func rowDiff(from diff: TimelineDiff) -> AttachmentRowDiff {
        switch diff {
        case .append(let values): return .append(values.map(row(from:)))
        case .clear: return .clear
        case .pushFront(let value): return .pushFront(row(from: value))
        case .pushBack(let value): return .pushBack(row(from: value))
        case .popFront: return .popFront
        case .popBack: return .popBack
        case .insert(let index, let value): return .insert(Int(index), row(from: value))
        case .set(let index, let value): return .set(Int(index), row(from: value))
        case .remove(let index): return .remove(Int(index))
        case .truncate(let length): return .truncate(Int(length))
        case .reset(let values): return .reset(values.map(row(from:)))
        }
    }

    // MARK: - Apply (queue only)

    private func applyOnQueue(_ diffs: [AttachmentRowDiff]) -> ApplySummary {
        let start = CACurrentMediaTime()
        var summary = ApplySummary()
        summary.diffs = diffs.count

        for diff in diffs {
            switch diff {
            case .append(let newRows):
                rows.append(contentsOf: newRows)
                summary.appended += newRows.count

            case .clear:
                noteRemoval(of: rows, in: &summary)
                rows.removeAll()
                summary.clears += 1

            case .pushFront(let row):
                rows.insert(row, at: 0)
                summary.inserted += 1

            case .pushBack(let row):
                rows.append(row)
                summary.appended += 1

            case .popFront:
                guard !rows.isEmpty else { summary.indexErrors += 1; continue }
                noteRemoval(of: [rows.removeFirst()], in: &summary)

            case .popBack:
                guard !rows.isEmpty else { summary.indexErrors += 1; continue }
                noteRemoval(of: [rows.removeLast()], in: &summary)

            case .insert(let index, let row):
                guard index >= 0, index <= rows.count else { summary.indexErrors += 1; continue }
                rows.insert(row, at: index)
                summary.inserted += 1

            case .set(let index, let row):
                guard rows.indices.contains(index) else { summary.indexErrors += 1; continue }
                let previous = rows[index]
                if previous.pendingDecryption != nil {
                    if let item = row.attachment {
                        summary.utdResolvedToMedia.append(item.id)
                    } else if row.pendingDecryption == nil {
                        summary.utdResolvedToOther += 1
                    }
                }
                if let previousItem = previous.attachment, row.attachment == nil {
                    summary.mediaRemoved.append(previousItem.id)
                }
                rows[index] = row
                summary.set += 1

            case .remove(let index):
                guard rows.indices.contains(index) else { summary.indexErrors += 1; continue }
                noteRemoval(of: [rows.remove(at: index)], in: &summary)

            case .truncate(let length):
                guard length >= 0, length <= rows.count else { summary.indexErrors += 1; continue }
                noteRemoval(of: Array(rows[length...]), in: &summary)
                rows.removeSubrange(length...)

            case .reset(let newRows):
                rows = newRows
                summary.resets += 1
            }
        }

        generation += 1
        summary.applyMs = (CACurrentMediaTime() - start) * 1000
        return summary
    }

    private func noteRemoval(of removed: [AttachmentRow], in summary: inout ApplySummary) {
        summary.removed += removed.count
        for row in removed {
            if let item = row.attachment {
                summary.mediaRemoved.append(item.id)
            } else if row.pendingDecryption != nil {
                summary.utdResolvedToOther += 1
            }
        }
    }

    // MARK: - Snapshot

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        return formatter
    }()

    private func makeSnapshot() -> Snapshot {
        var mediaItems: [AttachmentItem] = []
        var fileItems: [AttachmentItem] = []
        var pendingCount = 0
        var sessionIds = Set<String>()

        for row in rows.reversed() {
            switch row {
            case .attachment(let item):
                if item.kind.isVisual {
                    mediaItems.append(item)
                } else {
                    fileItems.append(item)
                }
            case .pendingDecryption(let pending):
                pendingCount += 1
                if let sessionId = pending.sessionId {
                    sessionIds.insert(sessionId)
                }
            case .other:
                break
            }
        }

        return Snapshot(
            generation: generation,
            rowCount: rows.count,
            media: Self.groupByMonth(mediaItems),
            files: Self.groupByMonth(fileItems),
            mediaCount: mediaItems.count,
            fileCount: fileItems.count,
            pendingCount: pendingCount,
            pendingSessionIds: sessionIds.sorted()
        )
    }

    /// Items arrive newest-first, so consecutive runs share a month.
    static func groupByMonth(_ items: [AttachmentItem], now: Date = Date()) -> [AttachmentMonthGroup] {
        var groups: [AttachmentMonthGroup] = []
        var currentKey: String?
        var currentItems: [AttachmentItem] = []
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.year, .month], from: now)

        func flush() {
            guard let key = currentKey, let first = currentItems.first else { return }
            let components = calendar.dateComponents([.year, .month], from: first.date)
            let title: String
            if components.year == nowComponents.year, components.month == nowComponents.month {
                title = String(localized: "This Month")
            } else {
                title = titleFormatter.string(from: first.date).capitalized
            }
            groups.append(AttachmentMonthGroup(id: key, title: title, items: currentItems))
            currentItems = []
        }

        for item in items {
            let components = calendar.dateComponents([.year, .month], from: item.date)
            let key = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
            if key != currentKey {
                flush()
                currentKey = key
            }
            currentItems.append(item)
        }
        flush()
        return groups
    }

    /// Leading edge + trailing debounce. A pagination batch is a single
    /// diff after a quiet period, so it is published immediately and the
    /// fill loop never waits out the debounce; bursts (initial reset,
    /// live updates arriving together) still collapse into one trailing
    /// publish.
    private func schedulePublish() {
        publishWorkItem?.cancel()
        publishWorkItem = nil
        if CACurrentMediaTime() - lastPublishTime >= publishDelay {
            publishNow()
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.publishNow()
        }
        publishWorkItem = workItem
        queue.asyncAfter(deadline: .now() + publishDelay, execute: workItem)
    }

    private func publishNow() {
        lastPublishTime = CACurrentMediaTime()
        publishWorkItem = nil
        let snapshot = makeSnapshot()
        let summary = pendingSummary
        pendingSummary = ApplySummary()
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot, summary)
        }
    }
}
