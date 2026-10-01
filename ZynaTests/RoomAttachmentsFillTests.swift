//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import Foundation
import GRDB
import MatrixRustSDK
@testable import Zyna

/// Drives the fill state machine without an SDK: every `loadMore` takes a
/// few milliseconds and publishes one snapshot.
private final class FakeAttachmentSource: AttachmentSource, @unchecked Sendable {
    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)?
    var onPaginationStatus: ((PaginationStatus) -> Void)?
    var onAttachmentsDiscovered: (([StoredRoomAttachment]) -> Void)?
    var onAttachmentsInvalidated: (([String]) -> Void)?

    private(set) var loadMoreCalls = 0
    var batchDelayMs = 20
    /// `loadMore` reports the room start from this call on.
    var reachStartAfter = Int.max
    private var generation = 0
    private var rows = 0
    var mediaCount = 0
    var voiceCount = 0
    var fileCount = 0
    var emitSnapshotOnStart = false
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func start() async throws {
        startCalls += 1
        if emitSnapshotOnStart { emitSnapshot() }
    }
    func stop() { stopCalls += 1 }
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
            generation: generation, rowCount: rows, media: [], voice: [], files: [],
            mediaCount: mediaCount, voiceCount: voiceCount, fileCount: fileCount,
            pendingCount: 0, pendingSessionIds: []
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

    @Test("Paged media readiness is independent of optimistic and durable file snapshots", arguments: [0, 300])
    func independentCounts(mediaCount: Int) async throws {
        let database = try TimelineWriteFixture.database()
        let gate = DispatchSemaphore(value: 0)
        let entered = Atomic(false)
        let blocked = Task.detached {
            try await database.read { _ in
                entered.wrappedValue = true
                _ = gate.wait(timeout: .now() + 8)
            }
        }
        defer { gate.signal() }
        try #require(await waitUntil { entered.wrappedValue })
        let source = FakeAttachmentSource()
        source.emitSnapshotOnStart = true; source.mediaCount = 100; source.fileCount = 77
        let model = RoomAttachmentsViewModel(roomId: TimelineWriteFixture.roomID, source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128,
            attachmentIndex: RoomAttachmentIndex(roomId: TimelineWriteFixture.roomID, dbQueue: database), usesPagedMedia: true)
        defer { model.stop() }
        model.tab = .polls
        await model.start()
        model.updatePagedMediaCount(mediaCount)
        #expect(model.currentCount(for: .files) == 77)
        var message = TimelineWriteFixture.message(1)
        message.contentType = "file"; message.contentMediaJSON = "{\"url\":\"mxc://example.org/file\"}"
        let record = try #require(StoredRoomAttachment(storedMessage: message))
        source.onAttachmentsDiscovered?([record])
        try #require(await waitUntil { !model.files.isEmpty })
        #expect(model.currentCount(for: .media) == mediaCount)
        #expect(model.currentCount(for: .files) == 77)
        // The durable empty snapshot makes file readiness authoritative.
        gate.signal()
        try await blocked.value
        try #require(await waitUntil { model.currentCount(for: .files) == 1 })
        #expect(model.currentCount(for: .media) == mediaCount)
    }

    @Test("The research presentation borrows discovery and releases its full media projection")
    func sharedDiscovery() async throws {
        let database = try TimelineWriteFixture.database()
        var message = TimelineWriteFixture.message(1)
        message.contentType = "image"; message.contentMediaJSON = "{\"url\":\"mxc://example.org/photo\"}"
        let record = try #require(StoredRoomAttachment(storedMessage: message))
        try await database.write { try record.save($0) }
        let source = FakeAttachmentSource()
        source.emitSnapshotOnStart = true
        let model = RoomAttachmentsViewModel(roomId: TimelineWriteFixture.roomID, source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128,
            attachmentIndex: RoomAttachmentIndex(roomId: TimelineWriteFixture.roomID, dbQueue: database), usesPagedMedia: true)
        defer { model.stop() }
        model.tab = .polls
        await model.start()
        try #require(await waitUntil { !model.isInitialLoading })
        #expect(model.media.isEmpty)
        model.setLegacyMediaPresentation(true)
        await model.start()
        try #require(await waitUntil { model.media.first?.items.first?.id == record.eventId })
        model.setLegacyMediaPresentation(false)
        try #require(await waitUntil { model.media.isEmpty })
        #expect(source.startCalls == 1)
        #expect(source.stopCalls == 0)
    }

    @Test("The shared research screen displays discoveries before persistence and drops visual optimistic rows on return")
    func sharedOptimisticMedia() async throws {
        let database = try TimelineWriteFixture.database()
        let source = FakeAttachmentSource()
        source.emitSnapshotOnStart = true
        let model = RoomAttachmentsViewModel(roomId: TimelineWriteFixture.roomID, source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128,
            attachmentIndex: RoomAttachmentIndex(roomId: TimelineWriteFixture.roomID, dbQueue: database), usesPagedMedia: true)
        defer { model.stop() }
        model.tab = .polls
        await model.start()
        try #require(await waitUntil { !model.isInitialLoading })
        model.setLegacyMediaPresentation(true)
        var message = TimelineWriteFixture.message(1)
        message.contentType = "image"; message.contentMediaJSON = "{\"url\":\"mxc://example.org/photo\"}"
        let photo = try #require(StoredRoomAttachment(storedMessage: message))
        source.onAttachmentsDiscovered?([photo])
        try #require(await waitUntil { model.media.first?.items.first?.id == photo.eventId })
        #expect(try await database.read { try StoredRoomAttachment.fetchCount($0) } == 0)
        model.setLegacyMediaPresentation(false)
        try #require(await waitUntil { model.media.isEmpty })
        // A nonvisual publication acts as a barrier for the late callback.
        message.eventId = "$file"; message.contentType = "file"
        let file = try #require(StoredRoomAttachment(storedMessage: message))
        source.onAttachmentsDiscovered?([photo, file])
        try #require(await waitUntil { model.files.first?.items.first?.id == file.eventId })
        #expect(model.media.isEmpty)
        #expect(source.startCalls == 1)
    }

    @Test("A disappearing presentation does not withdraw the other presentation's pagination demand",
          arguments: [RoomAttachmentsViewModel.Presentation.profile, .research])
    func sharedSentinel(disappearing: RoomAttachmentsViewModel.Presentation) async throws {
        let source = FakeAttachmentSource()
        source.emitSnapshotOnStart = true; source.mediaCount = 100
        let model = makeViewModel(source: source)
        defer { model.stop() }
        await model.start()
        let remaining: RoomAttachmentsViewModel.Presentation = disappearing == .profile ? .research : .profile
        model.sentinelAppeared(from: disappearing)
        model.sentinelAppeared(from: remaining)
        model.sentinelDisappeared(from: disappearing)
        try #require(await waitUntil { !model.isFillActive })
        #expect(model.diagnostics.pendingFillsReplayed == 1)
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

    @Test("Initial pagination uses the loaded timeline until index counts are available",
          arguments: [RoomAttachmentsViewModel.Tab.media, .voice, .files], [true, false])
    func initialTimelinePage(tab: RoomAttachmentsViewModel.Tab, fullPage: Bool) async throws {
        let source = FakeAttachmentSource()
        source.emitSnapshotOnStart = true
        let shortfall = fullPage ? 0 : 1
        source.mediaCount = RoomAttachmentsViewModel.mediaPageSize - shortfall
        source.voiceCount = RoomAttachmentsViewModel.voicePageSize - shortfall
        source.fileCount = RoomAttachmentsViewModel.filesPageSize - shortfall
        let model = makeViewModel(source: source)
        model.tab = tab
        await model.start()
        #expect(!model.isInitialLoading)
        if fullPage {
            #expect(!model.isFillActive)
            #expect(source.loadMoreCalls == 0)
            source.emitSnapshot()
            try await Task.sleep(for: .milliseconds(30))
            #expect(source.loadMoreCalls == 0)
            // A full first page is not evidence that history is exhausted.
            model.loadMoreTapped()
        } else {
            #expect(model.isFillActive)
        }
        #expect(await waitUntil { source.loadMoreCalls > 0 })
        model.stop()
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

    @Test("Retained tabs keep independent sentinels and resume only the visible tab", arguments: [
        RoomAttachmentsViewModel.Tab.voice, .files
    ])
    func retainedSentinels(other: RoomAttachmentsViewModel.Tab) async throws {
        let source = FakeAttachmentSource()
        source.mediaCount = 100
        source.voiceCount = 100
        source.fileCount = 100
        let model = makeViewModel(source: source)
        // Start on Polls so the warm snapshot can arrive without an initial fill.
        model.tab = .polls
        await model.start()
        source.emitSnapshot()
        #expect(await waitUntil { !model.isInitialLoading })
        model.tab = .media
        model.sentinelAppeared(in: .media)
        #expect(await waitUntil { source.loadMoreCalls > 0 })
        model.tab = other
        #expect(await waitUntil { !model.isFillActive })
        let calls = source.loadMoreCalls
        for _ in 0..<3 { source.emitSnapshot() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.loadMoreCalls == calls)

        // The hidden tab's callbacks must not reset the retained Media footer.
        let hiddenTab: RoomAttachmentsViewModel.Tab = other == .files ? .voice : .files
        model.sentinelAppeared(in: hiddenTab)
        model.sentinelDisappeared(in: hiddenTab)
        model.tab = .media
        #expect(await waitUntil { source.loadMoreCalls > calls })
        model.stop()
    }

    @Test("A fill paused by Polls resumes its unfinished target without a new sentinel callback")
    func resumeAfterPolls() async throws {
        let source = FakeAttachmentSource()
        source.mediaCount = 45
        let model = makeViewModel(source: source, budget: 5)
        model.tab = .polls
        await model.start()
        source.emitSnapshot()
        #expect(await waitUntil { !model.isInitialLoading })
        model.tab = .media
        model.loadMoreTapped()
        #expect(await waitUntil { source.loadMoreCalls > 0 })
        model.tab = .polls
        #expect(await waitUntil { !model.isFillActive })
        #expect(model.fillState == .idle)
        #expect(model.diagnostics.fillsEndedByTimeBudget == 0)
        let calls = source.loadMoreCalls
        // Enough for the initial-page check, but short of the interrupted target.
        source.mediaCount = 60
        source.emitSnapshot()
        try await Task.sleep(for: .milliseconds(30))
        model.tab = .media
        #expect(await waitUntil { source.loadMoreCalls > calls })
        source.mediaCount = 90
        source.emitSnapshot()
        #expect(await waitUntil { !model.isFillActive })
        #expect(model.fillState == .idle)
        model.stop()
    }
}
