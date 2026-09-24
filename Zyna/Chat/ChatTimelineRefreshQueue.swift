//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Coalesces SDK notifications while a snapshot is prepared off-main.
/// A superseded snapshot is read again against the latest window, keeping
/// the full flush provenance used by redaction animation eligibility.
final class ChatTimelineRefreshQueue {
    enum Result { case applied, superseded, failed }

    private let perform: (TimelineFlushSummary, @escaping (Result) -> Void) -> Void
    private var pending: TimelineFlushSummary?
    private var isRunning = false
    private var isCancelled = false

    var hasPending: Bool { pending != nil }

    /// Include notifications received during preparation without consuming
    /// them: their commits may postdate the snapshot and still need a read.
    func summaryForApplying(_ summary: TimelineFlushSummary) -> TimelineFlushSummary {
        dispatchPrecondition(condition: .onQueue(.main))
        return pending.map { summary.merging($0) } ?? summary
    }

    init(perform: @escaping (TimelineFlushSummary, @escaping (Result) -> Void) -> Void) {
        self.perform = perform
    }

    func enqueue(_ summary: TimelineFlushSummary) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCancelled else { return }
        pending = pending.map { $0.merging(summary) } ?? summary
        startNext()
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        isCancelled = true
        pending = nil
    }

    private func startNext() {
        guard !isCancelled, !isRunning, let summary = pending else { return }
        pending = nil
        isRunning = true
        perform(summary) { [weak self] result in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self, !self.isCancelled else { return }
            self.isRunning = false
            if case .superseded = result {
                self.pending = self.pending.map { summary.merging($0) } ?? summary
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
