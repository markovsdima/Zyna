//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import GRDB

/// One opt-in, suspended catalog read across a real account teardown.
/// Holds no thread, transaction, or lifecycle lock while waiting for sign-in.
/// A closed connection is inspected without SQL; the dangerous read is never
/// executed. This diagnoses a retained reference, not a production safety fix.
final class DatabaseHandoffProbe: @unchecked Sendable {
    static let shared = DatabaseHandoffProbe()

    enum Phase: String {
        case idle, armed, held, waitingForSignIn, inspecting, finished
    }

    struct Result: Equatable {
        let oldConnectionClosed: Bool
        let newConnectionDistinct: Bool
        let sameAccount: Bool
        let taskCancelled: Bool
    }

    struct Snapshot {
        let phase: Phase
        let report: String
        let result: Result?

        var isActive: Bool { phase != .idle && phase != .finished }
        var title: String {
            switch phase {
            case .idle: return "Off"
            case .armed: return "Armed — open Polls"
            case .held: return "Read held — sign out"
            case .waitingForSignIn: return "Waiting for sign-in"
            case .inspecting: return "Inspecting"
            case .finished: return result == nil ? "Finished — see report" : "Captured — see report"
            }
        }
    }

    enum ProbeError: Error { case interceptedStaleRead }

    private struct Replacement: Sendable {
        let distinct: Bool
        let sameAccount: Bool
    }

    private enum Release: Sendable {
        case bypass, cancelled
        case inspect(Replacement)
    }

    private struct State {
        var phase: Phase = .idle
        var run = ""
        var database: AccountDatabase?
        var accountTag = ""
        var continuation: CheckedContinuation<Release, Never>?
        var events: [String] = []
        var result: Result?

        mutating func record(_ detail: String) -> String {
            let line = "handoff-\(detail) probe=\(run)"
            events.append(line)
            return line
        }
    }

    private let state = Atomic(State())
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { PollCacheDiagnostics.log($0) }) {
        self.log = log
    }

    var snapshot: Snapshot {
        state.withValue { Snapshot(phase: $0.phase, report: $0.events.joined(separator: "\n"), result: $0.result) }
    }

    @discardableResult
    func arm(database: AccountDatabase, accountID: String) -> Bool {
        let line = state.withValue { state -> String? in
            guard state.phase == .idle || state.phase == .finished else { return nil }
            state = State()
            state.run = String(UUID().uuidString.prefix(8))
            state.database = database
            state.accountTag = PollCacheDiagnostics.key(accountID)
            state.phase = .armed
            return state.record("armed db=\(PollCacheDiagnostics.databaseKey(database.path))")
        }
        if let line { log(line) }
        return line != nil
    }

    /// Only the first page on the explicitly armed queue is held. Cancellation
    /// of its UI task intentionally does not release this diagnostic gate: it
    /// simulates a callback that outlives cancellation. Cancel Test does release
    /// it, by throwing instead of proceeding to SQLite.
    func beforeRead(database: AccountDatabase) async throws {
        let run = state.withValue { state -> String? in
            guard state.phase == .armed, state.database === database else { return nil }
            return state.run
        }
        guard let run else { return }

        let release: Release = await withCheckedContinuation { continuation in
            let line = state.withValue { state -> String? in
                guard state.run == run, state.phase == .armed, state.database === database else { return nil }
                state.continuation = continuation
                state.phase = .held
                return state.record("held source=poll-catalog.page")
            }
            if let line { log(line) } else { continuation.resume(returning: .bypass) }
        }
        let replacement: Replacement
        switch release {
        case .bypass: return
        case .cancelled: throw CancellationError()
        case .inspect(let value): replacement = value
        }

        let taskCancelled = Task.isCancelled
        // The owner records physical close only after GRDB finishes. This
        // inspection does not access SQLite or depend on task cancellation.
        let closed = database.isClosed
        let result = Result(oldConnectionClosed: closed, newConnectionDistinct: replacement.distinct,
                            sameAccount: replacement.sameAccount, taskCancelled: taskCancelled)
        let line = state.withValue { state -> String? in
            guard state.run == run, state.phase == .inspecting else { return nil }
            state.result = result
            state.phase = .finished
            return state.record("result oldClosed=\(closed) newDistinct=\(replacement.distinct) sameAccount=\(replacement.sameAccount) taskCancelled=\(taskCancelled) sqlAttempted=false")
        }
        if let line { log(line) }
        // Always terminate the selected old operation. No stale page can
        // reach SQLite or publish data into the new session through this probe.
        throw ProbeError.interceptedStaleRead
    }

    /// Called after successful close, on the lifecycle worker. Identity uses
    /// the queue object, not its path (which is reused on same-account login).
    func didClose(_ database: AccountDatabase) {
        let line = state.withValue { state -> String? in
            guard state.database === database else { return nil }
            switch state.phase {
            case .armed:
                state.phase = .finished
                state.database = nil
                return state.record("not-captured reason=no-poll-page-before-close")
            case .held:
                state.phase = .waitingForSignIn
                return state.record("old-closed waitingFor=authenticated-database")
            default:
                return nil
            }
        }
        if let line { log(line) }
    }

    /// Anonymous storage during logout is deliberately not the release point.
    func didActivate(_ database: AccountDatabase, userID: String?) {
        guard let userID else { return }
        let pending = state.withValue { state -> (CheckedContinuation<Release, Never>, Replacement, String)? in
            guard state.phase == .waitingForSignIn, let old = state.database,
                  let continuation = state.continuation else { return nil }
            let replacement = Replacement(distinct: old !== database,
                                          sameAccount: state.accountTag == PollCacheDiagnostics.key(userID))
            state.phase = .inspecting
            state.continuation = nil
            state.database = nil
            return (continuation, replacement,
                    state.record("resume newDb=\(PollCacheDiagnostics.databaseKey(database.path))"))
        }
        if let (continuation, replacement, line) = pending {
            log(line)
            continuation.resume(returning: .inspect(replacement))
        }
    }

    func cancel() {
        let pending = state.withValue { state -> (CheckedContinuation<Release, Never>?, String)? in
            guard state.phase != .idle, state.phase != .finished else { return nil }
            let continuation = state.continuation
            state.continuation = nil
            state.database = nil
            state.phase = .finished
            return (continuation, state.record("cancelled"))
        }
        if let (continuation, line) = pending {
            log(line)
            continuation?.resume(returning: .cancelled)
        }
    }
}
#endif
