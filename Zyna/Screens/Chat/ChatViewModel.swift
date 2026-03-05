//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
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
            .sink { [weak self] messages in
                Self.prefetchImages(messages)
                self?.messages = messages
            }
            .store(in: &cancellables)

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

    // MARK: - Prefetch

    private static func prefetchImages(_ messages: [ChatMessage]) {
        for message in messages {
            guard case .image(let source, let width, let height, _) = message.content else { continue }
            guard MediaCache.shared.image(for: source) == nil else { continue }
            let thumbWidth = UInt64((ScreenConstants.width * 0.75) * UIScreen.main.scale)
            let thumbHeight: UInt64
            if let width, let height, height > 0 {
                thumbHeight = UInt64(CGFloat(thumbWidth) / CGFloat(width) * CGFloat(height))
            } else {
                thumbHeight = thumbWidth * 3 / 4
            }
            Task { await MediaCache.shared.loadThumbnail(source: source, width: thumbWidth, height: thumbHeight) }
        }
    }
}
