// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import MatrixRustSDK

enum DirectChatBlockingError: LocalizedError {
    case blocked(String)
    case staleSession

    var errorDescription: String? {
        switch self {
        case .blocked: String(localized: "Unblock this person to send messages or call.", table: "Blocking")
        case .staleSession: String(localized: "Something went wrong")
        }
    }
}

enum DirectChatBlockingPolicy {
    static func recipient(isDirect: Bool, activeMembers: UInt64, heroIDs: [String], ownID: String) -> String? {
        let others = Set(heroIDs.filter { $0 != ownID })
        guard isDirect, activeMembers == 2, others.count == 1 else { return nil }
        return others.first
    }

    static func recipient(in info: RoomInfo, ownID: String) -> String? {
        recipient(isDirect: info.isDirect, activeMembers: info.activeMembersCount,
                  heroIDs: info.heroes.map(\.userId), ownID: ownID)
    }

    /// Recheck at dispatch as well as in the composer: a prepared attachment
    /// or queued retry can outlive the screen that admitted it.
    static func requireUnblocked(room: Room) async throws {
        let (client, database, sessionID) = await MainActor.run {
            (MatrixClientService.shared.client, DatabaseService.shared.dbQueue,
             MatrixClientService.shared.currentLocalSessionId)
        }
        guard let client, sessionID != nil else { throw DirectChatBlockingError.staleSession }
        let ownID = try client.userId()
        try await requireUnblocked(room: room, database: database, ownID: ownID) {
            database.isActive && MatrixClientService.shared.client === client
                && MatrixClientService.shared.currentLocalSessionId == sessionID
        }
    }

    static func requireUnblocked(room: Room, database: AccountDatabase, ownID: String,
                                 isCurrentSession: @MainActor () -> Bool) async throws {
        guard await isCurrentSession() else { throw DirectChatBlockingError.staleSession }
        let info = try await Task.detached { try await room.roomInfo() }.value
        try Task.checkCancellation()
        let recipient = recipient(in: info, ownID: ownID)
        let blocked = try await database.read { db in
            try recipient.map { try IgnoredContentStore.contains($0, in: db) } ?? false
        }
        try Task.checkCancellation()
        guard await isCurrentSession() else { throw DirectChatBlockingError.staleSession }
        if blocked, let recipient { throw DirectChatBlockingError.blocked(recipient) }
    }
}

/// Observes the persisted account list without fetching account data from
/// the server or creating another ignored-users SDK subscription per chat.
final class DirectChatBlockingModel {
    private enum FailedOperation { case read, unblock }
    enum State: Equatable {
        case loading, allowed, blocked(String)
        var blockedUserID: String? { if case .blocked(let id) = self { return id }; return nil }
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var recipientName: String?
    @Published private(set) var isUnblocking = false
    @Published var error: String?
    private let database: AccountDatabase
    private let ownID: String
    private let isCurrentSession: () -> Bool
    private let unignore: (String) async throws -> Void
    private let readIgnoredIDs: () async throws -> Set<String>
    private var recipientID: String?
    private var hasRoomInfo = false
    private var ignoredIDs: Set<String>?
    private var didFailReading = false
    private var failedOperation: FailedOperation?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var revision = 0
    private var started = false

    init(database: AccountDatabase, ownID: String, isCurrentSession: @escaping () -> Bool,
         unignore: @escaping (String) async throws -> Void,
         readIgnoredIDs: (() async throws -> Set<String>)? = nil) {
        self.database = database; self.ownID = ownID
        self.isCurrentSession = isCurrentSession; self.unignore = unignore
        self.readIgnoredIDs = readIgnoredIDs ?? {
            try await database.read { try IgnoredContentStore.userIDs(in: $0) }
        }
    }

    deinit { readTask?.cancel(); writeTask?.cancel() }

    func start() {
        guard !started else { return }
        started = true
        observation = NotificationCenter.default.publisher(for: IgnoredContentStore.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, notification.object as? AccountDatabase === self.database else { return }
                self.refresh()
            }
        refresh()
    }

    func update(_ info: RoomInfo) {
        guard isCurrentSession() else { return }
        recipientID = DirectChatBlockingPolicy.recipient(in: info, ownID: ownID)
        let name = info.heroes.first { $0.userId == recipientID }?.displayName ?? recipientID
        if recipientName != name { recipientName = name }
        hasRoomInfo = true
        publish()
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard started, isCurrentSession() else { return nil }
        readTask?.cancel(); revision += 1
        let version = revision
        readTask = Task { @MainActor [weak self, readIgnoredIDs] in
            do {
                let ids = try await readIgnoredIDs()
                guard let self, self.accepts(version) else { return }
                self.ignoredIDs = ids
                self.didFailReading = false
                if self.failedOperation == .read { self.failedOperation = nil }
                self.publish()
            } catch {
                guard let self, self.accepts(version) else { return }
                self.didFailReading = true
                self.publish()
                self.failedOperation = .read
                self.error = error.localizedDescription
            }
        }
        return readTask
    }

    func unblock() {
        guard started, isCurrentSession(), !isUnblocking, let id = state.blockedUserID else { return }
        isUnblocking = true; error = nil
        writeTask = Task { @MainActor [weak self, unignore] in
            do {
                try await unignore(id)
                guard let self, self.started, self.isCurrentSession(), !Task.isCancelled else { return }
                // Read the confirmed local change; never reopen the composer
                // merely because the user tapped Unblock.
                await self.refresh()?.value
                guard self.started, self.isCurrentSession(), !Task.isCancelled else { return }
                if self.failedOperation == .unblock { self.failedOperation = nil }
            } catch {
                guard let self, self.started, self.isCurrentSession(), !Task.isCancelled else { return }
                self.failedOperation = .unblock
                self.error = error.localizedDescription
            }
            self?.isUnblocking = false
        }
    }

    func retryLastFailure() {
        guard started, isCurrentSession() else { return }
        error = nil
        switch failedOperation {
        case .read: refresh()
        case .unblock: unblock()
        case nil: break
        }
    }

    func stop() {
        started = false; revision += 1
        observation = nil; readTask?.cancel(); writeTask?.cancel()
        isUnblocking = false
    }

    private func accepts(_ version: Int) -> Bool {
        started && isCurrentSession() && !Task.isCancelled && revision == version
    }

    private func publish() {
        let next: State
        // An initial read failure must not leave editing disabled forever.
        // Dispatch still checks the persisted list; retain any known blocks.
        if ignoredIDs == nil { next = didFailReading ? .allowed : .loading }
        else if ignoredIDs?.isEmpty == true { next = .allowed }
        else if !hasRoomInfo { next = .loading }
        else if let recipientID, ignoredIDs?.contains(recipientID) == true { next = .blocked(recipientID) }
        else { next = .allowed }
        if state != next { state = next }
    }
}
