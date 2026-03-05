//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

final class ChatViewModel {

    // MARK: - Published State

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isPaginating: Bool = false

    let roomName: String

    // MARK: - Coordinator callback
    var onBack: (() -> Void)?

    // MARK: - Private

    private let timelineService: TimelineService
    private var cancellables = Set<AnyCancellable>()

    init(room: Room) {
        self.roomName = room.displayName() ?? "Chat"
        self.timelineService = TimelineService(room: room)

        timelineService.messagesSubject
            .map { $0.reversed() }
            .receive(on: DispatchQueue.main)
            .assign(to: &$messages)

        timelineService.isPaginatingSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPaginating)

        Task {
            await timelineService.startListening()
        }
    }

    // MARK: - Actions

    func sendMessage(_ text: String) {
        Task {
            await timelineService.sendMessage(text)
        }
    }

    func loadOlderMessages() {
        guard !isPaginating else { return }
        Task {
            await timelineService.paginateBackwards()
        }
    }

    func cleanup() {
        timelineService.stopListening()
    }
}
