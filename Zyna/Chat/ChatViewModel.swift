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

    /// Called when messages become redacted (from any source). Passes message IDs.
    var onRedactedDetected: (([String]) -> Void)?

    /// Called when a redaction request fails.
    var onRedactionFailed: ((String, Error) -> Void)?

    let roomName: String
    @Published private(set) var partnerPresence: UserPresence?
    @Published private(set) var partnerUserId: String?

    // MARK: - Coordinator callback
    var onBack: (() -> Void)?

    // MARK: - Private

    let timelineService: TimelineService
    private let coalescer = TimelineCoalescer()
    private var cancellables = Set<AnyCancellable>()
    private var directUserId: String?

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

            // Detect newly redacted messages in updates
            let redactedIds: [String]
            if case .batch(_, _, let updates, _) = tableUpdate, !updates.isEmpty {
                redactedIds = updates.compactMap { ip -> String? in
                    guard ip.row < newMessages.count else { return nil }
                    let msg = newMessages[ip.row]
                    return msg.content.isRedacted ? msg.id : nil
                }
            } else {
                redactedIds = []
            }

            self.messages = newMessages

            if !redactedIds.isEmpty {
                // Filter redacted from normal table update (controller handles them via animation)
                if case .batch(let del, let ins, let upd, let anim) = tableUpdate {
                    let filtered = upd.filter { ip in
                        guard ip.row < newMessages.count else { return true }
                        return !newMessages[ip.row].content.isRedacted
                    }
                    self.onTableUpdate?(.batch(deletions: del, insertions: ins, updates: filtered, animated: anim))
                } else {
                    self.onTableUpdate?(tableUpdate)
                }
                self.onRedactedDetected?(redactedIds)
            } else {
                self.onTableUpdate?(tableUpdate)
            }

            // Auto-paginate when SDK delivers fewer messages than one page
            if newMessages.count < 20 && !self.isPaginating {
                self.loadOlderMessages()
            }
        }

        Task { [weak self] in
            await self?.timelineService.startListening()
        }

        Task { [weak self] in
            guard let self else { return }
            guard let info = try? await room.roomInfo() else { return }
            guard info.isDirect, let userId = info.heroes.first?.userId else { return }
            await MainActor.run {
                self.directUserId = userId
                self.partnerUserId = userId
            }
            PresenceTracker.shared.register(userIds: [userId], for: "chat")
            PresenceTracker.shared.$statuses
                .map { $0[userId] }
                .receive(on: DispatchQueue.main)
                .assign(to: &self.$partnerPresence)
        }
    }

    // MARK: - Actions

    func sendMessage(_ text: String) {
        Task {
            await timelineService.sendMessage(text)
        }
    }

    func sendVoiceMessage(fileURL: URL, duration: TimeInterval, waveform: [Float]) {
        Task {
            await timelineService.sendVoiceMessage(url: fileURL, duration: duration, waveform: waveform)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func sendImages(_ images: [ProcessedImage], caption: String?) {
        for (i, image) in images.enumerated() {
            let cap = (i == 0) ? caption : nil
            Task {
                await timelineService.sendImage(
                    imageData: image.imageData,
                    width: image.width, height: image.height, caption: cap
                )
            }
        }
    }

    func toggleReaction(_ key: String, for message: ChatMessage) {
        guard let itemId = message.itemIdentifier else { return }
        Task {
            await timelineService.toggleReaction(key, to: itemId)
        }
    }

    func redactMessage(_ message: ChatMessage) {
        guard let itemId = message.itemIdentifier else { return }
        Task {
            do {
                try await timelineService.redactEvent(itemId)
            } catch {
                await MainActor.run {
                    onRedactionFailed?(message.id, error)
                }
            }
        }
    }

    func hideMessage(_ messageId: String) {
        coalescer.hide(messageId)
    }

    func loadOlderMessages() {
        guard !isPaginating else { return }
        Task {
            await timelineService.paginateBackwards()
        }
    }

    func cleanup() {
        PresenceTracker.shared.unregister(for: "chat")
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
