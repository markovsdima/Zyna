//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import UIKit

final class RoomsViewModel {

    @Published private(set) var chats: [RoomModel] = []

    var onChatSelected: ((String) -> Void)?

    private let roomListService = ZynaRoomListService()
    private var cancellables = Set<AnyCancellable>()

    init() {
        roomListService.roomsSubject
            .map { summaries in
                ScopedLog(.ui)("Received \(summaries.count) rooms in UI")
                return summaries.map { RoomModel(from: $0) }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$chats)
    }

    func selectChat(at index: Int) {
        guard index < chats.count else { return }
        onChatSelected?(chats[index].id)
    }

    func deleteChat(at index: Int) {
        guard index < chats.count else { return }
        chats.remove(at: index)
    }
}
