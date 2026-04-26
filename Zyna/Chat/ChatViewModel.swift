//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Combine
import GRDB
import UniformTypeIdentifiers
import MatrixRustSDK

private let logMediaGroup = ScopedLog(.media, prefix: "[MediaGroup]")

final class ChatViewModel {

    struct DetectedRedactedMediaGroup {
        let groupId: String
        let redactedMessageIds: Set<String>
        let allMessageIds: Set<String>
        let totalCount: Int
        let remainingCountAfter: Int
    }

    struct DetectedRedactionBatch {
        let messageIds: [String]
        let mediaGroups: [DetectedRedactedMediaGroup]
    }

    private struct PartialReflowPreview {
        let identity: String
        let imageData: Data
    }

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

    /// Called when messages become redacted (from any source).
    /// Includes grouped media metadata for receiver-side coalescing.
    var onRedactedDetected: ((DetectedRedactionBatch) -> Void)?

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
    private let outgoingEnvelopes = OutgoingEnvelopeService.shared
    private let room: Room
    private let roomId: String
    private var hiddenIds = Set<String>()
    private var pendingPartialRedactions: [String: StoredMessage] = [:]
    private var partialReflowPreviewsByMessageId: [String: PartialReflowPreview] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var directUserId: String?
    private var historySyncTask: Task<Void, Never>?
    private var readReceiptWork: DispatchWorkItem?

