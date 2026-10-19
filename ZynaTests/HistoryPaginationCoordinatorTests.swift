//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Testing
@testable import Zyna

@Suite("Shared history pagination")
@MainActor
struct HistoryPaginationCoordinatorTests {
    @Test("Demand joins background through the writer drain, including an SDK end result")
    func sharedPage() async throws {
        let coordinator = HistoryPaginationCoordinator()
        let sdk = HeldHistoryStep()
        let writer = HeldHistoryStep()
        var results: [HistoryPaginationResult] = []
        let first = Task {
            await coordinator.load(operation: {
                let result = await sdk.hold()
                _ = await writer.hold()
                return result
            }, didFinish: { results.append($0) })
        }
        try await waitFor(sdk)
        await sdk.release(.page(reachedStart: true))
        try await waitFor(writer)
        var joinedEntered = false
        let joined = Task {
            joinedEntered = true
            return await coordinator.load(operation: {
                Issue.record("A demand waiter started a second SDK page")
                return .failed
            }, didFinish: { _ in Issue.record("A joined waiter completed the page twice") })
        }
        try await waitUntil { joinedEntered }
        #expect(coordinator.isLoading)
        #expect(results.isEmpty)
        await writer.release(.page(reachedStart: false))
        #expect(await first.value == .page(reachedStart: true))
        #expect(await joined.value == .page(reachedStart: true))
        #expect(results == [.page(reachedStart: true)])
        #expect(!coordinator.isLoading)
        #expect(await sdk.calls == 1)
    }

    @Test("Cancelling a background waiter preserves the demand waiter's shared page")
    func cancelWaiter() async throws {
        let coordinator = HistoryPaginationCoordinator()
        let sdk = HeldHistoryStep()
        var completions = 0
        let background = Task {
            await coordinator.load(operation: { await sdk.hold() }, didFinish: { _ in completions += 1 })
        }
        try await waitFor(sdk)
        var demandEntered = false
        let demand = Task {
            demandEntered = true
            return await coordinator.load(operation: {
                Issue.record("Cancelled waiter discarded the shared request")
                return .failed
            }, didFinish: { _ in Issue.record("Double completion") })
        }
        try await waitUntil { demandEntered }
        background.cancel()
        await sdk.release(.page(reachedStart: false))
        #expect(await background.value == .cancelled)
        #expect(await demand.value == .page(reachedStart: false))
        #expect(completions == 1)
    }

    @Test("Closing or changing accounts ignores a late SDK result and rejects further pages")
    func stopped() async throws {
        let old = HistoryPaginationCoordinator()
        let next = HistoryPaginationCoordinator()
        let sdk = HeldHistoryStep()
        let request = Task {
            await old.load(operation: { await sdk.hold() }, didFinish: { _ in
                Issue.record("Stopped chat consumed an old account result")
            })
        }
        try await waitFor(sdk)
        old.stop()
        await sdk.release(.page(reachedStart: true))
        #expect(await request.value == .cancelled)
        let rejected = await old.load(operation: {
            Issue.record("Stopped chat started SDK work")
            return .failed
        }, didFinish: { _ in Issue.record("Stopped chat notified UI") })
        #expect(rejected == .cancelled)
        let fresh = await next.load(operation: { .page(reachedStart: false) }, didFinish: { _ in })
        #expect(fresh == .page(reachedStart: false))
    }

    @Test("Failures remain retryable, and service-only pages do not imply exhaustion")
    func retryAndFilteredPages() async {
        let coordinator = HistoryPaginationCoordinator()
        var results: [HistoryPaginationResult] = []
        for expected in [HistoryPaginationResult.failed, .unavailable]
            + Array(repeating: .page(reachedStart: false), count: 5) + [.page(reachedStart: true)] {
            let result = await coordinator.load(operation: { expected }, didFinish: { results.append($0) })
            #expect(result == expected)
            #expect(!coordinator.isLoading)
        }
        #expect(results.count == 8)
        #expect(results.last == .page(reachedStart: true))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(predicate())
    }

    private func waitFor(_ step: HeldHistoryStep) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await step.waiting), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await step.waiting)
    }
}

private actor HeldHistoryStep {
    private var continuation: CheckedContinuation<HistoryPaginationResult, Never>?
    private(set) var calls = 0
    var waiting: Bool { continuation != nil }
    func hold() async -> HistoryPaginationResult {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ result: HistoryPaginationResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
