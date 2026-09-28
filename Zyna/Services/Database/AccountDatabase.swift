//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Owns one connection for one account activation. Retained references never
/// follow the active account. Retirement rejects new work before draining
/// admitted accesses and closing GRDB on the lifecycle worker.
final class AccountDatabase: @unchecked Sendable {
    enum AccessError: Error { case retired }

    private let queue: DatabaseQueue
    private let condition = NSCondition()
    private let closeLock = NSLock()
    private var acceptingAccess = true
    private var closed = false
    private var accesses = 0
    private var observations: [UUID: AnyDatabaseCancellable] = [:]

    /// Transfers ownership. The raw queue must not be used or closed again.
    init(_ queue: DatabaseQueue) { self.queue = queue }

    var path: String { queue.path }

    var isActive: Bool {
        condition.lock()
        defer { condition.unlock() }
        return acceptingAccess
    }

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    private func beginAccess() throws {
        condition.lock()
        defer { condition.unlock() }
        guard acceptingAccess else { throw AccessError.retired }
        accesses += 1
    }

    private func endAccess() {
        condition.lock()
        accesses -= 1
        if accesses == 0 { condition.broadcast() }
        condition.unlock()
    }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try beginAccess()
        defer { endAccess() }
        #if DEBUG
        let trace = HistoryPerformanceTrace.capture(database: self)
        let operation = trace?.begin(.readWait)
        let mainAccess = Thread.isMainThread ? trace?.begin(.mainDB) : nil
        var succeeded = false
        defer {
            operation?.finish(failed: !succeeded)
            mainAccess?.finish(failed: !succeeded)
        }
        let result = try queue.read { db in
            operation?.move(to: .read)
            return try value(db)
        }
        succeeded = true
        return result
        #else
        return try queue.read(value)
        #endif
    }

    func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        try beginAccess()
        defer { endAccess() }
        #if DEBUG
        let trace = HistoryPerformanceTrace.capture(database: self)
        let operation = trace?.begin(.readWait)
        var succeeded = false
        defer {
            operation?.finish(failed: !succeeded)
        }
        let result = try await queue.read { db in
            operation?.move(to: .read)
            return try value(db)
        }
        succeeded = true
        return result
        #else
        return try await queue.read(value)
        #endif
    }

    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try beginAccess()
        defer { endAccess() }
        #if DEBUG
        let trace = HistoryPerformanceTrace.capture(database: self)
        let operation = trace?.begin(.writeWait)
        let mainAccess = Thread.isMainThread ? trace?.begin(.mainDB) : nil
        var succeeded = false
        defer {
            operation?.finish(failed: !succeeded)
            mainAccess?.finish(failed: !succeeded)
        }
        let result = try queue.write { db in
            operation?.move(to: .write)
            return try updates(db)
        }
        succeeded = true
        return result
        #else
        return try queue.write(updates)
        #endif
    }

    func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        try beginAccess()
        defer { endAccess() }
        #if DEBUG
        let trace = HistoryPerformanceTrace.capture(database: self)
        let operation = trace?.begin(.writeWait)
        var succeeded = false
        defer {
            operation?.finish(failed: !succeeded)
        }
        let result = try await queue.write { db in
            operation?.move(to: .write)
            return try updates(db)
        }
        succeeded = true
        return result
        #else
        return try await queue.write(updates)
        #endif
    }

    func asyncRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
        do { try beginAccess() } catch {
            value(.failure(error))
            return
        }
        #if DEBUG
        let operation = HistoryPerformanceTrace.capture(database: self)?.begin(.readWait)
        #endif
        queue.asyncRead { [self] result in
            defer { endAccess() }
            #if DEBUG
            operation?.move(to: .read)
            defer { operation?.finish() }
            #endif
            value(result)
        }
    }

    /// All observers use asynchronous delivery. Registration and cancellation
    /// participate in draining; close cancels observations even if their UI
    /// owners have not been released yet.
    func observe<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>, on deliveryQueue: DispatchQueue,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable {
        do { try beginAccess() } catch {
            let cancelled = Atomic(false)
            deliveryQueue.async {
                guard !cancelled.wrappedValue else { return }
                onError(error)
            }
            return AnyDatabaseCancellable { cancelled.wrappedValue = true }
        }
        defer { endAccess() }
        let id = UUID()
        let token = observation.start(in: queue, scheduling: .async(onQueue: deliveryQueue),
            onError: { [weak self] error in
                guard self?.isActive == true else { return }
                onError(error)
            }, onChange: { [weak self] value in
                guard self?.isActive == true else { return }
                onChange(value)
            })
        condition.lock()
        let keep = acceptingAccess
        if keep { observations[id] = token }
        condition.unlock()
        if !keep { token.cancel() }
        return AnyDatabaseCancellable { [self] in cancelObservation(id) }
    }

    private func cancelObservation(_ id: UUID) {
        condition.lock()
        let token = observations.removeValue(forKey: id)
        if token != nil { accesses += 1 }
        condition.unlock()
        guard let token else { return }
        defer { endAccess() }
        token.cancel()
    }

    /// Call off-main, outside a database access. No access lock is held while
    /// GRDB runs SQL or invokes callbacks. A failed close stays retired and
    /// can be retried; it must never reopen admission on the old connection.
    func close() throws {
        closeLock.lock()
        defer { closeLock.unlock() }
        condition.lock()
        if closed {
            condition.unlock()
            return
        }
        acceptingAccess = false
        let tokens = Array(observations.values)
        observations.removeAll()
        condition.unlock()
        for token in tokens { token.cancel() }

        condition.lock()
        while accesses > 0 { condition.wait() }
        condition.unlock()
        // GRDB's serial queue also drains observer removal and the final
        // transaction cleanup of callback-based reads before closing.
        try queue.close()
        condition.lock()
        closed = true
        condition.unlock()
    }
}
