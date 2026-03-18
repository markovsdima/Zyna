//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// Buffers raw SDK timeline diffs and flushes them as a single batch update
/// after a 50 ms debounce window. All state is accessed on the main queue.
///
/// Maintains an incremental ChatMessage array so only changed items are re-mapped,
/// and computes fine-grained TableUpdate (never falls back to .reload except for
/// .reset / .clear diffs).
final class TimelineCoalescer {

    /// Fired on the main queue with the new display-order messages and a table update.
    var onBatchReady: (([ChatMessage], TableUpdate) -> Void)?

    // MARK: - Private State

    /// Timeline items in chronological SDK order.
    private var currentItems: [TimelineItem] = []

    /// Whether each currentItems[i] maps to a ChatMessage.
    private var isMappable: [Bool] = []

    /// Chat messages in chronological order (only mappable items).
    private var chronMessages: [ChatMessage] = []

    /// Messages in display order (reversed chronological for the inverted table).
    private var displayMessages: [ChatMessage] = []

    /// IDs of messages hidden after paint-splash animation (redacted and dismissed).
    private var hiddenIds = Set<String>()

    private var pendingDiffs: [TimelineDiff] = []
    private var debounceWork: DispatchWorkItem?

    private static let debounceInterval: TimeInterval = 0.05

    // MARK: - Public