    /// Whether the window is at the live edge (newest messages visible).
    var isAtLiveEdge: Bool { window.isAtLiveEdge }
    var hasOlderInDB: Bool { window.hasOlderInDB }

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
        timelineService.onSendQueueUpdate = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.window.refresh()
            }
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
        sdkPaginationExhausted = false
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
        let redactionBatch: DetectedRedactionBatch
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
            redactionBatch = Self.detectedRedactionBatch(
                newlyRedactedIds: newlyRedactedIds,
                newStored: newStored,
                prevStored: prevStored,
                prevById: prevById
            )
        } else {
            newlyRedactedIds = []
            redactionBatch = DetectedRedactionBatch(messageIds: [], mediaGroups: [])
        }

        Self.registerPendingPartialRedactions(
            into: &pendingPartialRedactions,
            newStored: newStored,
            prevStored: prevStored,
            newlyRedactedIds: newlyRedactedIds,
            hiddenIds: hiddenIds
        )
        Self.prunePartialReflowPreviews(
            in: &partialReflowPreviewsByMessageId,
            newStored: newStored
        )

        // 2. Build display array: filter hidden and already-redacted (keep newly-redacted for animation)
        let newlyRedactedSet = Set(newlyRedactedIds)
        let displayStored = newStored.compactMap { msg -> StoredMessage? in
            if hiddenIds.contains(msg.id) { return nil }
            if let pending = pendingPartialRedactions[msg.id] {
                return pending
            }
            if msg.contentType == "redacted" && !newlyRedactedSet.contains(msg.id) { return nil }
            return msg
        }

        let deletedMediaGroupIds = Self.redactedMediaGroupIds(in: newStored)
        if !deletedMediaGroupIds.isEmpty || !newlyRedactedIds.isEmpty {
            logMediaGroup(
                "deleteReflow observation newlyRedacted=\(newlyRedactedIds.joined(separator: ",")) deletedGroups=\(deletedMediaGroupIds.sorted().joined(separator: ",")) hidden=\(hiddenIds.count)"
            )
        }
        let rawMessages = displayStored.compactMap { $0.toChatMessage() }
        let newMessages = buildRenderableMessages(
            from: rawMessages,
            deletedMediaGroupIds: deletedMediaGroupIds,
            partialReflowPreviewsByMessageId: partialReflowPreviewsByMessageId,
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
            if case .batch(let del, let ins, let moves, let upd, let anim) = tableUpdate {
                let filtered = upd.filter { ip in
                    guard ip.row < newMessages.count else { return true }
                    return !newMessages[ip.row].content.isRedacted
                }
                onTableUpdate?(.batch(
                    deletions: del,
                    insertions: ins,
                    moves: moves,
                    updates: filtered,
                    animated: anim
                ))
            } else {
                onTableUpdate?(tableUpdate)
            }
            onRedactedDetected?(redactionBatch)
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

        // Any materialized older rows in GRDB mean backward pagination
        // is not exhausted, even if a previous server round finished late.
        if window.hasOlderInDB {
            sdkPaginationExhausted = false
        }

        // 8. Auto-paginate if too few messages and GRDB + SDK both need more
        if newMessages.count < 20 && !isPaginating && !window.hasOlderInDB {
            loadOlderFromServer()
        }
    }

    /// Stable key for diff comparison. Uses eventId (server-assigned,
    /// immutable) or transactionId (local echo carried onto the synced
    /// row) when available; falls back to id (SDK uniqueId) otherwise.
    private static func stableKey(_ msg: ChatMessage) -> String {
        if let presentation = msg.mediaGroupPresentation {
            if presentation.rendersCompositeBubble {
                return "media-group:\(presentation.id):composite"
            }
            if presentation.hidesStandaloneBubble,
               let mediaGroup = msg.zynaAttributes.mediaGroup {
                return "media-group:\(presentation.id):hidden:\(mediaGroup.index)"
            }
        }
        return msg.transactionId ?? msg.eventId ?? msg.id
    }

    private func buildRenderableMessages(
        from rawMessages: [ChatMessage],
        deletedMediaGroupIds: Set<String>,
        partialReflowPreviewsByMessageId: [String: PartialReflowPreview],
        olderBoundary: ClusterNeighbor?,
        newerBoundary: ClusterNeighbor?
    ) -> [ChatMessage] {
        let envelopes = outgoingEnvelopes.envelopes(roomId: roomId)
        if !envelopes.isEmpty {
            logMediaGroup(
                "render pending groups room=\(roomId) \(envelopes.map(Self.describe).joined(separator: "; "))"
            )
        }
        let currentUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        let mediaBatchPlan = Self.pendingRenderableMediaGroupPlan(
            from: envelopes.filter { $0.kind == .mediaBatch },
            rawMessages: rawMessages,
            currentUserId: currentUserId
        )
        let singleEnvelopePlan = Self.pendingRenderableSingleEnvelopePlan(
            from: envelopes.filter { $0.kind != .mediaBatch },
            rawMessages: rawMessages,
            currentUserId: currentUserId
        )
        let incomingAssemblyPlan = Self.incomingRenderableMediaGroupPlan(
            from: rawMessages,
            deletedMediaGroupIds: deletedMediaGroupIds,
            olderBoundary: olderBoundary,
            newerBoundary: newerBoundary
        )
        let envelopeIdsToRetire = mediaBatchPlan.retireEnvelopeIds.union(singleEnvelopePlan.retireEnvelopeIds)
        if !envelopeIdsToRetire.isEmpty {
            outgoingEnvelopes.deleteEnvelopes(ids: envelopeIdsToRetire)
        }

        let renderableMessages = Self.mergeRawMessages(
            rawMessages,
            with: mediaBatchPlan.activeEnvelopes
                + singleEnvelopePlan.activeEnvelopes
                + incomingAssemblyPlan.activeEnvelopes
        )

        return Self.buildDisplayMessages(
            from: renderableMessages,
            deletedMediaGroupIds: deletedMediaGroupIds,
            partialReflowPreviewsByMessageId: partialReflowPreviewsByMessageId,
            olderBoundary: olderBoundary,
            newerBoundary: newerBoundary
        )
    }

    func registerPartialReflowPreviews(_ previews: [String: Data]) {
        guard !previews.isEmpty else { return }
        for (messageId, imageData) in previews {
            partialReflowPreviewsByMessageId[messageId] = PartialReflowPreview(
                identity: "partial-reflow:\(messageId):\(UUID().uuidString)",
                imageData: imageData
            )
        }
    }

    func registerPendingAnimatedRedactions(_ messageIds: [String]) {
        guard !messageIds.isEmpty else { return }
        let storedById = Dictionary(
            window.currentStoredMessages().map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        for messageId in messageIds {
            guard pendingPartialRedactions[messageId] == nil,
                  let stored = storedById[messageId]
            else {
                continue
            }
            pendingPartialRedactions[messageId] = stored
        }
    }

    func clearPendingAnimatedRedactions(_ messageIds: [String]) {
        guard !messageIds.isEmpty else { return }
        for messageId in messageIds {
            pendingPartialRedactions.removeValue(forKey: messageId)
        }
    }

    func areMessagesRedacted(_ messageIds: [String]) -> Bool {
        guard !messageIds.isEmpty else { return false }
        let storedById = Dictionary(
            window.currentStoredMessages().map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        return messageIds.allSatisfy { storedById[$0]?.contentType == "redacted" }
    }

    private struct PendingRenderableEnvelope {
        let envelopeId: String
        let message: ChatMessage
        let anchorIndex: Int?
        let hiddenMessageIndices: Set<Int>
    }

    private struct PendingRenderableEnvelopePlan {
        let activeEnvelopes: [PendingRenderableEnvelope]
        let retireEnvelopeIds: Set<String>
    }

    private struct PendingMediaGroupObservedState {
        let primaryMessageIndexByItemIndex: [Int: Int]
        let hiddenMessageIndices: Set<Int>
        let syncedEventIndices: [Int: Int]
        let hasTransactionOnlyMessages: Bool
    }

    private struct PendingSingleEnvelopeObservedState {
        let primaryMessageIndex: Int?
        let hiddenMessageIndices: Set<Int>
        let hasTransactionOnlyMessages: Bool
    }

    private static func pendingRenderableMediaGroupPlan(
        from pendingGroups: [OutgoingEnvelopeSnapshot],
        rawMessages: [ChatMessage],
        currentUserId: String
    ) -> PendingRenderableEnvelopePlan {
        guard !pendingGroups.isEmpty else {
            return PendingRenderableEnvelopePlan(activeEnvelopes: [], retireEnvelopeIds: [])
        }

        var activeEnvelopes: [PendingRenderableEnvelope] = []
        var retireEnvelopeIds = Set<String>()

        for group in pendingGroups {
            let observedState = mediaGroupObservedState(for: group, in: rawMessages)
            let isFullyHydrated = isFullyHydrated(group: group, observedState: observedState)

            if isFullyHydrated {
                logMediaGroup("pending hydrated group=\(describe(group))")
                retireEnvelopeIds.insert(group.id)
                continue
            }

            let renderGroup = makeRenderablePendingMediaGroupEnvelope(
                group,
                observedState: observedState,
                rawMessages: rawMessages,
                currentUserId: currentUserId
            )
            activeEnvelopes.append(renderGroup)
        }

        return PendingRenderableEnvelopePlan(
            activeEnvelopes: activeEnvelopes,
            retireEnvelopeIds: retireEnvelopeIds
        )
    }

    private static func pendingRenderableSingleEnvelopePlan(
        from envelopes: [OutgoingEnvelopeSnapshot],
        rawMessages: [ChatMessage],
        currentUserId: String
    ) -> PendingRenderableEnvelopePlan {
        guard !envelopes.isEmpty else {
            return PendingRenderableEnvelopePlan(activeEnvelopes: [], retireEnvelopeIds: [])
        }

        var activeEnvelopes: [PendingRenderableEnvelope] = []
        var retireEnvelopeIds = Set<String>()

        for envelope in envelopes {
            let observedState = singleEnvelopeObservedState(for: envelope, in: rawMessages)
            if isFullyHydrated(envelope: envelope, observedState: observedState, rawMessages: rawMessages) {
                logMediaGroup("pending hydrated envelope=\(describe(envelope))")
                retireEnvelopeIds.insert(envelope.id)
                continue
            }

            let renderableEnvelope = makeRenderablePendingEnvelope(
                envelope,
                observedState: observedState,
                rawMessages: rawMessages,
                currentUserId: currentUserId
            )
            activeEnvelopes.append(renderableEnvelope)
        }

        return PendingRenderableEnvelopePlan(
            activeEnvelopes: activeEnvelopes,
            retireEnvelopeIds: retireEnvelopeIds
        )
    }

    private static func incomingRenderableMediaGroupPlan(
        from rawMessages: [ChatMessage],
        deletedMediaGroupIds: Set<String>,
        olderBoundary: ClusterNeighbor?,
        newerBoundary: ClusterNeighbor?
    ) -> PendingRenderableEnvelopePlan {
        guard !rawMessages.isEmpty else {
            return PendingRenderableEnvelopePlan(activeEnvelopes: [], retireEnvelopeIds: [])
        }

        var activeEnvelopes: [PendingRenderableEnvelope] = []
        var index = 0

        while index < rawMessages.count {
            guard !rawMessages[index].isOutgoing,
                  case .image = rawMessages[index].content,
                  let mediaGroup = rawMessages[index].zynaAttributes.mediaGroup
            else {
                index += 1
                continue
            }

            let runStart = index
            var runEnd = index

            while runEnd + 1 < rawMessages.count,
                  sharesMediaGroup(rawMessages[runEnd], rawMessages[runEnd + 1]) {
                runEnd += 1
            }

            defer { index = runEnd + 1 }

            guard mediaGroup.total > 1,
                  !deletedMediaGroupIds.contains(mediaGroup.id)
            else {
                continue
            }

            let sharesWithNewerBoundary = runStart == 0
                && sharesMediaGroup(rawMessages[runStart], newerBoundary)
            let sharesWithOlderBoundary = runEnd == rawMessages.count - 1
                && sharesMediaGroup(rawMessages[runEnd], olderBoundary)

            guard !sharesWithNewerBoundary,
                  !sharesWithOlderBoundary
            else {
                continue
            }

            let visibleMessages = Array(rawMessages[runStart...runEnd])
            guard visibleMessages.count < mediaGroup.total else {
                continue
            }

            let anchorIndex = mediaGroup.captionPlacement == .top ? runEnd : runStart
            let hiddenMessageIndices = Set(runStart...runEnd)
            let anchorMessage = rawMessages[anchorIndex]
            let body = incomingAssemblyPlaceholderBody(
                visibleCount: visibleMessages.count,
                totalCount: mediaGroup.total
            )

            var message = ChatMessage(
                id: "incoming-assembly:\(mediaGroup.id)",
                eventId: nil,
                transactionId: nil,
                itemIdentifier: nil,
                senderId: anchorMessage.senderId,
                senderDisplayName: anchorMessage.senderDisplayName,
                senderAvatarUrl: anchorMessage.senderAvatarUrl,
                isOutgoing: false,
                timestamp: anchorMessage.timestamp,
                content: .notice(body: body),
                reactions: [],
                replyInfo: nil,
                zynaAttributes: ZynaMessageAttributes(),
                sendStatus: "sent"
            )
            message.incomingAssemblyId = mediaGroup.id

            logMediaGroup(
                "incoming assembly group=\(mediaGroup.id) visible=\(visibleMessages.count) total=\(mediaGroup.total) anchor=\(anchorIndex)"
            )

            activeEnvelopes.append(
                PendingRenderableEnvelope(
                    envelopeId: "incoming-assembly:\(mediaGroup.id)",
                    message: message,
                    anchorIndex: anchorIndex,
                    hiddenMessageIndices: hiddenMessageIndices
                )
            )
        }

        return PendingRenderableEnvelopePlan(
            activeEnvelopes: activeEnvelopes,
            retireEnvelopeIds: []
        )
    }

    private static func mediaGroupObservedState(
        for group: OutgoingEnvelopeSnapshot,
        in messages: [ChatMessage]
    ) -> PendingMediaGroupObservedState {
        let eventIndexById = Dictionary(
            uniqueKeysWithValues: group.items.compactMap { item in
                item.eventId.map { ($0, item.itemIndex) }
            }
        )
        let transactionIndexById = Dictionary(
            uniqueKeysWithValues: group.items.compactMap { item in
                item.transactionId.map { ($0, item.itemIndex) }
            }
        )

        var primaryMessageIndexByItemIndex: [Int: Int] = [:]
        var hiddenMessageIndices = Set<Int>()
        var syncedEventIndices: [Int: Int] = [:]
        var hasTransactionOnlyMessages = false

        for (messageIndex, message) in messages.enumerated() {
            guard message.isOutgoing,
                  case .image = message.content
            else {
                continue
            }

            let relatedItemIndex = message.eventId.flatMap { eventIndexById[$0] }
                ?? message.transactionId.flatMap { transactionIndexById[$0] }
                ?? pendingMediaGroupItemIndex(of: message, in: group)

            if let relatedItemIndex {
                hiddenMessageIndices.insert(messageIndex)
                let previousIndex = primaryMessageIndexByItemIndex[relatedItemIndex]
                if previousIndex == nil
                    || prefersPendingPrimaryCandidate(
                        messages[messageIndex],
                        over: messages[previousIndex!]
                    ) {
                    primaryMessageIndexByItemIndex[relatedItemIndex] = messageIndex
                }
            }

            if message.eventId == nil,
               relatedItemIndex != nil {
                hasTransactionOnlyMessages = true
            }

            if let mediaGroup = message.zynaAttributes.mediaGroup,
               message.eventId != nil,
               mediaGroup.id == group.id,
               mediaGroup.index >= 0,
               mediaGroup.index < group.expectedItemCount,
               mediaGroup.total == group.expectedItemCount,
               mediaGroup.captionMode == .replicated,
               mediaGroup.captionPlacement == group.captionPlacement,
               mediaGroup.layoutOverride == group.mediaBatchPayload?.layoutOverride {
                let previousIndex = syncedEventIndices[mediaGroup.index]
                if previousIndex == nil
                    || prefersPendingPrimaryCandidate(
                        messages[messageIndex],
                        over: messages[previousIndex!]
                    ) {
                    syncedEventIndices[mediaGroup.index] = messageIndex
                }
            }
        }

        return PendingMediaGroupObservedState(
            primaryMessageIndexByItemIndex: primaryMessageIndexByItemIndex,
            hiddenMessageIndices: hiddenMessageIndices,
            syncedEventIndices: syncedEventIndices,
            hasTransactionOnlyMessages: hasTransactionOnlyMessages
        )
    }

    private static func pendingMediaGroupItemIndex(
        of message: ChatMessage,
        in group: OutgoingEnvelopeSnapshot
    ) -> Int? {
        guard let mediaGroup = message.zynaAttributes.mediaGroup,
              mediaGroup.id == group.id,
              mediaGroup.total == group.expectedItemCount,
              mediaGroup.captionMode == .replicated,
              mediaGroup.captionPlacement == group.captionPlacement,
              mediaGroup.layoutOverride == group.mediaBatchPayload?.layoutOverride
        else {
            return nil
        }
        return mediaGroup.index
    }

    private static func prefersPendingPrimaryCandidate(
        _ candidate: ChatMessage,
        over current: ChatMessage
    ) -> Bool {
        if (candidate.eventId != nil) != (current.eventId != nil) {
            return candidate.eventId != nil
        }

        let candidateHasGroup = candidate.zynaAttributes.mediaGroup != nil
        let currentHasGroup = current.zynaAttributes.mediaGroup != nil
        if candidateHasGroup != currentHasGroup {
            return candidateHasGroup
        }

        let candidateIsRead = candidate.sendStatus == "read"
        let currentIsRead = current.sendStatus == "read"
        if candidateIsRead != currentIsRead {
            return candidateIsRead
        }

        return candidate.timestamp >= current.timestamp
    }

    private static func isFullyHydrated(
        group: OutgoingEnvelopeSnapshot,
        observedState: PendingMediaGroupObservedState
    ) -> Bool {
        guard !observedState.hasTransactionOnlyMessages else { return false }
        guard observedState.syncedEventIndices.count == group.expectedItemCount else { return false }
        let expectedIndices = Set(0..<group.expectedItemCount)
        return Set(observedState.syncedEventIndices.keys) == expectedIndices
    }

    private static func makeRenderablePendingMediaGroupEnvelope(
        _ group: OutgoingEnvelopeSnapshot,
        observedState: PendingMediaGroupObservedState,
        rawMessages: [ChatMessage],
        currentUserId: String
    ) -> PendingRenderableEnvelope {
        let primaryMessagesByItemIndex: [Int: ChatMessage] = Dictionary(
            uniqueKeysWithValues: observedState.primaryMessageIndexByItemIndex.compactMap { itemIndex, messageIndex in
                guard rawMessages.indices.contains(messageIndex) else { return nil }
                return (itemIndex, rawMessages[messageIndex])
            }
        )

        let mediaItems = group.items.map { item -> MediaGroupItem in
            let primaryMessage = primaryMessagesByItemIndex[item.itemIndex]
            let primaryImageContent: (source: MediaSource?, width: UInt64?, height: UInt64?, caption: String?)? = {
                guard let primaryMessage,
                      case .image(let source, let width, let height, let caption, _) = primaryMessage.content else {
                    return nil
                }
                return (source, width, height, caption)
            }()

            return MediaGroupItem(
                messageId: primaryMessage?.id ?? item.id,
                eventId: item.eventId ?? primaryMessage?.eventId,
                transactionId: item.transactionId ?? primaryMessage?.transactionId,
                source: item.mediaSource ?? primaryImageContent?.source,
                previewImageData: item.previewImageData,
                previewIdentity: Self.pendingMediaPreviewIdentity(
                    groupId: group.id,
                    itemIndex: item.itemIndex
                ),
                width: item.previewWidth ?? primaryImageContent?.width,
                height: item.previewHeight ?? primaryImageContent?.height,
                caption: group.caption ?? primaryImageContent?.caption,
                sendStatus: item.transportState.messageSendStatus
            )
        }

        let anchorIndex: Int? = {
            let indices = Array(observedState.primaryMessageIndexByItemIndex.values)
            guard !indices.isEmpty else { return nil }
            return group.captionPlacement == .top ? indices.min() : indices.max()
        }()

        let anchorMessage = anchorIndex.flatMap { rawMessages.indices.contains($0) ? rawMessages[$0] : nil }
        let sendStatus = aggregatePendingMediaGroupSendStatus(from: mediaItems)
        let layoutOverride = group.mediaBatchPayload?.layoutOverride
        let presentation = MediaGroupPresentation(
            id: group.id,
            position: group.captionPlacement == .top ? .top : .bottom,
            totalHint: group.expectedItemCount,
            caption: group.caption,
            captionPlacement: group.captionPlacement,
            layoutOverride: layoutOverride,
            suppressIndividualCaption: group.caption != nil,
            items: mediaItems,
            rendersCompositeBubble: true,
            hidesStandaloneBubble: false
        )
        var message = ChatMessage(
            id: "pending-media-group:\(group.id)",
            eventId: nil,
            transactionId: nil,
            itemIdentifier: nil,
            senderId: anchorMessage?.senderId ?? currentUserId,
            senderDisplayName: anchorMessage?.senderDisplayName,
            senderAvatarUrl: anchorMessage?.senderAvatarUrl,
            isOutgoing: true,
            timestamp: anchorMessage?.timestamp ?? group.createdAt,
            content: .pendingOutgoingMediaBatch,
            reactions: [],
            replyInfo: group.replyInfo,
            zynaAttributes: ZynaMessageAttributes(),
            sendStatus: sendStatus
        )
        message.mediaGroupPresentation = presentation
        message.outgoingEnvelopeId = group.id

        logMediaGroup(
            "pending synthetic group=\(describe(group)) anchor=\(anchorIndex.map(String.init) ?? "nil") hidden=\(observedState.hiddenMessageIndices.count) status=\(sendStatus)"
        )

        return PendingRenderableEnvelope(
            envelopeId: group.id,
            message: message,
            anchorIndex: anchorIndex,
            hiddenMessageIndices: observedState.hiddenMessageIndices
        )
    }

    private static func singleEnvelopeObservedState(
        for envelope: OutgoingEnvelopeSnapshot,
        in messages: [ChatMessage]
    ) -> PendingSingleEnvelopeObservedState {
        let eventIds = Set(envelope.items.compactMap(\.eventId))
        let transactionIds = Set(envelope.items.compactMap(\.transactionId))

        var primaryMessageIndex: Int?
        var hiddenMessageIndices = Set<Int>()
        var hasTransactionOnlyMessages = false

        for (messageIndex, message) in messages.enumerated() {
            guard message.isOutgoing,
                  matches(envelopeKind: envelope.kind, message: message)
            else {
                continue
            }

            let isRelated = message.eventId.map { eventIds.contains($0) } == true
                || message.transactionId.map { transactionIds.contains($0) } == true
            guard isRelated else { continue }

            hiddenMessageIndices.insert(messageIndex)
            if let currentPrimaryIndex = primaryMessageIndex {
                if prefersPendingPrimaryCandidate(message, over: messages[currentPrimaryIndex]) {
                    primaryMessageIndex = messageIndex
                }
            } else {
                primaryMessageIndex = messageIndex
            }

            if message.eventId == nil {
                hasTransactionOnlyMessages = true
            }
        }

        return PendingSingleEnvelopeObservedState(
            primaryMessageIndex: primaryMessageIndex,
            hiddenMessageIndices: hiddenMessageIndices,
            hasTransactionOnlyMessages: hasTransactionOnlyMessages
        )
    }

    private static func matches(envelopeKind: OutgoingEnvelopeKind, message: ChatMessage) -> Bool {
        switch (envelopeKind, message.content) {
        case (.text, .text):
            return true
        case (.image, .image):
            return true
        case (.voice, .voice):
            return true
        case (.file, .file):
            return true
        default:
            return false
        }
    }

    private static func isFullyHydrated(
        envelope: OutgoingEnvelopeSnapshot,
        observedState: PendingSingleEnvelopeObservedState,
        rawMessages: [ChatMessage]
    ) -> Bool {
        guard !observedState.hasTransactionOnlyMessages,
              let primaryMessageIndex = observedState.primaryMessageIndex,
              rawMessages.indices.contains(primaryMessageIndex)
        else {
            return false
        }

        let primaryMessage = rawMessages[primaryMessageIndex]
        guard primaryMessage.eventId != nil else { return false }
        return hydratedMessage(primaryMessage, matches: envelope)
    }

    private static func hydratedMessage(
        _ message: ChatMessage,
        matches envelope: OutgoingEnvelopeSnapshot
    ) -> Bool {
        guard replyEventId(of: envelope.replyInfo) == replyEventId(of: message.replyInfo),
              message.zynaAttributes == envelope.zynaAttributes
        else {
            return false
        }

        switch envelope.payload {
        case .text(let textPayload):
            guard case .text(let body) = message.content else { return false }
            return body == textPayload.body
        case .image(let imagePayload):
            guard case .image(let source, let width, let height, let caption, _) = message.content,
                  source != nil
            else {
                return false
            }
            return normalized(caption) == normalized(imagePayload.caption)
                && dimensionsMatch(expected: imagePayload.width, actual: width)
                && dimensionsMatch(expected: imagePayload.height, actual: height)
        case .voice(let voicePayload):
            guard case .voice(let source, let duration, _) = message.content,
                  source != nil
            else {
                return false
            }
            return abs(duration - voicePayload.duration) < 0.5
        case .file(let filePayload):
            guard case .file(let source, let filename, let mimetype, let size, let caption) = message.content,
                  source != nil
            else {
                return false
            }
            return filename == filePayload.filename
                && normalized(caption) == normalized(filePayload.caption)
                && (filePayload.mimetype == nil || mimetype == filePayload.mimetype)
                && (filePayload.size == nil || size == filePayload.size)
        case .mediaBatch:
            return false
        }
    }

    private static func makeRenderablePendingEnvelope(
        _ envelope: OutgoingEnvelopeSnapshot,
        observedState: PendingSingleEnvelopeObservedState,
        rawMessages: [ChatMessage],
        currentUserId: String
    ) -> PendingRenderableEnvelope {
        let primaryMessage = observedState.primaryMessageIndex.flatMap {
            rawMessages.indices.contains($0) ? rawMessages[$0] : nil
        }
        let primaryContent = primaryMessage?.content
        let primaryTimestamp = primaryMessage?.timestamp ?? envelope.createdAt
        let primarySenderId = primaryMessage?.senderId ?? currentUserId
        let sendStatus = pendingSendStatus(
            transportState: envelope.primaryItem?.transportState,
            hydratedMessage: primaryMessage
        )

        let content: ChatMessageContent = {
            switch envelope.payload {
            case .text(let payload):
                return .text(body: payload.body)
            case .image(let payload):
                let primarySource: MediaSource?
                let primaryWidth: UInt64?
                let primaryHeight: UInt64?
                let primaryCaption: String?
                if case .image(let source, let width, let height, let caption, _) = primaryContent {
                    primarySource = source
                    primaryWidth = width
                    primaryHeight = height
                    primaryCaption = caption
                } else {
                    primarySource = nil
                    primaryWidth = nil
                    primaryHeight = nil
                    primaryCaption = nil
                }
                return .image(
                    source: envelope.primaryItem?.mediaSource ?? primarySource,
                    width: envelope.primaryItem?.previewWidth ?? payload.width ?? primaryWidth,
                    height: envelope.primaryItem?.previewHeight ?? payload.height ?? primaryHeight,
                    caption: payload.caption ?? primaryCaption,
                    previewImageData: envelope.primaryItem?.previewImageData
                )
            case .voice(let payload):
                let primarySource: MediaSource?
                if case .voice(let source, _, _) = primaryContent {
                    primarySource = source
                } else {
                    primarySource = nil
                }
                return .voice(
                    source: envelope.primaryItem?.mediaSource ?? primarySource,
                    duration: payload.duration,
                    waveform: payload.waveform
                )
            case .file(let payload):
                let primarySource: MediaSource?
                let primaryCaption: String?
                if case .file(let source, _, _, _, let caption) = primaryContent {
                    primarySource = source
                    primaryCaption = caption
                } else {
                    primarySource = nil
                    primaryCaption = nil
                }
                return .file(
                    source: envelope.primaryItem?.mediaSource ?? primarySource,
                    filename: payload.filename,
                    mimetype: payload.mimetype,
                    size: payload.size,
                    caption: payload.caption ?? primaryCaption
                )
            case .mediaBatch:
                return .pendingOutgoingMediaBatch
            }
        }()

        var message = ChatMessage(
            id: "outgoing-envelope:\(envelope.id)",
            eventId: nil,
            transactionId: nil,
            itemIdentifier: nil,
            senderId: primarySenderId,
            senderDisplayName: primaryMessage?.senderDisplayName,
            senderAvatarUrl: primaryMessage?.senderAvatarUrl,
            isOutgoing: true,
            timestamp: primaryTimestamp,
            content: content,
            reactions: [],
            replyInfo: envelope.replyInfo,
            zynaAttributes: envelope.zynaAttributes,
            sendStatus: sendStatus
        )
        message.outgoingEnvelopeId = envelope.id

        logMediaGroup(
            "pending synthetic envelope=\(describe(envelope)) anchor=\(observedState.primaryMessageIndex.map(String.init) ?? "nil") hidden=\(observedState.hiddenMessageIndices.count) status=\(sendStatus)"
        )

        return PendingRenderableEnvelope(
            envelopeId: envelope.id,
            message: message,
            anchorIndex: observedState.primaryMessageIndex,
            hiddenMessageIndices: observedState.hiddenMessageIndices
        )
    }

    private static func pendingSendStatus(
        transportState: OutgoingTransportState?,
        hydratedMessage: ChatMessage?
    ) -> String {
        if hydratedMessage?.sendStatus == "read" {
            return "read"
        }
        return transportState?.messageSendStatus ?? "queued"
    }

    private static func replyEventId(of replyInfo: ReplyInfo?) -> String? {
        replyInfo?.eventId
    }

    private static func normalized(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dimensionsMatch(expected: UInt64?, actual: UInt64?) -> Bool {
        expected == nil || actual == nil || expected == actual
    }

    private static func aggregatePendingMediaGroupSendStatus(from items: [MediaGroupItem]) -> String {
        let statuses = items.map(\.sendStatus)
        if statuses.contains("failed") {
            return "failed"
        }
        if statuses.contains(where: { ["queued", "sending", "retrying"].contains($0) }) {
            return "sending"
        }
        if !statuses.isEmpty, statuses.allSatisfy({ $0 == "read" }) {
            return "read"
        }
        if statuses.contains(where: { ["sent", "synced", "read"].contains($0) }) {
            return "sent"
        }
        return "queued"
    }

    private static func incomingAssemblyPlaceholderBody(
        visibleCount: Int,
        totalCount: Int
    ) -> String {
        "Receiving \(visibleCount) of \(totalCount) photos"
    }

    private static func mergeRawMessages(
        _ rawMessages: [ChatMessage],
        with pendingGroups: [PendingRenderableEnvelope]
    ) -> [ChatMessage] {
        guard !pendingGroups.isEmpty else { return rawMessages }

        let hiddenIndices = Set(pendingGroups.flatMap(\.hiddenMessageIndices))
        let anchoredGroups = Dictionary(
            grouping: pendingGroups.compactMap { group in
                group.anchorIndex.map { ($0, group) }
            },
            by: \.0
        ).mapValues { pairs in
            pairs.map(\.1).sorted { $0.message.timestamp > $1.message.timestamp }
        }

        var result: [ChatMessage] = []
        result.reserveCapacity(rawMessages.count + pendingGroups.count)

        for (index, message) in rawMessages.enumerated() {
            if let groups = anchoredGroups[index] {
                result.append(contentsOf: groups.map(\.message))
            }
            if hiddenIndices.contains(index) {
                continue
            }
            result.append(message)
        }

        let unanchoredGroups = pendingGroups
            .filter { $0.anchorIndex == nil }
            .sorted { $0.message.timestamp > $1.message.timestamp }
            .map(\.message)

        for message in unanchoredGroups {
            if let insertionIndex = result.firstIndex(where: { $0.timestamp <= message.timestamp }) {
                result.insert(message, at: insertionIndex)
            } else {
                result.append(message)
            }
        }

        return result
    }

    private static func computeTableUpdate(old: [ChatMessage], new: [ChatMessage]) -> (TableUpdate, [(IndexPath, ChatMessage)]) {
        let oldKeys = old.map { stableKey($0) }
        let newKeys = new.map { stableKey($0) }
        let keyDiff = newKeys.difference(from: oldKeys)

        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var removedOldOffsets = Set<Int>()
        let moves: [(from: IndexPath, to: IndexPath)] = []

        for change in keyDiff {
            switch change {
            case .remove(let offset, _, let associatedWith):
                if associatedWith != nil { continue }
                deletions.append(IndexPath(row: offset, section: 0))
                removedOldOffsets.insert(offset)
            case .insert(let offset, _, let associatedWith):
                if associatedWith != nil {
                    continue
                }
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

        let animated = deletions.isEmpty && insertions.count == 1 && moves.isEmpty && fullUpdates.isEmpty
        let batch = TableUpdate.batch(
            deletions: deletions,
            insertions: insertions,
            moves: moves,
            updates: fullUpdates,
            animated: animated
        )
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
        sdkPaginationExhausted = false
        window.applyOlder(page)
    }

    /// Paginate from server when GRDB is exhausted.
    func loadOlderFromServer() {
        guard !isPaginating else { return }
        Task {
            await timelineService.paginateBackwards(numEvents: 50)
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
        sdkPaginationExhausted = false
        window.jumpToLive()
        sendReadReceiptThrottled()
    }

    func jumpToOldest() {
        sdkPaginationExhausted = false
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

    private func refreshWindow() async {
        await MainActor.run {
            self.window.refresh()
        }
    }

    private func replyInfo(from message: ChatMessage?) -> ReplyInfo? {
        guard let message,
              let eventId = message.eventId else {
            return nil
        }
        return ReplyInfo(
            eventId: eventId,
            senderId: message.senderId,
            senderDisplayName: message.senderDisplayName,
            body: message.content.textPreview
        )
    }

    private func completeOutgoingDispatch(
        envelopeId: String,
        itemIndex: Int = 0,
        receipt: OutgoingDispatchReceipt
    ) async {
        if !receipt.acceptedByTransport {
            guard outgoingEnvelopes.markDispatchFailed(
                envelopeId: envelopeId,
                itemIndex: itemIndex
            ) else {
                return
            }
            await refreshWindow()
            return
        }

        let didMarkStarted = outgoingEnvelopes.markDispatchStarted(
            envelopeId: envelopeId,
            itemIndex: itemIndex
        )

        guard let transactionId = receipt.transactionId,
              outgoingEnvelopes.bindTransaction(
                envelopeId: envelopeId,
                itemIndex: itemIndex,
                transactionId: transactionId
              ) else {
            if didMarkStarted {
                await refreshWindow()
            }
            return
        }
        await refreshWindow()
    }

    private func sendOutgoingText(
        body: String,
        replyEventId: String? = nil,
        replyInfo: ReplyInfo? = nil,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes()
    ) async {
        let envelopeId = UUID().uuidString
        let bindingToken = outgoingEnvelopes.createOutgoingText(
            roomId: roomId,
            envelopeId: envelopeId,
            body: body,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes
        )
        await refreshWindow()

        let receipt: OutgoingDispatchReceipt
        if let replyEventId {
            receipt = await timelineService.sendReply(
                body,
                to: replyEventId,
                bindingToken: bindingToken
            )
        } else if zynaAttributes.isEmpty {
            receipt = await timelineService.sendMessage(
                body,
                bindingToken: bindingToken
            )
        } else {
            receipt = await timelineService.sendMessage(
                body,
                zynaAttributes: zynaAttributes,
                bindingToken: bindingToken
            )
        }

        await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)
    }

    private func sendOutgoingVoice(
        fileURL: URL,
        duration: TimeInterval,
        waveform: [Float]
    ) async {
        let envelopeId = UUID().uuidString
        let waveformPayload = waveform.map { sample -> UInt16 in
            let normalized = max(0, min(1, sample))
            return UInt16((normalized * 1024).rounded())
        }
        let bindingToken = outgoingEnvelopes.createOutgoingVoice(
            roomId: roomId,
            envelopeId: envelopeId,
            duration: duration,
            waveform: waveformPayload,
            replyInfo: nil
        )
        await refreshWindow()

        let receipt = await timelineService.sendVoiceMessage(
            url: fileURL,
            duration: duration,
            waveform: waveform,
            bindingToken: bindingToken
        )
        await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func sendOutgoingFile(
        url: URL,
        caption: String?,
        replyEventId: String?,
        replyInfo: ReplyInfo?
    ) async {
        let filename = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: url.path
        )[.size] as? UInt64) ?? 0
        let mimetype: String?
        if let utType = UTType(filenameExtension: url.pathExtension),
           let preferred = utType.preferredMIMEType {
            mimetype = preferred
        } else {
            mimetype = "application/octet-stream"
        }

        let envelopeId = UUID().uuidString
        let bindingToken = outgoingEnvelopes.createOutgoingFile(
            roomId: roomId,
            envelopeId: envelopeId,
            filename: filename,
            mimetype: mimetype,
            size: fileSize,
            caption: caption,
            replyInfo: replyInfo
        )
        await refreshWindow()

        let receipt = await timelineService.sendFile(
            url: url,
            caption: caption,
            replyEventId: replyEventId,
            bindingToken: bindingToken
        )
        await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)
    }

    private func sendOutgoingForwardedMedia(
        preview: ChatMessage,
        fallbackContent: RoomMessageEventContentWithoutRelation,
        attrs: ZynaMessageAttributes,
        caption: String?
    ) async {
        let envelopeId = UUID().uuidString

        switch preview.content {
        case .image(let source, let width, let height, _, let previewImageData):
            guard let source,
                  let mediaInfo = preview.content.mediaForwardInfo else {
                await timelineService.sendForwardedContent(fallbackContent)
                return
            }
            let bindingToken = outgoingEnvelopes.createOutgoingImage(
                roomId: roomId,
                envelopeId: envelopeId,
                caption: caption,
                width: width,
                height: height,
                previewImageData: previewImageData,
                previewSource: source,
                replyInfo: nil,
                zynaAttributes: attrs
            )
            await refreshWindow()
            let receipt = await timelineService.forwardMedia(
                source: source,
                mimetype: mediaInfo.mimetype,
                attrs: attrs,
                caption: caption,
                bindingToken: bindingToken
            )
            await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)
        case .voice(let source, let duration, let waveform):
            guard let source,
                  let mediaInfo = preview.content.mediaForwardInfo else {
                await timelineService.sendForwardedContent(fallbackContent)
                return
            }
            let bindingToken = outgoingEnvelopes.createOutgoingVoice(
                roomId: roomId,
                envelopeId: envelopeId,
                duration: duration,
                waveform: waveform,
                replyInfo: nil,
                zynaAttributes: attrs
            )
            await refreshWindow()
            let receipt = await timelineService.forwardVoiceMessage(
                source: source,
                mimetype: mediaInfo.mimetype,
                duration: duration,
                waveform: waveform,
                attrs: attrs,
                caption: caption,
                bindingToken: bindingToken
            )
            await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)
        case .file(let source, let filename, let mimetype, let size, _):
            guard let source,
                  let mediaInfo = preview.content.mediaForwardInfo else {
                await timelineService.sendForwardedContent(fallbackContent)
                return
            }
            let bindingToken = outgoingEnvelopes.createOutgoingFile(
                roomId: roomId,
                envelopeId: envelopeId,
                filename: filename,
                mimetype: mimetype,
                size: size,
                caption: caption,
                replyInfo: nil,
                zynaAttributes: attrs
            )
            await refreshWindow()
            let receipt = await timelineService.forwardMedia(
                source: source,
                mimetype: mediaInfo.mimetype,
                attrs: attrs,
                caption: caption,
                bindingToken: bindingToken
            )
            await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)
        default:
            await timelineService.sendForwardedContent(fallbackContent)
        }
    }

    func sendMessage(_ text: String, color: UIColor? = nil) {
        // Forward takes priority
        if let forward = pendingForwardContent {
            pendingForwardContent = nil
            let senderName = forward.preview.senderDisplayName ?? forward.preview.senderId
            let attrs = ZynaMessageAttributes(forwardedFrom: senderName)

            if let body = forward.preview.content.textBody {
                Task { [weak self] in
                    await self?.sendOutgoingText(body: body, zynaAttributes: attrs)
                }
            } else if forward.preview.content.mediaForwardInfo != nil {
                let caption = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
                Task { [weak self] in
                    await self?.sendOutgoingForwardedMedia(
                        preview: forward.preview,
                        fallbackContent: forward.content,
                        attrs: attrs,
                        caption: caption
                    )
                }
            } else {
                // Fallback: send without attributes
                Task { await timelineService.sendForwardedContent(forward.content) }
            }
            return
        }

        if let replyTarget = replyingTo, let eventId = replyTarget.eventId {
            replyingTo = nil
            let replyInfo = replyInfo(from: replyTarget)
            Task { [weak self] in
                await self?.sendOutgoingText(
                    body: text,
                    replyEventId: eventId,
                    replyInfo: replyInfo
                )
            }
            return
        }

        if let color {
            let attrs = ZynaMessageAttributes(color: color)
            Task { [weak self] in
                await self?.sendOutgoingText(body: text, zynaAttributes: attrs)
            }
            return
        }

        Task { [weak self] in
            await self?.sendOutgoingText(body: text)
        }
    }

    func sendVoiceMessage(fileURL: URL, duration: TimeInterval, waveform: [Float]) {
        Task { [weak self] in
            await self?.sendOutgoingVoice(
                fileURL: fileURL,
                duration: duration,
                waveform: waveform
            )
        }
    }

    func sendFile(url: URL) {
        Task { [weak self] in
            await self?.sendOutgoingFile(
                url: url,
                caption: nil,
                replyEventId: nil,
                replyInfo: nil
            )
        }
    }

    func sendImages(
        _ images: [ProcessedImage],
        caption: String?,
        captionPlacement: CaptionPlacement = .bottom,
        layoutOverride: MediaGroupLayoutOverride? = nil
    ) {
        Task { [weak self] in
            guard let self else { return }
            await self.sendImageBatch(
                images,
                caption: caption,
                captionPlacement: captionPlacement,
                layoutOverride: layoutOverride,
                replyEventId: nil,
                replyInfo: nil
            )
        }
    }

    func sendComposerAttachments(
        _ attachments: [ChatComposerAttachmentDraft],
        caption: String?,
        captionPlacement: CaptionPlacement = .bottom,
        layoutOverride: MediaGroupLayoutOverride? = nil
    ) {
        guard !attachments.isEmpty else { return }

        let replyTarget = replyingTo
        let replyEventId = replyTarget?.eventId
        replyingTo = nil
        pendingForwardContent = nil

        let imageAttachments = attachments.compactMap { attachment -> ProcessedImage? in
            guard case .image(let image) = attachment.payload else { return nil }
            return image
        }
        let hasOnlyImages = imageAttachments.count == attachments.count
        let replyInfo = replyInfo(from: replyTarget)

        if hasOnlyImages {
            Task { [weak self] in
                guard let self else { return }
                await self.sendImageBatch(
                    imageAttachments,
                    caption: caption,
                    captionPlacement: captionPlacement,
                    layoutOverride: layoutOverride,
                    replyEventId: replyEventId,
                    replyInfo: replyInfo
                )
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            for (index, attachment) in attachments.enumerated() {
                let attachmentCaption = (index == 0) ? caption : nil
                switch attachment.payload {
                case .image(let image):
                    await self.sendSingleImage(
                        image,
                        caption: attachmentCaption,
                        replyEventId: replyEventId,
                        replyInfo: replyInfo,
                        zynaAttributes: ZynaMessageAttributes()
                    )
                case .file(let url):
                    await self.sendOutgoingFile(
                        url: url,
                        caption: attachmentCaption,
                        replyEventId: replyEventId,
                        replyInfo: replyInfo
                    )
                }
            }
        }
    }

    private func sendSingleImage(
        _ image: ProcessedImage,
        caption: String?,
        replyEventId: String?,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes
    ) async {
        let envelopeId = UUID().uuidString
        let bindingToken = outgoingEnvelopes.createOutgoingImage(
            roomId: roomId,
            envelopeId: envelopeId,
            caption: caption,
            width: image.width,
            height: image.height,
            previewImageData: image.imageData,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes
        )
        await refreshWindow()

        let receipt = await timelineService.sendImage(
            imageData: image.imageData,
            width: image.width,
            height: image.height,
            caption: caption,
            zynaAttributes: zynaAttributes,
            replyEventId: replyEventId,
            bindingToken: bindingToken
        )
        await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)
    }

    private func normalizedCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func singleImageAttributes(
        imageCount: Int,
        captionPlacement: CaptionPlacement
    ) -> ZynaMessageAttributes {
        let needsCaptionPlacementMetadata = captionPlacement != .bottom
        guard imageCount > 1 || needsCaptionPlacementMetadata else {
            return ZynaMessageAttributes()
        }
        return ZynaMessageAttributes(
            mediaGroup: MediaGroupInfo(
                id: UUID().uuidString,
                index: 0,
                total: imageCount,
                captionMode: .replicated,
                captionPlacement: captionPlacement
            )
        )
    }

    private static func pendingMediaPreviewIdentity(groupId: String, itemIndex: Int) -> String {
        "pending:\(groupId):\(itemIndex)"
    }

    private func prewarmVisibleMediaBatchPreviewTiles(
        groupId: String,
        images: [ProcessedImage],
        layoutOverride: MediaGroupLayoutOverride?
    ) async {
        guard !images.isEmpty else { return }

        let visibleCount = min(images.count, PhotoGroupLayout.maxVisibleItems)
        guard visibleCount > 0 else { return }

        let primaryAspectRatio: CGFloat? = {
            guard let first = images.first,
                  first.height > 0 else {
                return nil
            }
            return CGFloat(first.width) / CGFloat(first.height)
        }()

        let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        let mediaHeight = PhotoGroupLayout.preferredMediaHeight(
            for: maxWidth,
            itemCount: images.count,
            primaryAspectRatio: primaryAspectRatio
        )
        let slotFrames = PhotoGroupLayout.frames(
            in: CGRect(x: 0, y: 0, width: maxWidth, height: mediaHeight),
            itemCount: images.count,
            layoutOverride: layoutOverride
        )
        let scale = ScreenConstants.scale

        await withTaskGroup(of: Void.self) { group in
            for (index, image) in images.prefix(visibleCount).enumerated() {
                guard slotFrames.indices.contains(index) else { continue }
                let slotFrame = slotFrames[index]
                let maxPixelWidth = max(1, Int(round(slotFrame.width * scale)))
                let maxPixelHeight = max(1, Int(round(slotFrame.height * scale)))
                let previewIdentity = Self.pendingMediaPreviewIdentity(
                    groupId: groupId,
                    itemIndex: index
                )

                group.addTask {
                    _ = await MediaCache.shared.loadPreviewBubbleImage(
                        previewIdentity: previewIdentity,
                        imageData: image.imageData,
                        maxPixelWidth: maxPixelWidth,
                        maxPixelHeight: maxPixelHeight
                    )
                }
            }
        }
    }

    private func sendImageBatch(
        _ images: [ProcessedImage],
        caption: String?,
        captionPlacement: CaptionPlacement,
        layoutOverride: MediaGroupLayoutOverride?,
        replyEventId: String?,
        replyInfo: ReplyInfo?
    ) async {
        guard !images.isEmpty else { return }

        let normalizedCaption = normalizedCaption(caption)

        if images.count == 1, let image = images.first {
            let attrs = singleImageAttributes(
                imageCount: 1,
                captionPlacement: captionPlacement
            )
            await sendSingleImage(
                image,
                caption: normalizedCaption,
                replyEventId: replyEventId,
                replyInfo: replyInfo,
                zynaAttributes: attrs
            )
            return
        }

        let mediaGroupId = UUID().uuidString

        logMediaGroup(
            "batch create group=\(mediaGroupId) items=\(images.count) captionPlacement=\(captionPlacement.rawValue) caption=\(normalizedCaption ?? "<nil>")"
        )
        await prewarmVisibleMediaBatchPreviewTiles(
            groupId: mediaGroupId,
            images: images,
            layoutOverride: layoutOverride
        )
        let bindingTokens = outgoingEnvelopes.createOutgoingMediaBatch(
            roomId: roomId,
            envelopeId: mediaGroupId,
            caption: normalizedCaption,
            captionPlacement: captionPlacement,
            layoutOverride: layoutOverride,
            items: images.map {
                OutgoingMediaDraftItem(
                    previewImageData: $0.imageData,
                    width: $0.width,
                    height: $0.height
                )
            },
            replyInfo: replyInfo
        )
        await refreshWindow()

        for (index, image) in images.enumerated() {
            guard bindingTokens.indices.contains(index) else { continue }
            let attrs = ZynaMessageAttributes(
                mediaGroup: MediaGroupInfo(
                    id: mediaGroupId,
                    index: index,
                    total: images.count,
                    captionMode: .replicated,
                    captionPlacement: captionPlacement,
                    layoutOverride: layoutOverride
                )
            )

            let receipt = await timelineService.sendImage(
                imageData: image.imageData,
                width: image.width,
                height: image.height,
                caption: normalizedCaption,
                zynaAttributes: attrs,
                replyEventId: replyEventId,
                bindingToken: bindingTokens[index]
            )
            await completeOutgoingDispatch(
                envelopeId: mediaGroupId,
                itemIndex: index,
                receipt: receipt
            )
        }
    }

    func toggleReaction(_ key: String, for message: ChatMessage) {
        guard let itemId = message.itemIdentifier else { return }
        Task {
            await timelineService.toggleReaction(key, to: itemId)
        }
    }

    func reactionSummaryEntries(for message: ChatMessage) async -> [ReactionSummaryEntry] {
        let currentUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        let flattened = message.reactions
            .flatMap { reaction in
                reaction.senders.map {
                    ReactionSummaryEntry(
                        id: "\(reaction.key)|\($0.userId)|\($0.timestamp)",
                        userId: $0.userId,
                        displayName: $0.userId,
                        timestamp: Date(timeIntervalSince1970: $0.timestamp),
                        reactionKey: reaction.key,
                        isOwn: $0.userId == currentUserId
                    )
                }
            }
            .sorted { $0.timestamp > $1.timestamp }

        guard !flattened.isEmpty else { return [] }

        let uniqueIds = Set(flattened.map(\.userId))
        var displayNames: [String: String] = [:]
        displayNames.reserveCapacity(uniqueIds.count)

        for userId in uniqueIds {
            let member = try? await room.member(userId: userId)
            displayNames[userId] = member?.displayName ?? userId
        }

        return flattened.map {
            ReactionSummaryEntry(
                id: $0.id,
                userId: $0.userId,
                displayName: displayNames[$0.userId] ?? $0.userId,
                timestamp: $0.timestamp,
                reactionKey: $0.reactionKey,
                isOwn: $0.isOwn
            )
        }
    }

    func redactMessage(_ message: ChatMessage) {
        guard let itemId = message.itemIdentifier else { return }
        redactItemIdentifier(itemId, messageId: message.id)
    }

    func redactMediaGroupItem(_ item: MediaGroupItem) {
        guard let itemId = item.itemIdentifier else { return }
        redactItemIdentifier(itemId, messageId: item.messageId)
    }

    func redactMediaGroupItems(_ items: [MediaGroupItem]) {
        let identifiableItems = items.filter { $0.itemIdentifier != nil }
        guard !identifiableItems.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for item in identifiableItems {
                    guard let itemId = item.itemIdentifier else { continue }
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.timelineService.redactEvent(itemId)
                        } catch {
                            await MainActor.run {
                                self.onRedactionFailed?(item.messageId, error)
                            }
                        }
                    }
                }
            }
        }
    }

    private func redactItemIdentifier(_ itemId: ChatItemIdentifier, messageId: String) {
        Task {
            do {
                try await timelineService.redactEvent(itemId)
            } catch {
                await MainActor.run {
                    onRedactionFailed?(messageId, error)
                }
            }
        }
    }

    func hideMessage(_ messageId: String) {
        hideMessages([messageId])
    }

    func hideMessages(_ messageIds: [String]) {
        let idsToHide = Set(messageIds)
        guard !idsToHide.isEmpty else { return }

        hiddenIds.formUnion(idsToHide)
        for messageId in idsToHide {
            pendingPartialRedactions.removeValue(forKey: messageId)
            partialReflowPreviewsByMessageId.removeValue(forKey: messageId)
        }
        let oldMessages = messages
        var visibleRedactedIds = Set(
            oldMessages
                .filter { $0.content.isRedacted }
                .map(\.id)
        )
        visibleRedactedIds.subtract(idsToHide)
        let displayStored = window.currentStoredMessages().filter { msg in
            if hiddenIds.contains(msg.id) { return false }
            if msg.contentType == "redacted" {
                return visibleRedactedIds.contains(msg.id)
            }
            return true
        }
        let deletedMediaGroupIds = Self.redactedMediaGroupIds(in: window.currentStoredMessages())
        logMediaGroup(
            "deleteReflow hide messageIds=\(idsToHide.sorted().joined(separator: ",")) visibleRedacted=\(visibleRedactedIds.sorted().joined(separator: ",")) deletedGroups=\(deletedMediaGroupIds.sorted().joined(separator: ","))"
        )
        let rawMessages = displayStored.compactMap { $0.toChatMessage() }
        let newMessages = buildRenderableMessages(
            from: rawMessages,
            deletedMediaGroupIds: deletedMediaGroupIds,
            partialReflowPreviewsByMessageId: partialReflowPreviewsByMessageId,
            olderBoundary: window.peekOlderNeighbor(),
            newerBoundary: window.peekNewerNeighbor()
        )
        messages = newMessages

        let (tableUpdate, inPlaceUpdates) = Self.computeTableUpdate(old: oldMessages, new: newMessages)
        onTableUpdate?(tableUpdate)
        for (indexPath, message) in inPlaceUpdates {
            onInPlaceUpdate?(indexPath, message)
        }
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
        timelineService.onSendQueueUpdate = nil
        diffBatcher.onFlush = nil
        timelineService.stopListening()
    }

    // MARK: - Background History Sync

    private func syncFullHistory() async {
        var stagnantBatchCount = 0
        while !Task.isCancelled {
            let countBefore = storedMessageCount()
            await timelineService.paginateBackwards(numEvents: 50)
            // Wait for batcher debounce (50ms) + margin
            try? await Task.sleep(for: .milliseconds(150))
            let countAfter = storedMessageCount()
            if countAfter <= countBefore {
                stagnantBatchCount += 1
                if stagnantBatchCount >= 3 { break }
            } else {
                stagnantBatchCount = 0
            }
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
    /// sender change, a gap > clusterGap, or a standalone event between.
    ///
    /// Array is newest → oldest (table is inverted). "First in cluster"
    /// is the visually top bubble — the OLDER one, higher-index.
    ///
    /// `olderBoundary` / `newerBoundary` are phantom rows just outside
    /// the currently loaded dataset, fetched from GRDB. They matter
    /// whenever an edge is an artificial cut, such as after `jumpTo`
    /// or while only part of history has been loaded this session.
    private static func decorateClusters(
        _ messages: [ChatMessage],
        olderBoundary: ClusterNeighbor?,
        newerBoundary: ClusterNeighbor?
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        var result = messages

        for i in 0..<result.count {
            let current = result[i]
            if current.content.isStandaloneEvent {
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
        return ClusterNeighbor(
            senderId: message.senderId,
            timestamp: message.timestamp,
            isStandaloneEvent: message.content.isStandaloneEvent,
            mediaGroupId: message.zynaAttributes.mediaGroup?.id
        )
    }

    private static func isClusterBoundary(current: ChatMessage, neighbor: ClusterNeighbor?) -> Bool {
        guard let neighbor else { return true }
        if neighbor.isStandaloneEvent { return true }
        if neighbor.senderId != current.senderId { return true }
        let gap = abs(current.timestamp.timeIntervalSince(neighbor.timestamp))
        return gap > clusterGap
    }

    private static func decorateMediaGroups(
        _ messages: [ChatMessage],
        deletedMediaGroupIds: Set<String>,
        partialReflowPreviewsByMessageId: [String: PartialReflowPreview],
        olderBoundary: ClusterNeighbor?,
        newerBoundary: ClusterNeighbor?
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        var result = messages
        var index = 0

        while index < result.count {
            guard case .image = result[index].content,
                  let mediaGroup = result[index].zynaAttributes.mediaGroup
            else {
                index += 1
                continue
            }

            let runStart = index
            var runEnd = index

            while runEnd + 1 < result.count,
                  sharesMediaGroup(result[runEnd], result[runEnd + 1]) {
                runEnd += 1
            }

            let sharesWithNewerBoundary = runStart == 0
                && sharesMediaGroup(result[runStart], newerBoundary)
            let sharesWithOlderBoundary = runEnd == result.count - 1
                && sharesMediaGroup(result[runEnd], olderBoundary)

            let runLength = runEnd - runStart + 1
            let isVisualGroup = runLength > 1 || sharesWithNewerBoundary || sharesWithOlderBoundary

            if isVisualGroup {
                let sourceMessages = Array(result[runStart...runEnd])
                let allowsDeletedReflow = deletedMediaGroupIds.contains(mediaGroup.id)
                let groupItems = mediaGroupItems(
                    from: sourceMessages,
                    partialReflowPreviewsByMessageId: partialReflowPreviewsByMessageId
                )
                let visibleCaptions = (runStart...runEnd).map { result[$0].content.visibleImageCaption }
                let captionCollapse = groupCaptionCollapse(from: visibleCaptions)
                let deduplicatedCaption = captionCollapse.caption
                let suppressIndividualCaption = captionCollapse.caption != nil
                let renderDecision =
                    mediaGroupRenderDecision(
                        messages: sourceMessages,
                        allowsDeletedReflow: allowsDeletedReflow,
                        sharesWithNewerBoundary: sharesWithNewerBoundary,
                        sharesWithOlderBoundary: sharesWithOlderBoundary,
                        canCollapseCaption: captionCollapse.canCollapse
                    )
                let canRenderCompositeBubble = renderDecision.canRender
                let isPartialDeletedReflow = canRenderCompositeBubble && allowsDeletedReflow && groupItems.count < mediaGroup.total
                let captionCarrierPosition: MediaGroupPosition = mediaGroup.captionPlacement == .top ? .top : .bottom
                logMediaGroup(
                    "decorate group=\(mediaGroup.id) run=\(runLength) total=\(mediaGroup.total) boundary[newer=\(sharesWithNewerBoundary),older=\(sharesWithOlderBoundary)] captionCollapse=\(captionCollapse.canCollapse) composite=\(canRenderCompositeBubble) reason=\(renderDecision.reason)"
                )
                if allowsDeletedReflow {
                    logMediaGroup(
                        "deleteReflow decorate group=\(mediaGroup.id) source=\(describeMediaGroupMessages(sourceMessages)) items=\(describeMediaGroupItems(groupItems)) partial=\(isPartialDeletedReflow) composite=\(canRenderCompositeBubble)"
                    )
                }

                if canRenderCompositeBubble {
                    if captionCarrierPosition == .bottom {
                        result[runStart].isFirstInCluster = result[runEnd].isFirstInCluster
                    } else {
                        result[runEnd].isLastInCluster = result[runStart].isLastInCluster
                    }
                }

                for currentIndex in runStart...runEnd {
                    let position: MediaGroupPosition
                    let hasNewerSibling = currentIndex > runStart || sharesWithNewerBoundary
                    let hasOlderSibling = currentIndex < runEnd || sharesWithOlderBoundary

                    if hasNewerSibling && hasOlderSibling {
                        position = .middle
                    } else if hasNewerSibling {
                        position = .top
                    } else {
                        position = .bottom
                    }

                    let caption = position == captionCarrierPosition ? deduplicatedCaption : nil
                    result[currentIndex].mediaGroupPresentation = MediaGroupPresentation(
                        id: mediaGroup.id,
                        position: position,
                        totalHint: isPartialDeletedReflow ? groupItems.count : mediaGroup.total,
                        caption: caption,
                        captionPlacement: mediaGroup.captionPlacement,
                        layoutOverride: isPartialDeletedReflow ? nil : mediaGroup.layoutOverride,
                        suppressIndividualCaption: suppressIndividualCaption,
                        items: (canRenderCompositeBubble && position == captionCarrierPosition) ? groupItems : [],
                        rendersCompositeBubble: canRenderCompositeBubble && position == captionCarrierPosition,
                        hidesStandaloneBubble: canRenderCompositeBubble && position != captionCarrierPosition
                    )
                }
            }

            index = runEnd + 1
        }

        return result
    }

    private static func buildDisplayMessages(
        from rawMessages: [ChatMessage],
        deletedMediaGroupIds: Set<String>,
        partialReflowPreviewsByMessageId: [String: PartialReflowPreview],
        olderBoundary: ClusterNeighbor?,
        newerBoundary: ClusterNeighbor?
    ) -> [ChatMessage] {
        let normalized = rawMessages.map { message -> ChatMessage in
            var copy = message
            copy.isFirstInCluster = true
            copy.isLastInCluster = true
            if case .pendingOutgoingMediaBatch = copy.content {
                // Sender-owned pending batches already carry their final
                // composite presentation and should not be rebuilt from
                // transport rows.
            } else {
                copy.mediaGroupPresentation = nil
            }
            return copy
        }

        let clusteredMessages = decorateClusters(
            normalized,
            olderBoundary: olderBoundary,
            newerBoundary: newerBoundary
        )

        return decorateMediaGroups(
            clusteredMessages,
            deletedMediaGroupIds: deletedMediaGroupIds,
            partialReflowPreviewsByMessageId: partialReflowPreviewsByMessageId,
            olderBoundary: olderBoundary,
            newerBoundary: newerBoundary
        ).filter { $0.mediaGroupPresentation?.hidesStandaloneBubble != true }
    }

    private static func sharesMediaGroup(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        guard case .image = lhs.content,
              case .image = rhs.content,
              lhs.senderId == rhs.senderId,
              let lhsGroup = lhs.zynaAttributes.mediaGroup,
              let rhsGroup = rhs.zynaAttributes.mediaGroup
        else {
            return false
        }
        return lhsGroup.id == rhsGroup.id
    }

    private static func sharesMediaGroup(_ message: ChatMessage, _ neighbor: ClusterNeighbor?) -> Bool {
        guard case .image = message.content,
              let groupId = message.zynaAttributes.mediaGroup?.id,
              let neighbor,
              neighbor.senderId == message.senderId
        else {
            return false
        }
        return neighbor.mediaGroupId == groupId
    }

    private static func isCompleteRenderableMediaGroup(
        messages: [ChatMessage],
        allowsDeletedReflow: Bool,
        sharesWithNewerBoundary: Bool,
        sharesWithOlderBoundary: Bool,
        canCollapseCaption: Bool
    ) -> Bool {
        mediaGroupRenderDecision(
            messages: messages,
            allowsDeletedReflow: allowsDeletedReflow,
            sharesWithNewerBoundary: sharesWithNewerBoundary,
            sharesWithOlderBoundary: sharesWithOlderBoundary,
            canCollapseCaption: canCollapseCaption
        ).canRender
    }

    private struct MediaGroupRenderDecision {
        let canRender: Bool
        let reason: String
    }

    private static func mediaGroupRenderDecision(
        messages: [ChatMessage],
        allowsDeletedReflow: Bool,
        sharesWithNewerBoundary: Bool,
        sharesWithOlderBoundary: Bool,
        canCollapseCaption: Bool
    ) -> MediaGroupRenderDecision {
        guard messages.count > 1,
              let firstGroup = messages.first?.zynaAttributes.mediaGroup
        else {
            if messages.count <= 1 { return MediaGroupRenderDecision(canRender: false, reason: "need>1") }
            return MediaGroupRenderDecision(canRender: false, reason: "missingFirstGroup")
        }

        guard !sharesWithNewerBoundary else {
            return MediaGroupRenderDecision(canRender: false, reason: "sharesNewerBoundary")
        }
        guard !sharesWithOlderBoundary else {
            return MediaGroupRenderDecision(canRender: false, reason: "sharesOlderBoundary")
        }
        guard canCollapseCaption else {
            return MediaGroupRenderDecision(canRender: false, reason: "captionMismatch")
        }
        let isPartialDeletedReflow = allowsDeletedReflow && messages.count < firstGroup.total
        guard isPartialDeletedReflow || firstGroup.total == messages.count else {
            return MediaGroupRenderDecision(
                canRender: false,
                reason: "countMismatch visible=\(messages.count) expected=\(firstGroup.total)"
            )
        }

        var seenIndices = Set<Int>()
        for message in messages {
            guard case .image = message.content,
                  let group = message.zynaAttributes.mediaGroup,
                  group.id == firstGroup.id,
                  group.total == firstGroup.total,
                  group.captionMode == firstGroup.captionMode,
                  group.captionPlacement == firstGroup.captionPlacement,
                  group.index >= 0,
                  group.index < group.total,
                  group.layoutOverride == firstGroup.layoutOverride,
                  seenIndices.insert(group.index).inserted
            else {
                return MediaGroupRenderDecision(canRender: false, reason: "inconsistentMember")
            }
        }

        guard seenIndices.count == messages.count else {
            return MediaGroupRenderDecision(
                canRender: false,
                reason: "uniqueIndexCountMismatch=\(seenIndices.count) visible=\(messages.count)"
            )
        }

        if !isPartialDeletedReflow {
            guard seenIndices.count == firstGroup.total else {
                return MediaGroupRenderDecision(
                    canRender: false,
                    reason: "uniqueIndexCountMismatch=\(seenIndices.count)"
                )
            }
            guard seenIndices.min() == 0 else {
                return MediaGroupRenderDecision(
                    canRender: false,
                    reason: "minIndex=\(seenIndices.min().map(String.init) ?? "nil")"
                )
            }
            guard seenIndices.max() == firstGroup.total - 1 else {
                return MediaGroupRenderDecision(
                    canRender: false,
                    reason: "maxIndex=\(seenIndices.max().map(String.init) ?? "nil") expected=\(firstGroup.total - 1)"
                )
            }
        } else {
            logMediaGroup(
                "deleteReflow decision group=\(firstGroup.id) visible=\(messages.count) total=\(firstGroup.total) indices=\(seenIndices.sorted().map(String.init).joined(separator: ","))"
            )
            return MediaGroupRenderDecision(
                canRender: true,
                reason: "redactedReflow visible=\(messages.count) expected=\(firstGroup.total)"
            )
        }

        return MediaGroupRenderDecision(canRender: true, reason: "complete")
    }

    private static func mediaGroupItems(
        from messages: [ChatMessage],
        partialReflowPreviewsByMessageId: [String: PartialReflowPreview]
    ) -> [MediaGroupItem] {
        messages
            .sorted {
                let lhsIndex = $0.zynaAttributes.mediaGroup?.index ?? .max
                let rhsIndex = $1.zynaAttributes.mediaGroup?.index ?? .max
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return $0.timestamp < $1.timestamp
            }
            .compactMap { message in
                guard case .image(let source, let width, let height, let caption, _) = message.content else {
                    return nil
                }
                return MediaGroupItem(
                    messageId: message.id,
                    eventId: message.eventId,
                    transactionId: message.transactionId,
                    source: source,
                    previewImageData: partialReflowPreviewsByMessageId[message.id]?.imageData,
                    previewIdentity: partialReflowPreviewsByMessageId[message.id]?.identity,
                    width: width,
                    height: height,
                    caption: caption,
                    sendStatus: message.sendStatus
                )
            }
    }

    private static func groupCaptionCollapse(from captions: [String?]) -> (caption: String?, canCollapse: Bool) {
        guard let first = captions.first else { return (nil, true) }
        let normalized = first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCaption = normalized?.isEmpty == false ? normalized : nil

        for caption in captions.dropFirst() {
            let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCurrent = trimmed?.isEmpty == false ? trimmed : nil
            if normalizedCurrent != normalizedCaption {
                return (nil, false)
            }
        }

        return (normalizedCaption, true)
    }

    private static func redactedMediaGroupIds(in storedMessages: [StoredMessage]) -> Set<String> {
        Set(
            storedMessages.compactMap { message in
                guard message.contentType == "redacted" else { return nil }
                return message.toChatMessage()?.zynaAttributes.mediaGroup?.id
            }
        )
    }

    private static func registerPendingPartialRedactions(
        into pendingPartialRedactions: inout [String: StoredMessage],
        newStored: [StoredMessage],
        prevStored: [StoredMessage]?,
        newlyRedactedIds: [String],
        hiddenIds: Set<String>
    ) {
        let existingIds = Set(newStored.map(\.id))
        pendingPartialRedactions = pendingPartialRedactions.filter {
            !hiddenIds.contains($0.key) && existingIds.contains($0.key)
        }

        guard let prevStored, !newlyRedactedIds.isEmpty else { return }

        let prevById = Dictionary(prevStored.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        for messageId in newlyRedactedIds {
            guard pendingPartialRedactions[messageId] == nil,
                  let previous = prevById[messageId],
                  previous.contentType == "image",
                  let mediaGroupId = previous.toChatMessage()?.zynaAttributes.mediaGroup?.id
            else {
                continue
            }
            pendingPartialRedactions[messageId] = previous
            logMediaGroup(
                "deleteReflow pending messageId=\(messageId) group=\(mediaGroupId)"
            )
        }
    }

    private static func liveImageCountByMediaGroup(in storedMessages: [StoredMessage]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for message in storedMessages {
            guard message.contentType == "image",
                  let mediaGroupId = message.toChatMessage()?.zynaAttributes.mediaGroup?.id
            else {
                continue
            }
            counts[mediaGroupId, default: 0] += 1
        }
        return counts
    }

    private static func prunePartialReflowPreviews(
        in previews: inout [String: PartialReflowPreview],
        newStored: [StoredMessage]
    ) {
        let liveIds = Set(
            newStored.compactMap { message in
                message.contentType == "image" ? message.id : nil
            }
        )
        previews = previews.filter { liveIds.contains($0.key) }
    }

    private static func detectedRedactionBatch(
        newlyRedactedIds: [String],
        newStored: [StoredMessage],
        prevStored: [StoredMessage],
        prevById: [String: StoredMessage]
    ) -> DetectedRedactionBatch {
        guard !newlyRedactedIds.isEmpty else {
            return DetectedRedactionBatch(messageIds: [], mediaGroups: [])
        }

        let remainingLiveCounts = liveImageCountByMediaGroup(in: newStored)
        var groupedMessageIds: [String: Set<String>] = [:]
        var groupedAllMessageIds: [String: Set<String>] = [:]
        var groupedTotals: [String: Int] = [:]
        var groupOrder: [String] = []

        for messageId in newlyRedactedIds {
            guard let previous = prevById[messageId],
                  previous.contentType == "image",
                  let mediaGroup = previous.toChatMessage()?.zynaAttributes.mediaGroup
            else {
                continue
            }

            if groupedMessageIds[mediaGroup.id] == nil {
                groupOrder.append(mediaGroup.id)
            }
            groupedMessageIds[mediaGroup.id, default: []].insert(messageId)
            groupedTotals[mediaGroup.id] = mediaGroup.total

            if groupedAllMessageIds[mediaGroup.id] == nil {
                let allMessageIds = Set(
                    prevStored.compactMap { stored -> String? in
                        guard stored.contentType == "image",
                              let groupId = stored.toChatMessage()?.zynaAttributes.mediaGroup?.id,
                              groupId == mediaGroup.id
                        else {
                            return nil
                        }
                        return stored.id
                    }
                )
                groupedAllMessageIds[mediaGroup.id] = allMessageIds
            }
        }

        let mediaGroups = groupOrder.compactMap { groupId -> DetectedRedactedMediaGroup? in
            guard let redactedMessageIds = groupedMessageIds[groupId],
                  let allMessageIds = groupedAllMessageIds[groupId],
                  let totalCount = groupedTotals[groupId]
            else {
                return nil
            }
            return DetectedRedactedMediaGroup(
                groupId: groupId,
                redactedMessageIds: redactedMessageIds,
                allMessageIds: allMessageIds,
                totalCount: totalCount,
                remainingCountAfter: remainingLiveCounts[groupId] ?? 0
            )
        }

        return DetectedRedactionBatch(
            messageIds: newlyRedactedIds,
            mediaGroups: mediaGroups
        )
    }

    private static func describe(_ group: OutgoingEnvelopeSnapshot) -> String {
        let items = group.items.map {
            "\($0.itemIndex):event=\($0.eventId ?? "-"),tx=\($0.transactionId ?? "-")"
        }.joined(separator: "|")
        return "\(group.id)[\(group.expectedItemCount)] placement=\(group.captionPlacement.rawValue) items=\(items)"
    }

    private static func describe(_ message: ChatMessage) -> String {
        let itemId = message.eventId ?? message.transactionId ?? message.id
        let group = message.zynaAttributes.mediaGroup.map {
            "\($0.id)#\($0.index + 1)/\($0.total)"
        } ?? "none"
        return "\(itemId) group=\(group) status=\(message.sendStatus)"
    }

    private static func describeMediaGroupMessages(_ messages: [ChatMessage]) -> String {
        messages.map { message in
            let itemId = message.eventId ?? message.transactionId ?? message.id
            let index = message.zynaAttributes.mediaGroup?.index ?? -1
            return "\(index):\(itemId):\(message.content.textPreview)"
        }.joined(separator: "|")
    }

    private static func describeMediaGroupItems(_ items: [MediaGroupItem]) -> String {
        items.enumerated().map { renderIndex, item in
            let itemId = item.eventId ?? item.transactionId ?? item.messageId
            return "\(renderIndex):\(itemId)"
        }.joined(separator: "|")
    }

    // MARK: - Prefetch

    private static func prefetchImages(_ messages: [ChatMessage]) {
        let maxPixelWidth = Int(
            round(ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio * ScreenConstants.scale)
        )
        let maxPixelHeight = Int(
            round(MessageCellHelpers.maxImageBubbleHeight * ScreenConstants.scale)
        )

        for message in messages {
            guard case .image(let source?, let width, let height, _, _) = message.content else { continue }
            guard MediaCache.shared.bubbleImage(
                for: source,
                maxPixelWidth: maxPixelWidth,
                maxPixelHeight: maxPixelHeight
            ) == nil else { continue }
            let knownAspectRatio: CGFloat?
            if let width, let height, height > 0 {
                knownAspectRatio = CGFloat(width) / CGFloat(height)
            } else {
                knownAspectRatio = nil
            }
            Task {
                await MediaCache.shared.loadBubbleImage(
                    source: source,
                    maxPixelWidth: maxPixelWidth,
                    maxPixelHeight: maxPixelHeight,
                    knownAspectRatio: knownAspectRatio
                )
            }
        }
    }
}
