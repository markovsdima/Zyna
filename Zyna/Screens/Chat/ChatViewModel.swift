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

    /// Publishes table-ready diffs with IndexPaths for the inverted table.
    let tableDiffsSubject = PassthroughSubject<[ChatTableDiff], Never>()

    let roomName: String

    // MARK: - Coordinator callback
    var onBack: (() -> Void)?

    // MARK: - Private

    let timelineService: TimelineService
    private var timelineTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(room: Room) {
        self.roomName = room.displayName() ?? "Chat"
        self.timelineService = TimelineService(room: room)

        timelineService.isPaginatingSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPaginating)

        timelineTask = Task { [weak self] in
            guard let self else { return }
            await self.timelineService.startListening()

            // AsyncStream with .bufferingNewest(1) ensures true coalescing:
            // while we process one snapshot, rapid-fire SDK updates overwrite
            // the buffer and only the latest snapshot is delivered next.
            let stream = AsyncStream<[ChatMessage]>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                self.timelineService.messagesSubject
                    .dropFirst() // skip initial empty value
                    .sink { continuation.yield($0) }
                    .store(in: &self.cancellables)
            }

            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run { self.applySnapshot(snapshot) }
            }
        }
    }

    @MainActor
    private func applySnapshot(_ chronological: [ChatMessage]) {
        let reversed = Array(chronological.reversed())
        let oldMessages = messages
        let oldCount = oldMessages.count

        Self.prefetchImages(reversed)
        messages = reversed

        let tableDiffs = Self.computeTableDiffs(
            old: oldMessages,
            new: reversed,
            oldCount: oldCount
        )
        if !tableDiffs.isEmpty {
            print("[chat-vm] UI update: \(tableDiffs), \(reversed.count) messages")
            tableDiffsSubject.send(tableDiffs)
        }

        // Auto-paginate when SDK delivers fewer messages than one page
        if reversed.count < 20 && !isPaginating {
            loadOlderMessages()
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
        timelineTask?.cancel()
        timelineTask = nil
        timelineService.stopListening()
    }

    // MARK: - Snapshot Diffing (compares old vs new reversed arrays)

    private static func computeTableDiffs(
        old: [ChatMessage],
        new: [ChatMessage],
        oldCount: Int
    ) -> [ChatTableDiff] {
        let newCount = new.count

        // Empty → non-empty: reload
        if oldCount == 0 && newCount > 0 {
            return [.reloadData]
        }

        // New messages appended at chronological end = inserted at row 0 in reversed array.
        // Detect: new array is longer, and the tail matches the old array.
        if newCount > oldCount {
            let appendedCount = newCount - oldCount
            let tailMatches = old.isEmpty || (new[appendedCount].id == old[0].id)
            if tailMatches {
                let indexPaths = (0..<appendedCount).map { IndexPath(row: $0, section: 0) }
                return [.insertRows(indexPaths)]
            }
        }

        // Everything else (pagination, profile updates, decryption, removals): reload.
        // This is fine because coalescing ensures we rarely hit this path repeatedly.
        if old != new {
            return [.reloadData]
        }

        return []
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
