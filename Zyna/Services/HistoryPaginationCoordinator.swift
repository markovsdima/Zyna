//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum HistoryPaginationResult: Equatable, Sendable {
    case page(reachedStart: Bool)
    case unavailable
    case failed
    case cancelled
}

/// Demand and background pagination share the SDK call and writer drain.
/// Cancelling one waiter does not cancel a page another waiter still needs.
final class HistoryPaginationCoordinator {
    private var inFlight: Task<HistoryPaginationResult, Never>?
    private var stopped = false

    @MainActor var isLoading: Bool { inFlight != nil }

    @MainActor
    func load(
        operation: @escaping @Sendable () async -> HistoryPaginationResult,
        didFinish: @escaping @MainActor (HistoryPaginationResult) -> Void
    ) async -> HistoryPaginationResult {
        guard !stopped, !Task.isCancelled else { return .cancelled }
        let task: Task<HistoryPaginationResult, Never>
        if let inFlight {
            task = inFlight
        } else {
            task = Task { @MainActor [weak self] in
                let result = await operation()
                guard let self, !self.stopped, !Task.isCancelled else { return .cancelled }
                self.inFlight = nil
                didFinish(result)
                return result
            }
            inFlight = task
        }
        let result = await task.value
        return Task.isCancelled ? .cancelled : result
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = true
        inFlight?.cancel()
        inFlight = nil
    }

    deinit { inFlight?.cancel() }
}
