//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Coalesces SDK and poll notifications while a snapshot is prepared off-main.
/// A superseded snapshot is read again against the latest window, keeping
/// the full flush provenance used by redaction animation eligibility.
final class ChatTimelineRefreshQueue {
    enum Result { case applied, superseded, failed }

    private let perform: (TimelineFlushSummary, @escaping (Result) -> Void) -> Void
    private var pending: TimelineFlushSummary?
    private var isRunning = false
    private var isCancelled = false
    private let scheduleRepair: (@escaping () -> Void) -> Void
    private var repairSequence: UInt64 = 0
    private var scheduledRepair: UInt64?
    private var hasImmediatePending = false

    var hasPending: Bool { pending != nil }
    var isIdle: Bool { !isRunning && pending == nil }

    /// Include notifications received during preparation without consuming
    /// them: their commits may postdate the snapshot and still need a read.
    func summaryForApplying(_ summary: TimelineFlushSummary) -> TimelineFlushSummary {
        dispatchPrecondition(condition: .onQueue(.main))
        return pending.map { summary.merging($0) } ?? summary
    }

    init(scheduleRepair: @escaping (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }, perform: @escaping (TimelineFlushSummary, @escaping (Result) -> Void) -> Void) {
        self.scheduleRepair = scheduleRepair
        self.perform = perform
    }

    func enqueue(_ update: PollStore.RoomUpdate) {
        // Only catalog discovery can cover history absent from the chat's
        // SDK window. Local actions must not suppress a concurrent live deletion.
        enqueue(TimelineFlushSummary(includesUnreportedHistory: update.origin == .catalog,
                                     requiresPresentationRefresh: true))
    }

    func enqueue(_ summary: TimelineFlushSummary) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCancelled else { return }
        pending = pending.map { $0.merging(summary) } ?? summary
        // Live and local actions do not wait for repair's throttle window.
        hasImmediatePending = true
        scheduledRepair = nil
        startNext()
    }

    /// Keep commit provenance immediately, but batch repair-only refreshes.
    /// A fixed deadline cannot be postponed by a continuous repair stream.
    func enqueueRepair(_ summary: TimelineFlushSummary) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCancelled else { return }
        pending = pending.map { $0.merging(summary) } ?? summary
        if hasImmediatePending { startNext(); return }
        guard scheduledRepair == nil else { return }
        repairSequence &+= 1
        let sequence = repairSequence
        scheduledRepair = sequence
        scheduleRepair { [weak self] in
            guard let self, self.scheduledRepair == sequence else { return }
            self.scheduledRepair = nil
            self.startNext()
        }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        isCancelled = true
        pending = nil
        scheduledRepair = nil
        hasImmediatePending = false
    }

    private func startNext() {
        guard !isCancelled, !isRunning, scheduledRepair == nil, let summary = pending else { return }
        let wasImmediate = hasImmediatePending
        pending = nil
        hasImmediatePending = false
        isRunning = true
        perform(summary) { [weak self] result in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self, !self.isCancelled else { return }
            self.isRunning = false
            if case .superseded = result {
                self.pending = self.pending.map { summary.merging($0) } ?? summary
                if wasImmediate {
                    self.hasImmediatePending = true
                    self.scheduledRepair = nil
                }
            }
            if case .failed = result {
                // Keep provenance for the next notification, but don't loop
                // on a persistent database error without a new trigger.
                self.pending = self.pending.map { summary.merging($0) } ?? summary
                return
            }
            self.startNext()
        }
    }
}
