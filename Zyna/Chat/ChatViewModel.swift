//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Combine
import MatrixRustSDK

final class ChatViewModel {

    // MARK: - State

    private(set) var messages: [ChatMessage] = []
    @Published private(set) var isPaginating: Bool = false

    /// Called on the main queue when the table needs updating.
    var onTableUpdate: ((TableUpdate) -> Void)?

    let roomName: String

    // MARK: - Coordinator callback
    var onBack: (() -> Void)?

    // MARK: - Private

    let timelineService: TimelineService
    private let coalescer = TimelineCoalescer()
    private var cancellables = Set<AnyCancellable>()

    init(room: Room) {
        self.roomName = room.displayName() ?? "Chat"
        self.timelineService = TimelineService(room: room)

        timelineService.isPaginatingSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPaginating)

        // Wire SDK diffs → coalescer
        timelineService.onDiffs = { [weak self] diffs in
            self?.coalescer.receive(diffs: diffs)
        }

        // Coalescer output → UI
        coalescer.onBatchReady = { [weak self] newMessages, tableUpdate in
            guard let self else { return }
            Self.prefetchImages(newMessages)
            self.messages = newMessages
            self.onTableUpdate?(tableUpdate)

            // Auto-paginate when SDK delivers fewer messages than one page
            if newMessages.count < 20 && !self.isPaginating {
                self.loadOlderMessages()
            }
        }

        Task { [weak self] in
            await self?.timelineService.startListening()
        }
    }

    // MARK: - Actions

    func sendMessage(_ text: String) {
        Task {
            await timelineService.sendMessage(text)
        }
    }

    func sendVoiceMessage(fileURL: URL, duration: TimeInterval, waveform: [UInt16]) {
        Task {
            await timelineService.sendVoiceMessage(url: fileURL, duration: duration, waveform: waveform)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func loadOlderMessages() {
        guard !isPaginating else { return }
        Task {
            await timelineService.paginateBackwards()
        }
    }

    func cleanup() {
        timelineService.onDiffs = nil
        coalescer.onBatchReady = nil
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
