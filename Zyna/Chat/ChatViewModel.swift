//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Combine
import GRDB
import MatrixRustSDK

final class ChatViewModel {

    // MARK: - State

    private(set) var messages: [ChatMessage] = []
    @Published private(set) var isPaginating: Bool = false

    /// True when SDK backward pagination returned no new visible
    /// messages, meaning we've likely reached the room history start.
    /// Prevents infinite batch-fetch loops when all remaining events
    /// are filtered (call signaling, redacted, etc.).
    var sdkPaginationExhausted = false
    @Published private(set) var replyingTo: ChatMessage?
    @Published private(set) var pendingForwardContent: (preview: ChatMessage, content: RoomMessageEventContentWithoutRelation)?
    @Published private(set) var isInvited: Bool = false

    /// Called on the main queue when the table needs updating.
    var onTableUpdate: ((TableUpdate) -> Void)?

    /// Called for lightweight in-place cell updates (e.g. send-status change)
    /// that don't require cell recreation. Index path → updated message.
    var onInPlaceUpdate: ((IndexPath, ChatMessage) -> Void)?

    /// Called when messages become redacted (from any source). Passes message IDs.
    var onRedactedDetected: (([String]) -> Void)?

    /// Called when a redaction request fails.
    var onRedactionFailed: ((String, Error) -> Void)?

    let roomName: String
    @Published private(set) var partnerPresence: UserPresence?
    @Published private(set) var partnerUserId: String?
    @Published private(set) var memberCount: Int?
    @Published private(set) var isGroupChat: Bool = false
    @Published private(set) var searchState: ChatSearchState?

    // MARK: - Coordinator callback
    var onBack: (() -> Void)?

    // MARK: - Private

    let timelineService: TimelineService
    private let diffBatcher: TimelineDiffBatcher
    private let window: MessageWindow
    private let room: Room
    private let roomId: String
    private var hiddenIds = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    private var directUserId: String?
    private var historySyncTask: Task<Void, Never>?
    private var readReceiptWork: DispatchWorkItem?

    /// Whether the window is at the live edge (newest messages visible).
    var isAtLiveEdge: Bool { window.isAtLiveEdge }

    init(room: Room) {
        let roomId = room.id()
        self.room = room
        self.roomId = roomId
        self.roomName = room.displayName() ?? "Chat"
        self.isInvited = room.membership() == .invited
        self.timelineService = TimelineService(room: room)
        self.diffBatcher = TimelineDiffBatcher(
            roomId: roomId,
            dbQueue: DatabaseService.shared.dbQueue
        )
        self.window = MessageWindow(
            roomId: roomId,
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
        timelineService.onReadCursor = { timestamp in
            batcher.updateReadCursor(timestamp: timestamp)
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

        // Defer timeline setup until invite is accepted
        if !isInvited {
            startTimelineAndHistory()
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
                    self.isGroupChat = true
                }
            }
        }
    }

    // MARK: - Timeline Bootstrap

