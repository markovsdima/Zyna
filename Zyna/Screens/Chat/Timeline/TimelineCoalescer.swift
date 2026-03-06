//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// Buffers raw SDK timeline diffs and flushes them as a single batch update
/// after a 50 ms debounce window. All state is accessed on the main queue.
final class TimelineCoalescer {

    /// Fired on the main queue with the new display-order messages and a table update.
    var onBatchReady: (([ChatMessage], TableUpdate) -> Void)?

    // MARK: - Private State

    /// Timeline items in chronological SDK order.
    private var currentItems: [TimelineItem] = []

    /// Messages in display order (reversed chronological for the inverted table).
    private var displayMessages: [ChatMessage] = []

    private var pendingDiffs: [TimelineDiff] = []
    private var debounceWork: DispatchWorkItem?

    private static let debounceInterval: TimeInterval = 0.05
    private static let maxDiffsBeforeReload = 50
    private static let maxOpsBeforeReload = 100

    // MARK: - Public

    /// Called from the SDK listener thread. Enqueues diffs and schedules a flush.
    func receive(diffs: [TimelineDiff]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingDiffs.append(contentsOf: diffs)
            self.scheduleFlush()
        }
    }

    // MARK: - Debounce

    private func scheduleFlush() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    // MARK: - Flush

    private func flush() {
        let diffs = pendingDiffs
        pendingDiffs.removeAll()
        guard !diffs.isEmpty else { return }

        let oldMessages = displayMessages
        var hadResetOrClear = false

        for diff in diffs {
            switch diff.change() {
            case .reset, .clear:
                hadResetOrClear = true
            default:
                break
            }
            applySingleDiff(diff)
        }

        // Full re-map: SDK may mutate TimelineItem objects in-place (e.g. decryption)
        let chronological = currentItems.compactMap { TimelineService.mapTimelineItem($0) }
        displayMessages = Array(chronological.reversed())

        let tableUpdate: TableUpdate
        if hadResetOrClear || diffs.count > Self.maxDiffsBeforeReload {
            tableUpdate = .reload
        } else {
            tableUpdate = computeBatchUpdate(old: oldMessages, new: displayMessages)
        }

        onBatchReady?(displayMessages, tableUpdate)
    }

    // MARK: - Apply Single Diff

    // swiftlint:disable:next cyclomatic_complexity
    private func applySingleDiff(_ diff: TimelineDiff) {
        switch diff.change() {
        case .append:
            guard let items = diff.append() else { return }
            currentItems.append(contentsOf: items)

        case .pushBack:
            guard let item = diff.pushBack() else { return }
            currentItems.append(item)

        case .pushFront:
            guard let item = diff.pushFront() else { return }
            currentItems.insert(item, at: 0)

        case .insert:
            guard let update = diff.insert() else { return }
            let idx = Int(update.index)
            guard idx <= currentItems.count else { return }
            currentItems.insert(update.item, at: idx)

        case .set:
            guard let update = diff.set() else { return }
            let idx = Int(update.index)
            guard idx < currentItems.count else { return }
            currentItems[idx] = update.item

        case .remove:
            guard let index = diff.remove() else { return }
            let idx = Int(index)
            guard idx < currentItems.count else { return }
            currentItems.remove(at: idx)

        case .popBack:
            guard !currentItems.isEmpty else { return }
            currentItems.removeLast()

        case .popFront:
            guard !currentItems.isEmpty else { return }
            currentItems.removeFirst()

        case .reset:
            currentItems = diff.reset() ?? []

        case .truncate:
            if let length = diff.truncate() {
                currentItems = Array(currentItems.prefix(Int(length)))
            }

        case .clear:
            currentItems = []
        }
    }

    // MARK: - Batch Update Computation

    private func computeBatchUpdate(old: [ChatMessage], new: [ChatMessage]) -> TableUpdate {
        if old.isEmpty && !new.isEmpty { return .reload }
        if old == new { return .batch(deletions: [], insertions: [], updates: []) }

        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)

        let structuralDiff = newIDs.difference(from: oldIDs)
        let hasStructuralChanges = !structuralDiff.isEmpty

        // Content-only changes: same id, different content
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var contentUpdates: [IndexPath] = []
        for (index, msg) in new.enumerated() {
            if let oldMsg = oldByID[msg.id], oldMsg != msg {
                contentUpdates.append(IndexPath(row: index, section: 0))
            }
        }
        let hasContentChanges = !contentUpdates.isEmpty

        // Mixed structural + content changes → safest to reload
        if hasStructuralChanges && hasContentChanges {
            return .reload
        }

        if hasStructuralChanges {
            let opCount = structuralDiff.insertions.count + structuralDiff.removals.count
            if opCount > Self.maxOpsBeforeReload {
                return .reload
            }

            var deletions: [IndexPath] = []
            var insertions: [IndexPath] = []

            for change in structuralDiff {
                switch change {
                case .remove(let offset, _, _):
                    deletions.append(IndexPath(row: offset, section: 0))
                case .insert(let offset, _, _):
                    insertions.append(IndexPath(row: offset, section: 0))
                }
            }

            return .batch(deletions: deletions, insertions: insertions, updates: [])
        }

        // Content-only changes
        return .batch(deletions: [], insertions: [], updates: contentUpdates)
    }
}