    /// Called from the SDK listener thread. Enqueues diffs and schedules a flush.
    func receive(diffs: [TimelineDiff]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingDiffs.append(contentsOf: diffs)
            self.scheduleFlush()
        }
    }

    /// Permanently hides a message from the display array (called after splash animation).
    func hide(_ messageId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hiddenIds.insert(messageId)

            let oldDisplay = self.displayMessages
            self.displayMessages = self.chronMessages.reversed().filter { msg in
                !self.hiddenIds.contains(msg.id) && !msg.content.isRedacted
            }

            guard let oldIdx = oldDisplay.firstIndex(where: { $0.id == messageId }) else { return }
            self.onBatchReady?(self.displayMessages, .batch(
                deletions: [IndexPath(row: oldIdx, section: 0)],
                insertions: [],
                updates: [],
                animated: false
            ))
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

        let oldDisplayMessages = displayMessages
        var updatedIds = Set<String>()
        var hadResetOrClear = false

        for diff in diffs {
            switch diff {
            case .reset, .clear:
                hadResetOrClear = true
            default:
                break
            }
            applySingleDiff(diff, updatedIds: &updatedIds)
        }

        // Filter out: hidden (post-animation) and already-redacted (historical).
        // Keep live redactions (in updatedIds) so the controller can animate them first.
        displayMessages = chronMessages.reversed().filter { msg in
            !hiddenIds.contains(msg.id) && (!msg.content.isRedacted || updatedIds.contains(msg.id))
        }

        if hadResetOrClear {
            onBatchReady?(displayMessages, .reload)
            return
        }

        if oldDisplayMessages == displayMessages {
            return
        }

        // Structural diff on IDs
        let oldIDs = oldDisplayMessages.map(\.id)
        let newIDs = displayMessages.map(\.id)
        let idDiff = newIDs.difference(from: oldIDs)

        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var removedOldOffsets = Set<Int>()

        for change in idDiff {
            switch change {
            case .remove(let offset, _, _):
                deletions.append(IndexPath(row: offset, section: 0))
                removedOldOffsets.insert(offset)
            case .insert(let offset, _, _):
                insertions.append(IndexPath(row: offset, section: 0))
            }
        }

        // Content updates: old indices for items whose content changed (excluding removed)
        var updates: [IndexPath] = []
        if !updatedIds.isEmpty {
            for (oldIdx, msg) in oldDisplayMessages.enumerated() {
                if updatedIds.contains(msg.id) && !removedOldOffsets.contains(oldIdx) {
                    updates.append(IndexPath(row: oldIdx, section: 0))
                }
            }
        }

        // Animate only single-message appends with no other changes
        let animated = deletions.isEmpty && insertions.count == 1 && updates.isEmpty

        onBatchReady?(displayMessages, .batch(
            deletions: deletions,
            insertions: insertions,
            updates: updates,
            animated: animated
        ))
    }

    // MARK: - Apply Single Diff (incremental)

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func applySingleDiff(_ diff: TimelineDiff, updatedIds: inout Set<String>) {
        switch diff {

        case .append(let items):
            for item in items {
                currentItems.append(item)
                if let msg = TimelineService.mapTimelineItem(item) {
                    chronMessages.append(msg)
                    isMappable.append(true)
                } else {
                    isMappable.append(false)
                }
            }

        case .pushBack(let item):
            currentItems.append(item)
            if let msg = TimelineService.mapTimelineItem(item) {
                chronMessages.append(msg)
                isMappable.append(true)
            } else {
                isMappable.append(false)
            }

        case .pushFront(let item):
            currentItems.insert(item, at: 0)
            if let msg = TimelineService.mapTimelineItem(item) {
                chronMessages.insert(msg, at: 0)
                isMappable.insert(true, at: 0)
            } else {
                isMappable.insert(false, at: 0)
            }

        case .insert(let index, let item):
            let idx = Int(index)
            guard idx <= currentItems.count else { return }
            currentItems.insert(item, at: idx)
            if let msg = TimelineService.mapTimelineItem(item) {
                let msgIdx = chatMessageIndex(forTimelineIndex: idx)
                chronMessages.insert(msg, at: msgIdx)
                isMappable.insert(true, at: idx)
            } else {
                isMappable.insert(false, at: idx)
            }

        case .set(let index, let item):
            let idx = Int(index)
            guard idx < currentItems.count else { return }

            let oldMsgIdx = isMappable[idx] ? chatMessageIndex(forTimelineIndex: idx) : nil

            currentItems[idx] = item
            let newMsg = TimelineService.mapTimelineItem(item)
            isMappable[idx] = newMsg != nil

            switch (oldMsgIdx, newMsg) {
            case let (oldIdx?, msg?):
                if chronMessages[oldIdx] != msg {
                    chronMessages[oldIdx] = msg
                    updatedIds.insert(msg.id)
                }
            case let (nil, msg?):
                let msgIdx = chatMessageIndex(forTimelineIndex: idx)
                chronMessages.insert(msg, at: msgIdx)
            case let (oldIdx?, nil):
                chronMessages.remove(at: oldIdx)
            case (nil, nil):
                break
            }

        case .remove(let index):
            let idx = Int(index)
            guard idx < currentItems.count else { return }
            if isMappable[idx] {
                let msgIdx = chatMessageIndex(forTimelineIndex: idx)
                chronMessages.remove(at: msgIdx)
            }
            currentItems.remove(at: idx)
            isMappable.remove(at: idx)

        case .popBack:
            guard !currentItems.isEmpty else { return }
            if isMappable.last == true {
                chronMessages.removeLast()
            }
            currentItems.removeLast()
            isMappable.removeLast()

        case .popFront:
            guard !currentItems.isEmpty else { return }
            if isMappable.first == true {
                chronMessages.removeFirst()
            }
            currentItems.removeFirst()
            isMappable.removeFirst()

        case .reset(let items):
            currentItems = items
            rebuildChronMessages()

        case .truncate(let length):
            currentItems = Array(currentItems.prefix(Int(length)))
            rebuildChronMessages()

        case .clear:
            currentItems = []
            chronMessages = []
            isMappable = []
        }
    }

    // MARK: - Helpers

    private func chatMessageIndex(forTimelineIndex timelineIndex: Int) -> Int {
        var count = 0
        for i in 0..<timelineIndex {
            if isMappable[i] { count += 1 }
        }
        return count
    }

    private func rebuildChronMessages() {
        let mapped = currentItems.map { TimelineService.mapTimelineItem($0) }
        isMappable = mapped.map { $0 != nil }
        chronMessages = mapped.compactMap { $0 }
    }
}
