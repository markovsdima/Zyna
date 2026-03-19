//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import UIKit
import MatrixRustSDK

final class RoomsViewModel {

    @Published private(set) var chats: [RoomModel] = []

    var onChatSelected: ((Room) -> Void)?

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
                self?.chats = rooms
                self?.syncRegistration()
            }
            .store(in: &cancellables)

        PresenceTracker.shared.$statuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.applyPresence(statuses)
            }
            .store(in: &cancellables)
    }

    // MARK: - Presence

    func registerPresence() {
        syncRegistration()
    }

    func unregisterPresence() {
        PresenceTracker.shared.unregister(for: "rooms")
    }

    private func syncRegistration() {
        let userIds = chats.compactMap { $0.directUserId }
        PresenceTracker.shared.register(userIds: userIds, for: "rooms")
    }

    private func applyPresence(_ statuses: [String: UserPresence]) {
        guard !statuses.isEmpty else { return }
        chats = chats.map { chat in
            guard let userId = chat.directUserId, let status = statuses[userId] else { return chat }
            var updated = chat
            updated.isOnline = status.online
            updated.lastSeen = status.lastSeen
            return updated
        }
    }

    // MARK: - Actions

    func selectChat(at index: Int) {
        guard index < chats.count else { return }
        let roomId = chats[index].id
        guard let room = roomListService.room(for: roomId) else { return }
        onChatSelected?(room)
    }

    func deleteChat(at index: Int) {
        guard index < chats.count else { return }
        chats.remove(at: index)
    }
}
