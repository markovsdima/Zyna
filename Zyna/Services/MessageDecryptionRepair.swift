//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// One serial inspector per open chat, with a durable, bounded work queue.
/// The task captures dependencies, never the view model or a global account.
final class MessageDecryptionRepair: @unchecked Sendable {
    typealias Inspect = @Sendable (String) async throws -> RoomTimelineEventInspection
    private let continuation: AsyncStream<Void>.Continuation
    private let task: Task<Void, Never>
    private let stopped: Atomic<Bool>
    private let focus = Atomic<MessageDecryptionRepairStore.Focus?>(nil)
    private let retryRequested = Atomic(false)

    init(roomID: String, database: AccountDatabase, historyRevision: TimelineHistoryRevision,
         writeQueue: DispatchQueue = DispatchQueue(label: "com.zyna.decryption-repair-write", qos: .utility),
         inspect: @escaping Inspect,
         projectionSDK: MessageProjectionRecovery.SDK? = nil,
         didChange: @escaping @MainActor @Sendable (TimelineFlushSummary) -> Void) {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let stopped = Atomic(false)
        self.stopped = stopped
        continuation = stream.continuation
        let focus = self.focus
        let retryRequested = self.retryRequested
        #if DEBUG
        let trace = HistoryPerformanceTrace.capture(database: database)
        #endif
        task = Task.detached(priority: .utility) {
            let log = ScopedLog(.messageDiagnostics, prefix: "[MessageRepair]")
            var timer: Task<Void, Never>?
            var projectionRecovery = MessageProjectionRecovery()
            #if DEBUG
            let unknownLog = ScopedLog(.messageDiagnostics, prefix: "[HistoryUnknown]")
            var unknownDiagnostics = MessageUnknownDiagnostics()
            #endif
            defer { timer?.cancel(); stream.continuation.finish() }
            for await _ in stream.stream {
                #if DEBUG
                trace?.count(.repairWake)
                #endif
                timer?.cancel()
                guard !Task.isCancelled, database.isActive else { return }
                do {
                    while !Task.isCancelled, database.isActive {
                        if retryRequested.tryToClearFlag() {
                            projectionRecovery.retryManually()
                            try await database.write { db in
                                guard !stopped.wrappedValue else { throw CancellationError() }
                                try MessageDecryptionRepairStore.retryPage(in: db, roomID: roomID, focus: focus.wrappedValue)
                            }
                        }
                        if let projectionSDK {
                            try await projectionRecovery.run(roomID: roomID, database: database, sdk: projectionSDK)
                        }
                        let candidates = try await database.read { db in
                            try MessageDecryptionRepairStore.candidates(in: db, roomID: roomID,
                                now: Date().timeIntervalSince1970, focus: focus.wrappedValue)
                        }
                        if candidates.isEmpty { break }
                        var inspected = 0
                        var changed = 0
                        var outcomes: [RoomTimelineEventDisposition: Int] = [:]
                        var lookupFailures = 0
                        for candidate in candidates {
                            try Task.checkCancellation()
                            guard database.isActive, let eventID = candidate.message.eventId else { return }
                            let result: RoomTimelineEventInspection?
                            #if DEBUG
                            let operation = trace?.begin(.inspect)
                            #endif
                            do { result = try await inspect(eventID) }
                            catch is CancellationError { return }
                            catch {
                                result = nil
                                #if DEBUG
                                operation?.finish(failed: true)
                                trace?.count(.inspectError)
                                #endif
                            }
                            #if DEBUG
                            operation?.finish()
                            switch result?.disposition {
                            case .hidden: trace?.count(.hidden)
                            case .visible: trace?.count(.visible)
                            case .unableToDecrypt: trace?.count(.utd)
                            case .indeterminate: trace?.count(.unknown)
                            case nil: break
                            }
                            if let trace, let result {
                                if let count = MessageDiagnostics.repairContentCount(result) { trace.count(count) }
                                if candidate.message.isLegacyDecryptionCandidate { trace.count(.inspectLegacy) }
                            }
                            if unknownLog.isEnabled, let result,
                               let detail = unknownDiagnostics.sample(result, attempt: candidate.attemptCount + 1) {
                                unknownLog(detail)
                            }
                            #endif
                            try Task.checkCancellation()
                            if let result { outcomes[result.disposition, default: 0] += 1 }
                            else { lookupFailures += 1 }
                            let didWrite = try await Self.persist(result, candidate: candidate,
                                database: database, historyRevision: historyRevision, writeQueue: writeQueue,
                                stopped: stopped, didChange: didChange)
                            inspected += 1
                            if didWrite { changed += 1 }
                            #if DEBUG
                            if didWrite { trace?.count(.repairChanges) }
                            let pause = trace?.begin(.repairPause)
                            defer { pause?.finish() }
                            #endif
                            // Bound network pressure and yield between small DB writes.
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        #if DEBUG
                        if !HistoryPerformanceTrace.enabled {
                            log("batch inspected=\(inspected) changed=\(changed) hidden=\(outcomes[.hidden, default: 0]) visible=\(outcomes[.visible, default: 0]) utd=\(outcomes[.unableToDecrypt, default: 0]) unknown=\(outcomes[.indeterminate, default: 0]) errors=\(lookupFailures)")
                        }
                        #endif
                    }
                } catch is CancellationError { return }
                catch AccountDatabase.AccessError.retired { return }
                catch { log("database access failed; deferred retry") }
                // Diffs wake the worker immediately; this tick also retries
                // candidates when keys recover without a timeline diff.
                timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(15))
                        stream.continuation.yield()
                    } catch { }
                }
            }
        }
        continuation.yield()
    }

    func wake() { continuation.yield() }

    func prioritize(_ value: MessageDecryptionRepairStore.Focus) {
        focus.wrappedValue = value
        wake()
    }

    func retry() { retryRequested.wrappedValue = true; wake() }

    func stop() {
        stopped.wrappedValue = true
        task.cancel()
        continuation.finish()
    }

    func waitUntilStopped() async { await task.value }

    private static func persist(_ result: RoomTimelineEventInspection?,
        candidate: MessageDecryptionRepairStore.Candidate, database: AccountDatabase,
        historyRevision: TimelineHistoryRevision, writeQueue: DispatchQueue, stopped: Atomic<Bool>,
        didChange: @escaping @MainActor @Sendable (TimelineFlushSummary) -> Void
    ) async throws -> Bool {
        #if DEBUG
        let operation = HistoryPerformanceTrace.capture(database: database)?.begin(.repairQueue)
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            // Share the batcher's serial writer and main notification order.
            // A later live flush must not claim an unreported repair revision.
            writeQueue.async {
                #if DEBUG
                operation?.move(to: .repairWrite)
                defer { operation?.finish() }
                #endif
                do {
                    var summary = TimelineFlushSummary(includesUnreportedHistory: true)
                    let changed = try database.write { db in
                        // Dispatch closures don't inherit task cancellation.
                        guard !stopped.wrappedValue else { throw CancellationError() }
                        guard database.isActive else { throw AccountDatabase.AccessError.retired }
                        let impact = try MessageDecryptionRepairStore.applyWithImpact(result, to: candidate,
                            in: db, now: Date().timeIntervalSince1970)
                        let changed = impact != .none
                        summary.onlyUnadmittedChanges = impact == .unadmittedRows
                        if impact == .presentation, let eventID = candidate.message.eventId {
                            summary.recoveredEventIDs.insert(eventID)
                        }
                        if changed { historyRevision.observeCommit(summary, in: db) }
                        return changed
                    }
                    if changed {
                        summary.committedHistoryRevision = historyRevision.current
                        let committed = summary
                        DispatchQueue.main.async {
                            guard !stopped.wrappedValue, database.isActive else { return }
                            didChange(committed)
                        }
                    }
                    continuation.resume(returning: changed)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    deinit { stop() }
}
