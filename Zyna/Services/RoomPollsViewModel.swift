//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import GRDB

/// UI-independent state for the polls tab. Only published values live on main;
/// the catalog handles database reads, decoding, and pending-state projection.
@MainActor
final class RoomPollsViewModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, more, exhausted, failed(String)
    }

    @Published private(set) var items: [RoomPollItem] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var pendingDecryptionCount = 0
    @Published private(set) var openingEventId: String?
    @Published private(set) var failedOpeningEventId: String?
    private var openingTask: Task<Void, Never>?
    private var openingRequest = UUID()
    private let catalog: RoomPollCatalog
    private let source: RoomPollHistorySource
    private let pageSize: Int
    private let fillBudget: TimeInterval
    private let settleQuiet: TimeInterval
    private let isCurrentSession: () -> Bool
    private var limit: Int
    private var observation: AnyDatabaseCancellable?
    private var task: Task<Void, Never>?
    private var active = false
    private var stopped = false
    private var started = false
    private var sourceStarted = false
    private var hasMoreCached = false
    private var reachedStart = false
    private var previousReachedStart = false
    private var generation = 0
    private var rowCount = 0
    private var bottomVisible = false
    private var sourceError: String?
    #if DEBUG
    private var hasTracedSnapshot = false

    func traceRowAppearance(_ item: RoomPollItem) {
        PollCacheDiagnostics.log("row-appear \(catalog.diagnosticContext) event=\(PollCacheDiagnostics.key(item.eventId)) ended=\(item.snapshot.hasEnded)")
    }
    #endif
    private var fillState: State = .idle {
        didSet { updateState() }
    }

    init(catalog: RoomPollCatalog, source: RoomPollHistorySource, pageSize: Int = 30,
         fillBudget: TimeInterval = 2.5, settleQuiet: TimeInterval = 0.5,
         isCurrentSession: @escaping () -> Bool = { true }) {
        self.catalog = catalog
        self.source = source
        self.pageSize = pageSize
        self.limit = pageSize
        self.fillBudget = fillBudget
        self.settleQuiet = settleQuiet
        self.isCurrentSession = isCurrentSession
    }

    deinit { task?.cancel(); openingTask?.cancel(); observation?.cancel() }

    func openPoll(_ eventId: String,
                  prepare: @escaping @MainActor (String) async throws -> PreparedPollNavigation) {
        guard active, !stopped, isCurrentSession() else { return }
        cancelOpening()
        let request = openingRequest
        openingEventId = eventId
        openingTask = Task { [weak self] in
            do {
                let prepared = try await prepare(eventId)
                try Task.checkCancellation()
                guard let self else { return }
                guard self.canOpen(request) else {
                    self.finishOpening(request, failedEventId: nil)
                    return
                }
                guard prepared.open() else { throw PollNavigationError.unavailable }
                self.finishOpening(request, failedEventId: nil)
            } catch is CancellationError {
                self?.finishOpening(request, failedEventId: nil)
            } catch {
                self?.finishOpening(request, failedEventId: eventId)
            }
        }
    }

    func cancelOpening() {
        openingRequest = UUID()
        openingTask?.cancel()
        openingTask = nil
        openingEventId = nil
        failedOpeningEventId = nil
    }

    private func canOpen(_ request: UUID) -> Bool {
        openingRequest == request && active && !stopped && isCurrentSession()
    }

    private func finishOpening(_ request: UUID, failedEventId: String?) {
        guard openingRequest == request else { return }
        openingTask = nil
        openingEventId = nil
        failedOpeningEventId = canOpen(request) ? failedEventId : nil
    }

    func activate() {
        #if DEBUG
        PollCacheDiagnostics.log("activate \(catalog.diagnosticContext) stopped=\(stopped) sessionCurrent=\(isCurrentSession()) started=\(started)")
        #endif
        guard !stopped, isCurrentSession() else { return }
        active = true
        if !started {
            started = true
            source.onChange = { [weak self] snapshot in
                guard let self, !self.stopped, self.isCurrentSession() else { return }
                self.generation = snapshot.generation
                self.rowCount = snapshot.rowCount
                if self.pendingDecryptionCount != snapshot.pendingCount {
                    self.pendingDecryptionCount = snapshot.pendingCount
                }
                self.sourceError = snapshot.error
                #if DEBUG
                PollCacheDiagnostics.log("sdk-update \(self.catalog.diagnosticContext) generation=\(snapshot.generation) rows=\(snapshot.rowCount) pendingKeys=\(snapshot.pendingCount) writeError=\(snapshot.error != nil)")
                #endif
                self.updateState()
            }
            observe()
            loadMore()
        } else {
            loadMoreAtBottom()
        }
    }

    func deactivate() {
        active = false
        cancelOpening()
        #if DEBUG
        PollCacheDiagnostics.log("deactivate \(catalog.diagnosticContext)")
        #endif
    }

    func loadMore() {
        guard active, !stopped, task == nil, isCurrentSession() else { return }
        guard state != .exhausted || hasMoreCached else { return }
        if state == .more, hasMoreCached || items.count >= limit {
            limit += pageSize
            observe()
        }
        fillState = .loading
        task = Task { [weak self] in await self?.fill() }
    }

    /// Auto-load only when a full page was found. Sparse history requires an
    /// explicit button after each budget, even when late diffs keep arriving.
    func reachedBottom() {
        bottomVisible = true
        loadMoreAtBottom()
    }

    func leftBottom() { bottomVisible = false }

    private func loadMoreAtBottom() {
        guard bottomVisible else { return }
        guard items.count >= limit, state == .more else { return }
        loadMore()
    }

    func retryDecryption() { if !stopped, isCurrentSession() { source.retryDecryption() } }

    func stop() {
        #if DEBUG
        PollCacheDiagnostics.log("stop \(catalog.diagnosticContext) visibleCount=\(items.count)")
        #endif
        stopped = true
        active = false
        cancelOpening()
        task?.cancel()
        task = nil
        observation?.cancel()
        observation = nil
        source.onChange = nil
        source.stop()
    }

    private func observe() {
        observation?.cancel()
        let requestedLimit = limit
        observation = catalog.observe(limit: limit + 1, onError: { [weak self] error in
            guard let self, !self.stopped, self.limit == requestedLimit, self.isCurrentSession() else { return }
            #if DEBUG
            PollCacheDiagnostics.log("observe-error \(self.catalog.diagnosticContext) error=\(PollCacheDiagnostics.error(error))")
            #endif
            self.fillState = .failed(error.localizedDescription)
        }, onChange: { [weak self] items in
            guard let self, !self.stopped, self.limit == requestedLimit, self.isCurrentSession() else { return }
            self.update(items, origin: "observation")
        })
    }

    private func update(_ values: [RoomPollItem], origin: String) {
        #if DEBUG
        if PollCacheDiagnostics.isEnabled, !hasTracedSnapshot || items != Array(values.prefix(limit)) {
            hasTracedSnapshot = true
            PollCacheDiagnostics.log("publish \(catalog.diagnosticContext) origin=\(origin) previous=\(items.count) limit=\(limit) sourceStarted=\(sourceStarted) \(PollCacheDiagnostics.items(values))")
        }
        #endif
        hasMoreCached = values.count > limit
        items = Array(values.prefix(limit))
        if reachedStart, fillState == .more || fillState == .exhausted {
            fillState = hasMoreCached ? .more : .exhausted
        }
    }

    private func updateState() {
        // A successful read or completed pagination cannot acknowledge a
        // failed write. Only the history source can report its recovery.
        let next = sourceError.map(State.failed) ?? fillState
        if state != next {
            #if DEBUG
            let phase: String
            switch next {
            case .idle: phase = "idle"
            case .loading: phase = "loading"
            case .more: phase = "more"
            case .exhausted: phase = "exhausted"
            case .failed: phase = "failed"
            }
            PollCacheDiagnostics.log("state \(catalog.diagnosticContext) state=\(phase) visibleCount=\(items.count)")
            #endif
            state = next
        }
    }

    private func refresh() async throws {
        let values = try await catalog.page(limit: limit + 1)
        try checkSession()
        update(values, origin: "page")
    }

    private func checkSession() throws {
        guard !stopped, !Task.isCancelled, isCurrentSession() else { throw CancellationError() }
    }

    private func fill() async {
        defer { task = nil }
        do {
            try await refresh()
            if !sourceStarted {
                try checkSession()
                #if DEBUG
                PollCacheDiagnostics.log("sdk-start-begin \(catalog.diagnosticContext) cachedCount=\(items.count)")
                #endif
                try await source.start()
                try checkSession()
                sourceStarted = true
                #if DEBUG
                PollCacheDiagnostics.log("sdk-start-end \(catalog.diagnosticContext)")
                #endif
            }
            let began = ProcessInfo.processInfo.systemUptime
            var batches = 0
            // One discovery batch even with a warm catalog, then bounded work.
            while active, !reachedStart, batches < 100 {
                try checkSession()
                if batches > 0, !previousReachedStart,
                   (items.count >= limit || ProcessInfo.processInfo.systemUptime - began >= fillBudget) { break }
                let before = rowCount
                #if DEBUG
                let batchStart = ProcessInfo.processInfo.systemUptime
                PollCacheDiagnostics.log("sdk-page-begin \(catalog.diagnosticContext) batch=\(batches + 1)")
                #endif
                let end = try await source.loadMore()
                #if DEBUG
                PollCacheDiagnostics.log("sdk-page-end \(catalog.diagnosticContext) reachedStart=\(end) ms=\(Int((ProcessInfo.processInfo.systemUptime - batchStart) * 1000))")
                #endif
                try checkSession()
                try await refresh()
                reachedStart = end && previousReachedStart && rowCount == before
                previousReachedStart = end
                batches += 1
            }
            // Listener batches may trail the SDK's pagination reply. This is a
            // bounded quiet window, not proof that missing keys will arrive.
            let settleStart = ProcessInfo.processInfo.systemUptime
            var quietSince = settleStart
            var lastGeneration = generation
            while ProcessInfo.processInfo.systemUptime - quietSince < settleQuiet,
                  ProcessInfo.processInfo.systemUptime - settleStart < 3 {
                try await Task.sleep(for: .milliseconds(50))
                try checkSession()
                if generation != lastGeneration {
                    lastGeneration = generation
                    quietSince = ProcessInfo.processInfo.systemUptime
                }
            }
            try await source.synchronize()
            try await refresh()
            fillState = reachedStart && !hasMoreCached ? .exhausted : .more
        } catch is CancellationError {
            if !stopped { fillState = .idle }
        } catch {
            guard !stopped, isCurrentSession() else { return }
            #if DEBUG
            PollCacheDiagnostics.log("fill-error \(catalog.diagnosticContext) error=\(PollCacheDiagnostics.error(error))")
            #endif
            fillState = sourceError == nil ? .failed(error.localizedDescription)
                : (reachedStart && !hasMoreCached ? .exhausted : .more)
        }
    }
}
