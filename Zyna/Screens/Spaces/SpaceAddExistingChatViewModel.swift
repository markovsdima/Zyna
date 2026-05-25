//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

final class SpaceAddExistingChatViewModel {

    let parent: RoomModel

    private(set) var chats: [RoomModel] = []
    private(set) var isLoading = true
    private(set) var isAdding = false

    var onChanged: (() -> Void)?
    var onAddingChanged: ((Bool) -> Void)?
    var onChatAdded: ((RoomModel) -> Void)?
    var onError: ((String) -> Void)?

    private let roomListService: ZynaRoomListService
    private var allChats: [RoomModel] = []
    private var searchQuery = ""
    private var loadTask: Task<Void, Never>?
    private var addTask: Task<Void, Never>?

    init(
        parent: RoomModel,
        roomListService: ZynaRoomListService
    ) {
        self.parent = parent
        self.roomListService = roomListService
    }

    deinit {
        loadTask?.cancel()
        addTask?.cancel()
    }

    var title: String {
        String(localized: "Add Chat")
    }

    var subtitle: String {
        let parentName = parent.name.isEmpty ? String(localized: "Untitled") : parent.name
        return String(localized: "Select a chat to add to \(parentName).")
    }

    var emptyMessage: String {
        if isLoading {
            return String(localized: "Loading")
        }

        return allChats.isEmpty
            ? String(localized: "No chats to add")
            : String(localized: "No chats found")
    }

    func loadChats() {
        loadTask?.cancel()
        isLoading = true
        onChanged?()

        loadTask = Task { [weak self] in
            guard let self else { return }

            var childIds = Set(
                roomListService.cachedSpaceChildRooms(for: parent.id).map(\.id)
            )
            let children = await roomListService.refreshSpaceChildren(for: parent.id)
            childIds.formUnion(children.rooms.map(\.id))
            childIds.insert(parent.id)

            let summaries = await roomListService.joinedRoomSummaries()
            var seenIds = Set<String>()
            let models = summaries.compactMap { summary -> RoomModel? in
                guard !summary.isSpace,
                      !childIds.contains(summary.id),
                      seenIds.insert(summary.id).inserted else {
                    return nil
                }
                return RoomModel(from: summary)
            }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let statuses = PresenceTracker.shared.statuses
                self.isLoading = false
                if statuses.isEmpty {
                    self.allChats = models
                } else {
                    self.allChats = models.map { room in
                        guard let userId = room.directUserId,
                              let status = statuses[userId] else { return room }
                        var updated = room
                        updated.isOnline = status.online
                        updated.lastSeen = status.lastSeen
                        return updated
                    }
                }
                self.applyFilter()
                self.onChanged?()
            }
        }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        applyFilter()
        onChanged?()
    }

    func addChat(at index: Int) {
        guard chats.indices.contains(index), !isAdding else { return }
        addChat(chats[index])
    }

    private func addChat(_ chat: RoomModel) {
        isAdding = true
        onAddingChanged?(true)

        addTask?.cancel()
        addTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await roomListService.addChild(chat.id, toSpace: parent.id, context: "existing-chat")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isAdding = false
                    self.onAddingChanged?(false)
                    self.onChatAdded?(chat)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isAdding = false
                    self.onAddingChanged?(false)
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    private func applyFilter() {
        guard !searchQuery.isEmpty else {
            chats = allChats
            return
        }

        chats = allChats.filter { room in
            room.name.lowercased().contains(searchQuery)
                || room.lastMessage.lowercased().contains(searchQuery)
                || room.directUserId?.lowercased().contains(searchQuery) == true
        }
    }
}
