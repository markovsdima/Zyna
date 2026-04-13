//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import UIKit
import MatrixRustSDK

final class RoomsViewModel {

    private(set) var chats: [RoomModel] = []

    var onChatSelected: ((Room) -> Void)?
    var onTableUpdate: ((RoomsTableUpdate) -> Void)?

    let roomListService = ZynaRoomListService()
    private var cancellables = Set<AnyCancellable>()

    init() {
        roomListService.roomsSubject
            .map { summaries in
                ScopedLog(.ui)("Received \(summaries.count) rooms in UI")
                return summaries.map { RoomModel(from: $0) }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rooms in
                self?.applyRooms(rooms)
            }
            .store(in: &cancellables)

        PresenceTracker.shared.$statuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.applyPresence(statuses)
            }
            .store(in: &cancellables)
    }

    // MARK: - Room updates (diff-based)

    private var isFirstLoad = true

    private func applyRooms(_ newRooms: [RoomModel]) {
        // Apply current presence state to incoming rooms so the
        // diff sees the combined result rather than flipping online
        // status off and back on.
        let statuses = PresenceTracker.shared.statuses
        var rooms = newRooms
        if !statuses.isEmpty {
            rooms = rooms.map { room in
                guard let userId = room.directUserId,
                      let status = statuses[userId] else { return room }
                var r = room
                r.isOnline = status.online
                r.lastSeen = status.lastSeen
                return r
            }
        }

        allChats = rooms

        if isFirstLoad {
            isFirstLoad = false
            if searchQuery.isEmpty {
                chats = rooms
                onTableUpdate?(.reload)
            } else {
                applyFilter()
            }
        } else if searchQuery.isEmpty {
            let update = Self.computeDiff(old: chats, new: rooms)
            chats = rooms
            onTableUpdate?(update)
        } else {
            applyFilter()
        }

        syncRegistration()
    }

    // MARK: - Presence (partial reload, no diff)

    func registerPresence() {
        syncRegistration()
    }

    func unregisterPresence() {
        PresenceTracker.shared.unregister(for: "rooms")
    }

    private func syncRegistration() {
        let userIds = allChats.compactMap { $0.directUserId }
        PresenceTracker.shared.register(userIds: userIds, for: "rooms")
    }

    private func applyPresence(_ statuses: [String: UserPresence]) {
        guard !statuses.isEmpty else { return }

        // Update allChats
        for (idx, chat) in allChats.enumerated() {
            guard let userId = chat.directUserId,
                  let status = statuses[userId],
                  chat.isOnline != status.online else { continue }
            allChats[idx].isOnline = status.online
            allChats[idx].lastSeen = status.lastSeen
        }

        // Update visible chats
        var changedRows: [IndexPath] = []
        for (idx, chat) in chats.enumerated() {
            guard let userId = chat.directUserId,
                  let status = statuses[userId] else { continue }
            if chat.isOnline != status.online {
                chats[idx].isOnline = status.online
                chats[idx].lastSeen = status.lastSeen
                changedRows.append(IndexPath(row: idx, section: 0))
            }
        }

        if !changedRows.isEmpty {
            onTableUpdate?(.partialReload(changedRows))
        }
    }

    // MARK: - Search

    private var allChats: [RoomModel] = []
    private var searchQuery: String = ""

    func filterChats(query: String) {
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        applyFilter()
    }

    private func applyFilter() {
        if searchQuery.isEmpty {
            chats = allChats
        } else {
            chats = allChats.filter { $0.name.lowercased().contains(searchQuery) }
        }
        onTableUpdate?(.reload)
    }

    // MARK: - Actions

    func selectChat(at index: Int) {
        guard index < chats.count else { return }
        let roomId = chats[index].id
        if let room = roomListService.room(for: roomId) {
            onChatSelected?(room)
            return
        }
        // SDK not ready yet (rooms visible from GRDB cache).
        // Poll until the room appears or timeout after 10s.
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if let room = self.roomListService.room(for: roomId) {
                    self.onChatSelected?(room)
                    return
                }
            }
        }
    }

    func deleteChat(at index: Int) {
        guard index < chats.count else { return }
        chats.remove(at: index)
    }

    // MARK: - Diff

    private static func computeDiff(
        old: [RoomModel],
        new: [RoomModel]
    ) -> RoomsTableUpdate {
        let oldIds = old.map(\.id)
        let newIds = new.map(\.id)

        let idDiff = newIds.difference(from: oldIds)

        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var removedOldOffsets = Set<Int>()

        for change in idDiff {
            switch change {
            case .remove(let offset, _, _):
                deletions.append(IndexPath(row: offset, section: 0))
                removedOldOffsets.insert(offset)
            case .insert(let offset, _, _):
                insertions.append(IndexPath(row: offset, section: 0))
            }
        }

        // Detect content changes on rows that stayed
        let newById = Dictionary(
            new.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        var reloads: [IndexPath] = []
        for (oldIdx, oldRoom) in old.enumerated() {
            guard !removedOldOffsets.contains(oldIdx) else { continue }
            if let newIdx = newById[oldRoom.id], old[oldIdx] != new[newIdx] {
                reloads.append(IndexPath(row: oldIdx, section: 0))
            }
        }

        if deletions.isEmpty && insertions.isEmpty && reloads.isEmpty {
            return .none
        }
        return .batch(
            deletions: deletions,
            insertions: insertions,
            reloads: reloads
        )
    }
}

// MARK: - Table Update

enum RoomsTableUpdate {
    case none
    case reload
    case batch(
        deletions: [IndexPath],
        insertions: [IndexPath],
        reloads: [IndexPath]
    )
    case partialReload([IndexPath])
}
