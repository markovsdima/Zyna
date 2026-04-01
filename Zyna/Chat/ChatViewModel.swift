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
    @Published private(set) var replyingTo: ChatMessage?

    /// Called on the main queue when the table needs updating.
    var onTableUpdate: ((TableUpdate) -> Void)?

    /// Called when messages become redacted (from any source). Passes message IDs.
    var onRedactedDetected: (([String]) -> Void)?

    /// Called when a redaction request fails.
    var onRedactionFailed: ((String, Error) -> Void)?

    let roomName: String
    @Published private(set) var partnerPresence: UserPresence?
    @Published private(set) var partnerUserId: String?
    @Published private(set) var memberCount: Int?

    // MARK: - Coordinator callback
    var onBack: (() -> Void)?

    // MARK: - Private

    let timelineService: TimelineService
    private let diffBatcher: TimelineDiffBatcher
    private let window: MessageWindow
    private var hiddenIds = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    private var directUserId: String?

    /// Whether the window is at the live edge (newest messages visible).
    var isAtLiveEdge: Bool { window.isAtLiveEdge }

    init(room: Room) {
        self.roomName = room.displayName() ?? "Chat"
        self.timelineService = TimelineService(room: room)
        self.diffBatcher = TimelineDiffBatcher(
            roomId: room.id(),
            dbQueue: DatabaseService.shared.dbQueue
        )
        self.window = MessageWindow(
            roomId: room.id(),
            dbQueue: DatabaseService.shared.dbQueue
        )

        timelineService.isPaginatingSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPaginating)

        // Write path: SDK diffs → GRDB
        let batcher = diffBatcher
        timelineService.onDiffs = { diffs in
            batcher.receive(diffs: diffs)
        }

        // Bridge: batcher flush → window refresh
        let win = window
        diffBatcher.onFlush = { [weak win] in
            win?.refresh()
        }

        // Read path: window changes → UI
        window.onChange = { [weak self] newStored, prevStored in
            self?.handleObservationChange(newStored: newStored, prevStored: prevStored)
        }

        // Initial load from GRDB cache
        window.loadInitial()

        Task { [weak self] in
            await self?.timelineService.startListening()
        }

        Task { [weak self] in
            guard let self else { return }
            guard let info = try? await room.roomInfo() else { return }

            if info.isDirect, let userId = info.heroes.first?.userId {
                await MainActor.run {
                    self.directUserId = userId
                    self.partnerUserId = userId
                }
                PresenceTracker.shared.register(userIds: [userId], for: "chat")
                PresenceTracker.shared.$statuses
                    .map { $0[userId] }
                    .receive(on: DispatchQueue.main)
                    .assign(to: &self.$partnerPresence)
            } else {
                let count = Int(info.joinedMembersCount)
                await MainActor.run {
                    self.memberCount = count
                }
            }
        }
    }

    // MARK: - Window Change Handling

    private func handleObservationChange(newStored: [StoredMessage], prevStored: [StoredMessage]?) {
        // 1. Detect newly redacted messages
        let newlyRedactedIds: [String]
        if let prevStored {
            let prevById = Dictionary(prevStored.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            newlyRedactedIds = newStored.compactMap { msg in
                guard msg.contentType == "redacted" else { return nil }
                guard let prev = prevById[msg.id], prev.contentType != "redacted" else { return nil }
                return msg.id
            }
        } else {
            newlyRedactedIds = []
        }

        // 2. Build display array: filter hidden and already-redacted (keep newly-redacted for animation)
        let newlyRedactedSet = Set(newlyRedactedIds)
        let displayStored = newStored.filter { msg in
            if hiddenIds.contains(msg.id) { return false }
            if msg.contentType == "redacted" && !newlyRedactedSet.contains(msg.id) { return false }
            return true
        }

        let newMessages = displayStored.compactMap { $0.toChatMessage() }

        // 3. Prefetch images
        Self.prefetchImages(newMessages)

        // 4. Compute table update
        let oldMessages = self.messages
        self.messages = newMessages

        let tableUpdate: TableUpdate
        if prevStored == nil {
            tableUpdate = .reload
        } else {
            tableUpdate = Self.computeTableUpdate(old: oldMessages, new: newMessages)
        }

        // 5. Emit (filter redacted from normal updates, send separately for animation)
        if !newlyRedactedIds.isEmpty {
            if case .batch(let del, let ins, let upd, let anim) = tableUpdate {
                let filtered = upd.filter { ip in
                    guard ip.row < newMessages.count else { return true }
                    return !newMessages[ip.row].content.isRedacted
                }
                onTableUpdate?(.batch(deletions: del, insertions: ins, updates: filtered, animated: anim))
            } else {
                onTableUpdate?(tableUpdate)
            }
            onRedactedDetected?(newlyRedactedIds)
        } else {
            onTableUpdate?(tableUpdate)
        }

        // 6. Auto-paginate if too few messages and GRDB + SDK both need more
        if newMessages.count < 20 && !isPaginating && !window.hasOlderInDB {
            loadOlderFromServer()
        }
    }

    private static func computeTableUpdate(old: [ChatMessage], new: [ChatMessage]) -> TableUpdate {
        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)
        let idDiff = newIDs.difference(from: oldIDs)

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

        let newById = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
        var updates: [IndexPath] = []
        for (oldIdx, oldMsg) in old.enumerated() {
            guard !removedOldOffsets.contains(oldIdx) else { continue }
            if let newIdx = newById[oldMsg.id], old[oldIdx] != new[newIdx] {
                updates.append(IndexPath(row: oldIdx, section: 0))
            }
        }

        let animated = deletions.isEmpty && insertions.count == 1 && updates.isEmpty
        return .batch(deletions: deletions, insertions: insertions, updates: updates, animated: animated)
    }

    // MARK: - Pagination

    /// Load older messages from GRDB. Returns true if data was available.
    func loadOlderFromDB() -> Bool {
        window.loadOlder()
    }

    /// Paginate from server when GRDB is exhausted.
    func loadOlderFromServer() {
        guard !isPaginating else { return }
        Task {
            await timelineService.paginateBackwards()
        }
    }

    /// Load newer messages from GRDB (when scrolling back down after jump).
    func loadNewerMessages() {
        window.loadNewer()
    }

    // MARK: - Jump

    func jumpToMessage(eventId: String) {
        window.jumpTo(eventId: eventId)
    }

    func jumpToLive() {
        window.jumpToLive()
    }

    func jumpToOldest() {
        window.jumpToOldest()
    }

    func indexOfMessage(eventId: String) -> Int? {
        messages.firstIndex { $0.eventId == eventId }
    }

    // MARK: - Reply

    func setReplyTarget(_ message: ChatMessage?) {
        replyingTo = message
    }

    // MARK: - Actions

    func sendMessage(_ text: String) {
        if let replyTarget = replyingTo, let eventId = replyTarget.eventId {
            replyingTo = nil
            Task { await timelineService.sendReply(text, to: eventId) }
        } else {
            Task { await timelineService.sendMessage(text) }
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
        hiddenIds.insert(messageId)
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages.remove(at: idx)
        onTableUpdate?(.batch(
            deletions: [IndexPath(row: idx, section: 0)],
            insertions: [],
            updates: [],
            animated: false
        ))
    }

    func cleanup() {
        PresenceTracker.shared.unregister(for: "chat")
        timelineService.onDiffs = nil
        diffBatcher.onFlush = nil
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
