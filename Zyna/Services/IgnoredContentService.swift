// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK

/// One subscription per account activation. Late reads cannot overwrite a
/// newer sync snapshot, and retired databases reject old-account writes.
final class IgnoredContentService: @unchecked Sendable {
    let client: Client
    private let database: AccountDatabase
    private let revision = Atomic(0)
    private let stopped = Atomic(false)
    private let ignoredIDs = Atomic(Set<String>())
    var userIDs: Set<String> { ignoredIDs.wrappedValue }
    private let queue = DispatchQueue(label: "com.zyna.ignored-content", qos: .userInitiated)
    private var observation: TaskHandle?
    private let source: any IgnoredUsersProviding
    private let initialRead = Atomic<Task<Void, Never>?>(nil)

    init(client: Client, database: AccountDatabase, source: (any IgnoredUsersProviding)? = nil) {
        self.client = client
        self.database = database
        self.source = source ?? IgnoredUsersService(client: client)
        observation = self.source.observeIgnoredUsers { [weak self] ids in
            guard let self else { return }
            self.revision.modify { version in
                version += 1
                // Enqueue snapshots and confirmed deltas in the same order
                // as their revisions. A delta must not discard a preceding
                // full snapshot containing changes to other users.
                self.queue.async { [weak self] in
                    do { try self?.apply(ids) }
                    catch { ScopedLog(.rooms)("Couldn't update blocked-content visibility: \(error)") }
                }
            }
        }
    }

    deinit { observation?.cancel(); initialRead.wrappedValue?.cancel() }
    func stop() {
        stopped.wrappedValue = true
        initialRead.wrappedValue?.cancel()
        observation?.cancel(); observation = nil
    }

    /// The persisted list is usable immediately. A slow account-data GET
    /// must never postpone offline sync or encryption listener setup.
    func start() {
        initialRead.modify { task in
            guard task == nil, !stopped.wrappedValue else { return }
            let version = revision.wrappedValue
            task = Task { [weak self, source] in
                do {
                    let ids = try await source.ignoredUserIds()
                    try Task.checkCancellation()
                    try await self?.applySnapshot(ids, version: version)
                } catch is CancellationError { }
                catch { ScopedLog(.rooms)("Couldn't refresh blocked-content visibility: \(error)") }
            }
        }
    }

    func storedUserIDs() async throws -> Set<String> {
        try await database.read { try IgnoredContentStore.userIDs(in: $0) }
    }

    private func applySnapshot(_ ids: [String], version: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if revision.wrappedValue == version { try apply(ids) }
                    continuation.resume()
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Called only after a successful SDK write. Merge a single confirmed
    /// change into the persisted list, without a second network round trip.
    /// Separate local changes compose even when their reads overlap.
    func applyConfirmedChange(userID: String, isIgnored: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            revision.modify { version in
                version += 1
                queue.async { [self] in
                    defer { continuation.resume() }
                    guard !stopped.wrappedValue, database.isActive else { return }
                    do {
                        let (ids, changed) = try database.write { db in
                            var ids = try IgnoredContentStore.userIDs(in: db)
                            if isIgnored { ids.insert(userID) } else { ids.remove(userID) }
                            return (ids, try IgnoredContentStore.replace(ids, in: db))
                        }
                        publish(ids, changed: changed)
                    } catch {
                        // A local cache error cannot turn an acknowledged PUT
                        // into a failed block/unblock in the UI. A later snapshot
                        // can repair the cache.
                        ScopedLog(.rooms)("Couldn't persist confirmed blocked-content visibility: \(error)")
                    }
                }
            }
        }
    }

    #if DEBUG
    func waitForInitialReadForTesting() async { await initialRead.wrappedValue?.value }
    #endif

    private func apply(_ ids: [String]) throws {
        guard !stopped.wrappedValue, database.isActive else { return }
        let changed = try database.write { try IgnoredContentStore.replace(Set(ids), in: $0) }
        publish(Set(ids), changed: changed)
    }

    private func publish(_ ids: Set<String>, changed: Bool) {
        ignoredIDs.wrappedValue = ids
        if changed {
            NotificationCenter.default.post(name: IgnoredContentStore.didChange, object: database)
        }
    }
}
