//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRustSDK

@MainActor
final class BlockedUsersViewModel: ObservableObject {

    struct Entry: Identifiable, Equatable {
        let userId: String
        let displayName: String?

        var id: String { userId }
        var title: String { displayName ?? userId }
        /// Only when it adds something the title doesn't already show.
        var subtitle: String? { displayName == nil ? nil : userId }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoading = true
    /// Set when the list itself failed to load — without it an empty
    /// `entries` would read as "you haven't blocked anyone".
    @Published private(set) var loadError: String?
    @Published private(set) var processingUserId: String?
    @Published var pendingUnblock: Entry?
    @Published var errorMessage: String?

    private static let profileFetchConcurrency = 5

    private var subscription: TaskHandle?
    private var displayNameTask: Task<Void, Never>?

    init() {
        subscription = IgnoredUsersService.shared.observeIgnoredUsers { userIds in
            Task { @MainActor [weak self] in
                self?.apply(userIds: userIds)
            }
        }
        load()
    }

    deinit {
        subscription?.cancel()
        displayNameTask?.cancel()
    }

    // MARK: - Unblocking

    func requestUnblock(_ entry: Entry) {
        pendingUnblock = entry
    }

    func cancelUnblock() {
        pendingUnblock = nil
    }

    func confirmUnblock(_ entry: Entry) {
        pendingUnblock = nil
        processingUserId = entry.userId

        Task { [weak self] in
            do {
                try await IgnoredUsersService.shared.unignore(userId: entry.userId)
                // The subscription should push the new list; refresh anyway so
                // the row can't outlive the block that produced it.
                self?.load()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.processingUserId = nil
        }
    }

    // MARK: - Loading

    func retry() {
        isLoading = true
        loadError = nil
        load()
    }

    private func load() {
        Task { [weak self] in
            do {
                let userIds = try await IgnoredUsersService.shared.ignoredUserIds()
                self?.apply(userIds: userIds)
            } catch {
                self?.isLoading = false
                self?.loadError = error.localizedDescription
            }
        }
    }

    /// Publishes user IDs immediately; display names are resolved in the
    /// background and applied when the batch completes.
    private func apply(userIds: [String]) {
        displayNameTask?.cancel()

        let knownNames = entries.reduce(into: [String: String]()) { names, entry in
            names[entry.userId] = entry.displayName
        }
        entries = Self.sorted(
            userIds.map { Entry(userId: $0, displayName: knownNames[$0]) }
        )
        isLoading = false
        loadError = nil

        resolveDisplayNames(for: userIds)
    }

    private func resolveDisplayNames(for userIds: [String]) {
        guard !userIds.isEmpty,
              let client = MatrixClientService.shared.client else {
            return
        }

        // Failure and "the server says there is no name" must stay apart:
        // one leaves the name we already show alone, the other clears it.
        let fetchName: @Sendable (String) async -> (String, Result<String?, Error>) = { userId in
            do {
                return (userId, .success(try await client.getProfile(userId: userId).displayName))
            } catch {
                return (userId, .failure(error))
            }
        }

        displayNameTask = Task { [weak self] in
            var names: [String: String] = [:]
            var answered: Set<String> = []

            // Sliding window rather than one task per id: a long block
            // list would otherwise fire hundreds of requests at once and
            // trip the server's rate limit, losing the names silently.
            await withTaskGroup(of: (String, Result<String?, Error>).self) { group in
                var pending = userIds.makeIterator()

                // `addTaskUnlessCancelled` stops a superseded resolver from
                // working through the rest of the list for results nobody
                // will apply.
                for _ in 0..<Self.profileFetchConcurrency {
                    guard let userId = pending.next() else { break }
                    _ = group.addTaskUnlessCancelled { await fetchName(userId) }
                }

                while let (userId, result) = await group.next() {
                    if case .success(let displayName) = result {
                        answered.insert(userId)
                        if let displayName, !displayName.isEmpty {
                            names[userId] = displayName
                        }
                    }
                    if let next = pending.next() {
                        _ = group.addTaskUnlessCancelled { await fetchName(next) }
                    }
                }
            }

            guard !Task.isCancelled, let self else { return }
            entries = Self.sorted(entries.map { entry in
                guard answered.contains(entry.userId) else { return entry }
                return Entry(userId: entry.userId, displayName: names[entry.userId])
            })
        }
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}
