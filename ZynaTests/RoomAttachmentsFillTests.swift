//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import Foundation
import MatrixRustSDK
@testable import Zyna

/// Drives the fill state machine without an SDK: every `loadMore` takes a
/// few milliseconds and publishes one snapshot.
private final class FakeAttachmentSource: AttachmentSource, @unchecked Sendable {
    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)?
    var onPaginationStatus: ((PaginationStatus) -> Void)?

    private(set) var loadMoreCalls = 0
    var batchDelayMs = 20
    /// `loadMore` reports the room start from this call on.
    var reachStartAfter = Int.max
    private var generation = 0
    private var rows = 0

    func start() async throws {}
    func stop() {}
    func retryDecryption(sessionIds: [String]) {}
    func describeTimelineItem(eventId: String) async -> String? { nil }
    func storeRowDescription(uniqueId: String) -> String? { nil }

    func loadMore(numEvents: UInt16) async throws -> Bool {
        loadMoreCalls += 1
        try? await Task.sleep(for: .milliseconds(batchDelayMs))
        let reachedStart = loadMoreCalls >= reachStartAfter
        if !reachedStart {
            rows += 1
        }
        emitSnapshot()
        return reachedStart
    }

    func emitSnapshot() {
        generation += 1
        let snapshot = AttachmentTimelineStore.Snapshot(
            generation: generation, rowCount: rows, media: [], files: [],
            mediaCount: 0, fileCount: 0, pendingCount: 0, pendingSessionIds: []
        )
        let handler = onSnapshot
        Task { @MainActor in
            handler?(snapshot, AttachmentTimelineStore.ApplySummary())
        }
    }
}

@MainActor
@Suite("RoomAttachmentsViewModel fill")
struct RoomAttachmentsFillTests {

    private func makeViewModel(source: FakeAttachmentSource, budget: CFTimeInterval = 0.15) -> RoomAttachmentsViewModel {
        RoomAttachmentsViewModel(
            roomId: "!room:example.org", source: source, filterMode: .sdkOnlyMessage,
            tilePixelSize: 128, fillTimeBudgetSeconds: budget
        )
    }

    private func waitUntil(seconds: Double = 6, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("Snapshots never restart a fill that stopped on its budget")
    func budgetIsFinal() async throws {
        let source = FakeAttachmentSource()
        let viewModel = makeViewModel(source: source)
        await viewModel.start()
        viewModel.sentinelAppeared()

        #expect(await waitUntil { !viewModel.isFillActive && viewModel.fillState == .capped })
        let callsAfterBudget = source.loadMoreCalls
        #expect(callsAfterBudget > 0)

        for _ in 0..<5 {
            source.emitSnapshot()
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(source.loadMoreCalls == callsAfterBudget)
        #expect(!viewModel.isFillActive)

        // An explicit intent re-arms it.
        viewModel.loadMoreTapped()
        #expect(await waitUntil { source.loadMoreCalls > callsAfterBudget })
        viewModel.stop()
    }

    @Test("A tab switch during a fill is replayed once, and stop clears it")
    func tabSwitchReplaysOnce() async throws {
        let source = FakeAttachmentSource()
        let viewModel = makeViewModel(source: source)
        await viewModel.start()
        #expect(viewModel.isFillActive)
        viewModel.tab = .files

        #expect(await waitUntil { !viewModel.isFillActive })
        #expect(viewModel.diagnostics.pendingFillsReplayed == 1)
        #expect(viewModel.diagnostics.fills == 2)

        // Pending intents die with the screen.
        viewModel.loadMoreTapped()
        #expect(viewModel.isFillActive)
        viewModel.tab = .media
        viewModel.stop()
        #expect(!viewModel.isFillActive)
    }

    @Test("Room start needs a confirming call and ends the loop for good")
    func roomStartIsConfirmed() async throws {
        let source = FakeAttachmentSource()
        source.reachStartAfter = 3
        let viewModel = makeViewModel(source: source, budget: 5)
        await viewModel.start()

        #expect(await waitUntil { viewModel.fillState == .exhausted })
        // Calls 1–2 load, call 3 reports the start, call 4 confirms it.
        #expect(source.loadMoreCalls == 4)

        viewModel.sentinelAppeared()
        viewModel.loadMoreTapped()
        try await Task.sleep(for: .milliseconds(150))
        #expect(source.loadMoreCalls == 4)
        viewModel.stop()
    }
}