    private func startTimelineAndHistory() {
        window.loadInitial()

        Task { [weak self] in
            await self?.timelineService.startListening()
        }

        historySyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.syncFullHistory()
        }
    }

    // MARK: - Invite

    func acceptInvite() {
        guard isInvited else { return }
        Task {
            do {
                try await room.join()
                await MainActor.run { [weak self] in
                    self?.isInvited = false
                }
                startTimelineAndHistory()
            } catch {
                ScopedLog(.rooms)("Failed to accept invite: \(error)")
            }
        }
    }

    // MARK: - Window Change Handling

    private func handleObservationChange(newStored: [StoredMessage], prevStored: [StoredMessage]?) {
        // 1. Detect newly redacted user messages (paint splash).
        //    Only for content that was a visible message — not call
        //    signaling carriers (zero-width-space body), system
        //    notices, or unsupported event types.
        let splashContentTypes: Set<String> = ["text", "image", "voice", "file", "emote"]
        let newlyRedactedIds: [String]
        if let prevStored {
            let prevById = Dictionary(prevStored.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            newlyRedactedIds = newStored.compactMap { msg in
                guard msg.contentType == "redacted" else { return nil }
                guard let prev = prevById[msg.id],
                      prev.contentType != "redacted",
                      splashContentTypes.contains(prev.contentType)
                else { return nil }
                // Skip carrier messages stored as "text" with an
                // invisible body (call signaling, future extensions).
                if prev.contentType == "text" {
                    let body = prev.contentBody ?? ""
                    let visible = body
                        .replacingOccurrences(of: "\u{200B}", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if visible.isEmpty { return nil }
                }
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

        let rawMessages = displayStored.compactMap { $0.toChatMessage() }
        let newMessages = Self.decorateClusters(
            rawMessages,
            olderBoundary: window.peekOlderNeighbor(),
            newerBoundary: window.peekNewerNeighbor()
        )

        // 3. Prefetch images
        Self.prefetchImages(newMessages)

        // 4. Compute table update
        let oldMessages = self.messages
        self.messages = newMessages

        let tableUpdate: TableUpdate
        var inPlaceUpdates: [(IndexPath, ChatMessage)] = []
        if prevStored == nil {
            tableUpdate = .reload
        } else {
            (tableUpdate, inPlaceUpdates) = Self.computeTableUpdate(old: oldMessages, new: newMessages)
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

        // 6. Apply lightweight in-place updates (send-status) without cell recreation
        for (indexPath, message) in inPlaceUpdates {
            onInPlaceUpdate?(indexPath, message)
        }

        // 7. Send read receipt when at live edge (user sees latest messages)
        if window.isAtLiveEdge {
            sendReadReceiptThrottled()
        }

        // 8. Auto-paginate if too few messages and GRDB + SDK both need more
        if newMessages.count < 20 && !isPaginating && !window.hasOlderInDB {
            loadOlderFromServer()
        }
    }

    /// Stable key for diff comparison. Uses eventId (server-assigned,
    /// immutable) when available; falls back to id (SDK uniqueId) for
    /// local echoes that don't have an eventId yet.
    private static func stableKey(_ msg: ChatMessage) -> String {
        msg.eventId ?? msg.id
    }

    private static func computeTableUpdate(old: [ChatMessage], new: [ChatMessage]) -> (TableUpdate, [(IndexPath, ChatMessage)]) {
        let oldKeys = old.map { stableKey($0) }
        let newKeys = new.map { stableKey($0) }
        let keyDiff = newKeys.difference(from: oldKeys)

        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var removedOldOffsets = Set<Int>()

        for change in keyDiff {
            switch change {
            case .remove(let offset, _, _):
                deletions.append(IndexPath(row: offset, section: 0))
                removedOldOffsets.insert(offset)
            case .insert(let offset, _, _):
                insertions.append(IndexPath(row: offset, section: 0))
            }
        }

        let newByKey = Dictionary(new.enumerated().map { (stableKey($1), $0) }, uniquingKeysWith: { _, last in last })
        var fullUpdates: [IndexPath] = []
        var inPlaceUpdates: [(IndexPath, ChatMessage)] = []

        for (oldIdx, oldMsg) in old.enumerated() {
            guard !removedOldOffsets.contains(oldIdx) else { continue }
            guard let newIdx = newByKey[stableKey(oldMsg)], old[oldIdx] != new[newIdx] else { continue }
            if MessageCellNode.canUpdateInPlace(old: old[oldIdx], new: new[newIdx]) {
                inPlaceUpdates.append((IndexPath(row: newIdx, section: 0), new[newIdx]))
            } else {
                fullUpdates.append(IndexPath(row: oldIdx, section: 0))
            }
        }

        let animated = deletions.isEmpty && insertions.count == 1 && fullUpdates.isEmpty
        let batch = TableUpdate.batch(deletions: deletions, insertions: insertions, updates: fullUpdates, animated: animated)
        return (batch, inPlaceUpdates)
    }

    // MARK: - Pagination

    /// Load older messages from GRDB. Returns true if data was available.
    func loadOlderFromDB() -> Bool {
        window.loadOlder()
    }

    /// Query-only part of older-page load. Safe to call from any
    /// thread; returns merged+sorted rows or nil when exhausted.
    /// Caller is expected to pair this with `applyOlderPageFromDB`
    /// on the main thread.
    func queryOlderFromDB() -> MessageWindow.OlderPage? {
        window.queryOlder()
    }

    /// Main-thread apply step paired with `queryOlderFromDB`.
    func applyOlderPageFromDB(_ page: MessageWindow.OlderPage) {
        window.applyOlder(page)
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
        sendReadReceiptThrottled()
    }

    func jumpToOldest() {
        window.jumpToOldest()
    }

    func indexOfMessage(eventId: String) -> Int? {
        messages.firstIndex { $0.eventId == eventId }
    }

    // MARK: - Read Receipts

    /// Debounced read receipt — avoids spamming the server when
    /// multiple diffs arrive in quick succession.
    private func sendReadReceiptThrottled() {
        readReceiptWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { await self?.timelineService.markAsRead() }
        }
        readReceiptWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Reply

    func setReplyTarget(_ message: ChatMessage?) {
        replyingTo = message
    }

    func setPendingForward(preview: ChatMessage, content: RoomMessageEventContentWithoutRelation) {
        pendingForwardContent = (preview, content)
    }

    func clearPendingForward() {
        pendingForwardContent = nil
    }

    // MARK: - Actions

    func sendMessage(_ text: String, color: UIColor? = nil) {
        // Forward takes priority
        if let forward = pendingForwardContent {
            pendingForwardContent = nil
            let senderName = forward.preview.senderDisplayName ?? forward.preview.senderId
            let attrs = ZynaMessageAttributes(forwardedFrom: senderName)

            if let body = forward.preview.content.textBody {
                Task { await timelineService.sendMessage(body, zynaAttributes: attrs) }
            } else if let mediaInfo = forward.preview.content.mediaForwardInfo {
                let caption = text.isEmpty ? nil : text
                Task { await timelineService.forwardMedia(
                    source: mediaInfo.source,
                    mimetype: mediaInfo.mimetype,
                    attrs: attrs,
                    caption: caption
                )}
            } else {
                // Fallback: send without attributes
                Task { await timelineService.sendForwardedContent(forward.content) }
            }
            return
        }

        if let replyTarget = replyingTo, let eventId = replyTarget.eventId {
            replyingTo = nil
            Task { await timelineService.sendReply(text, to: eventId) }
            return
        }

        if let color {
            let attrs = ZynaMessageAttributes(color: color)
            Task { await timelineService.sendMessage(text, zynaAttributes: attrs) }
            return
        }

        Task { await timelineService.sendMessage(text) }
    }

    func sendVoiceMessage(fileURL: URL, duration: TimeInterval, waveform: [Float]) {
        Task {
            await timelineService.sendVoiceMessage(url: fileURL, duration: duration, waveform: waveform)
            // Suspected mitigation: SDK returns the SendHandle before
            // the upload finishes; immediate delete may race with the
            // async read. Was observed on short (~0.2s) and occasional
            // longer recordings. If voice messages still go missing,
            // the root cause may be deeper in the SDK send queue.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func sendFile(url: URL) {
        Task {
            await timelineService.sendFile(url: url)
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

    // MARK: - Search

    func activateSearch() {
        searchState = ChatSearchState()
    }

    func deactivateSearch() {
        searchState = nil
    }

    func updateSearchQuery(_ text: String) {
        guard searchState != nil else { return }
        searchState?.query = text

        guard !text.isEmpty else {
            searchState?.results = []
            searchState?.currentIndex = 0
            return
        }

        let rid = roomId
        let pattern = "%\(text)%"
        let results: [ChatSearchResult] = (try? DatabaseService.shared.dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == rid)
                .filter(Column("contentBody").like(pattern))
                .order(Column("timestamp").desc)
                .fetchAll(db)
                .compactMap { msg -> ChatSearchResult? in
                    guard let eventId = msg.eventId, let body = msg.contentBody else { return nil }
                    return ChatSearchResult(eventId: eventId, body: body)
                }
        }) ?? []

        searchState?.results = results
        searchState?.currentIndex = 0
    }

    func nextSearchResult() {
        guard var state = searchState, !state.results.isEmpty else { return }
        state.currentIndex = (state.currentIndex + 1) % state.results.count
        searchState = state
    }

    func previousSearchResult() {
        guard var state = searchState, !state.results.isEmpty else { return }
        state.currentIndex = (state.currentIndex - 1 + state.results.count) % state.results.count
        searchState = state
    }

    func cleanup() {
        historySyncTask?.cancel()
        PresenceTracker.shared.unregister(for: "chat")
        timelineService.onDiffs = nil
        diffBatcher.onFlush = nil
        timelineService.stopListening()
    }

    // MARK: - Background History Sync

    private func syncFullHistory() async {
        while !Task.isCancelled {
            let countBefore = storedMessageCount()
            await timelineService.paginateBackwards(numEvents: 50)
            // Wait for batcher debounce (50ms) + margin
            try? await Task.sleep(for: .milliseconds(150))
            let countAfter = storedMessageCount()
            if countAfter <= countBefore { break }
        }
    }

    private func storedMessageCount() -> Int {
        let rid = roomId
        return (try? DatabaseService.shared.dbQueue.read { db in
            try StoredMessage
                .filter(Column("roomId") == rid)
                .fetchCount(db)
        }) ?? 0
    }

    // MARK: - Cluster Decoration

    /// Same-sender messages within this gap share a cluster; beyond it
    /// the cluster breaks even without a sender change. Same threshold
    /// for DM and group — a long pause means a new "take" either way.
    private static let clusterGap: TimeInterval = 10 * 60

    /// Assigns isFirstInCluster / isLastInCluster. A cluster breaks on
    /// sender change, a gap > clusterGap, or a call event between.
    ///
    /// Array is newest → oldest (table is inverted). "First in cluster"
    /// is the visually top bubble — the OLDER one, higher-index.
    ///
    /// `olderBoundary` / `newerBoundary` are phantom rows just outside
    /// the window, fetched from GRDB. Needed after window trim or
    /// jumpTo, where both edges are artificial cuts.
    private static func decorateClusters(
        _ messages: [ChatMessage],
        olderBoundary: ClusterNeighbor?,
        newerBoundary: ClusterNeighbor?
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        var result = messages

        for i in 0..<result.count {
            let current = result[i]
            if case .callEvent = current.content {
                result[i].isFirstInCluster = true
                result[i].isLastInCluster = true
                continue
            }
            // Array is newest-first: prev index = newer, next = older.
            let newerInArray = i > 0 ? neighbor(from: result[i - 1]) : newerBoundary
            let olderInArray = i + 1 < result.count ? neighbor(from: result[i + 1]) : olderBoundary
            result[i].isFirstInCluster = isClusterBoundary(current: current, neighbor: olderInArray)
            result[i].isLastInCluster = isClusterBoundary(current: current, neighbor: newerInArray)
        }
        return result
    }

    private static func neighbor(from message: ChatMessage) -> ClusterNeighbor {
        let isCall: Bool
        if case .callEvent = message.content { isCall = true } else { isCall = false }
        return ClusterNeighbor(
            senderId: message.senderId,
            timestamp: message.timestamp,
            isCallEvent: isCall
        )
    }

    private static func isClusterBoundary(current: ChatMessage, neighbor: ClusterNeighbor?) -> Bool {
        guard let neighbor else { return true }
        if neighbor.isCallEvent { return true }
        if neighbor.senderId != current.senderId { return true }
        let gap = abs(current.timestamp.timeIntervalSince(neighbor.timestamp))
        return gap > clusterGap
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
