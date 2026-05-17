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
private let logMessageEdit = ScopedLog(.timeline, prefix: "[MessageEdit]")
private let logVideoSend = ScopedLog(.video, prefix: "[VideoSend]")
private let timelineHealthLog = ScopedLog(.database, prefix: "[TimelineHealth]")

enum ChatPresentationMode {
    case normal
    case preview

    var isPreview: Bool {
        if case .preview = self { return true }
        return false
    }
}

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
        let identityKeys: Set<String>

        init(
            messageIds: [String],
            mediaGroups: [DetectedRedactedMediaGroup],
            identityKeys: Set<String> = []
        ) {
            self.messageIds = messageIds
            self.mediaGroups = mediaGroups
            self.identityKeys = identityKeys
        }
    }

    struct SendFailureNotice: Identifiable {
        let id = UUID()
        let context: OutgoingSendFailureContext

        var reason: OutgoingSendFailureReason {
            context.reason
        }
    }

    private struct RedactionTransitionCandidate {
        let message: StoredMessage
        let previous: StoredMessage

        var identityKey: String {
            message.timelineIdentityKey
        }

        var identityKeys: Set<String> {
            message.timelineIdentityKeys
        }
    }

    private struct PartialReflowPreview {
        let identity: String
        let imageData: Data
    }

    private struct PendingRedactionDisplayLookup {
        let byMessageId: [String: PendingRedactionRecord]
        let byIdentityKey: [String: PendingRedactionRecord]
    }

    private struct VisibleReadReceiptTarget: Equatable {
        let eventId: String
    }

    private enum PendingReadReceiptSend: Equatable {
        case bootstrap(VisibleReadReceiptTarget)
        case advance(VisibleReadReceiptTarget)

        var target: VisibleReadReceiptTarget {
            switch self {
            case .bootstrap(let target), .advance(let target):
                return target
            }
        }
    }

    // MARK: - State

    private(set) var messages: [ChatMessage] = []
    private(set) var rows: [ChatTimelineRow] = []
    @Published private(set) var isPaginating: Bool = false

    /// True when SDK backward pagination returned no new visible
    /// messages, meaning we've likely reached the room history start.
    /// Prevents infinite batch-fetch loops when all remaining events
    /// are filtered (call signaling, redacted, etc.).
    var sdkPaginationExhausted = false
    @Published private(set) var replyingTo: ChatMessage?
    @Published private(set) var editingMessage: ChatMessage?
    @Published private(set) var pendingForwardContent: (preview: ChatMessage, content: RoomMessageEventContentWithoutRelation)?
    @Published private(set) var isInvited: Bool = false
    @Published private(set) var sendFailureNotice: SendFailureNotice?
    @Published private(set) var isComposerSendBlocked: Bool = false
    private var editingDraftOverride: String?
    private var activeEditAttemptId: UUID?
    private var recentlySentTransactionIds: Set<String> = []
    private var recentlySentTransactionOrder: [String] = []
    private var recentlyFailedTransactionIds: Set<String> = []
    private var recentlyFailedTransactionOrder: [String] = []

    /// Called on the main queue when the table needs updating.
    var onTableUpdate: ((TableUpdate) -> Void)?

    /// Called for lightweight in-place cell updates (e.g. send-status change)
    /// that don't require cell recreation. Index path → updated message.
    var onInPlaceUpdate: ((IndexPath, ChatMessage) -> Void)?

    /// Called when messages become redacted (from any source).
    /// Includes grouped media metadata for receiver-side coalescing.
    var onRedactedDetected: ((DetectedRedactionBatch) -> Void)?

    /// Called when a redaction request fails.
    var onRedactionFailed: ((String, Error, PendingRedactionFailureDisposition) -> Void)?
    var canRestoreFailedEditDraft: (() -> Bool)?

    let roomName: String
    let mode: ChatPresentationMode
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
    private let pendingRedactions = PendingRedactionService.shared
    private let pendingReactions = PendingReactionService.shared
    private let room: Room
    private let roomId: String
    private var hiddenMessageKeys = Set<String>()
    private var pendingPartialRedactions: [String: StoredMessage] = [:]
    private var pendingRedactionIds = Set<String>()
    private var pendingRedactionKeys = Set<String>()
    private var partialReflowPreviewsByMessageId: [String: PartialReflowPreview] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var directUserId: String?
    private var historySyncTask: Task<Void, Never>?
    private var pendingRedactionPlaceholderWork: DispatchWorkItem?
    private var readReceiptWork: DispatchWorkItem?
    private var pendingReadReceiptSend: PendingReadReceiptSend?
    private var readReceiptBaselineTarget: VisibleReadReceiptTarget?
    private var lastBootstrapReadReceiptTarget: VisibleReadReceiptTarget?
    private var messageIndexByEventId: [String: Int] = [:]
    private var rowIndexByEventId: [String: Int] = [:]

    /// Whether the window is at the live edge (newest messages visible).
    var isAtLiveEdge: Bool { window.isAtLiveEdge }
    var hasOlderInDB: Bool { window.hasOlderInDB }
    var roomIdentifier: String { roomId }
    private static let pendingRedactionPlaceholderDelay: TimeInterval = 1.7
    private var requiresVerifiedDeviceForSending: Bool {
        room.encryptionState() != .notEncrypted
    }

    init(room: Room, mode: ChatPresentationMode = .normal) {
        let roomId = room.id()
        self.room = room
        self.roomId = roomId
        self.mode = mode
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
        self.pendingRedactionIds = pendingRedactions.pendingMessageIds(roomId: roomId)
        self.pendingRedactionKeys = pendingRedactions.pendingMessageIdentityKeys(roomId: roomId)

        timelineService.isPaginatingSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPaginating)

        MatrixClientService.shared.verificationStateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshComposerSendPermission()
            }
            .store(in: &cancellables)

        SessionVerificationService.shared.encryptionReadinessSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshComposerSendPermission()
            }
            .store(in: &cancellables)

        OutgoingTextOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        OutgoingTextOutboxService.shared.sendFailureSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self,
                      self.roomId == failure.roomId else { return }
                self.sendFailureNotice = SendFailureNotice(context: failure.context)
            }
            .store(in: &cancellables)

        OutgoingImageOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        OutgoingImageOutboxService.shared.sendFailureSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self,
                      self.roomId == failure.roomId else { return }
                self.sendFailureNotice = SendFailureNotice(context: failure.context)
            }
            .store(in: &cancellables)

        OutgoingVideoOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        OutgoingVideoOutboxService.shared.sendFailureSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self,
                      self.roomId == failure.roomId else { return }
                self.sendFailureNotice = SendFailureNotice(context: failure.context)
            }
            .store(in: &cancellables)

        OutgoingFileOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        OutgoingFileOutboxService.shared.sendFailureSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self,
                      self.roomId == failure.roomId else { return }
                self.sendFailureNotice = SendFailureNotice(context: failure.context)
            }
            .store(in: &cancellables)

        OutgoingVoiceOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        OutgoingVoiceOutboxService.shared.sendFailureSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self,
                      self.roomId == failure.roomId else { return }
                self.sendFailureNotice = SendFailureNotice(context: failure.context)
            }
            .store(in: &cancellables)

        OutgoingForwardedMediaOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        OutgoingForwardedMediaOutboxService.shared.sendFailureSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self,
                      self.roomId == failure.roomId else { return }
                self.sendFailureNotice = SendFailureNotice(context: failure.context)
            }
            .store(in: &cancellables)

        OutgoingEditOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        OutgoingEditOutboxService.shared.sendFailureSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self,
                      self.roomId == failure.roomId else { return }
                self.sendFailureNotice = SendFailureNotice(context: failure.context)
            }
            .store(in: &cancellables)

        OutgoingRedactionOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        OutgoingRedactionOutboxService.shared.redactionFailureSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failure in
                guard let self,
                      self.roomId == failure.roomId else { return }
                self.onRedactionFailed?(
                    failure.messageId,
                    failure.error,
                    failure.disposition
                )
            }
            .store(in: &cancellables)

        OutgoingReactionOutboxService.shared.roomDidUpdateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedRoomId in
                guard let self,
                      self.roomId == updatedRoomId else { return }
                Task { [weak self] in
                    await self?.refreshWindow()
                }
            }
            .store(in: &cancellables)

        refreshComposerSendPermission()

        // Write path: SDK diffs → GRDB
        let batcher = diffBatcher
        timelineService.onDiffs = { diffs in
            batcher.receive(diffs: diffs)
        }
        timelineService.onReadCursor = { timestamp in
            batcher.updateReadCursor(timestamp: timestamp)
        }
        timelineService.onOwnFullyReadMarker = { [weak self] eventId in
            DispatchQueue.main.async { [weak self] in
                self?.seedReadReceiptBaseline(eventId: eventId)
            }
        }
        timelineService.onSendQueueUpdate = { [weak self] update, didMutateOutgoingEnvelopes in
            Task { [weak self] in
                guard let self else { return }
                switch update {
                case .sentEvent(let transactionId, _):
                    await self.rememberSentTransaction(transactionId)
                    let didClearPendingEdit = await self.clearPendingMessageEdit(
                        transactionId: transactionId
                    )
                    if !didClearPendingEdit, didMutateOutgoingEnvelopes {
                        await self.refreshWindow()
                    }
                case .sendError(let transactionId, let error, let isRecoverable):
                    let failureContext = OutgoingSendFailureContext.fromQueueWedgeError(error)
                    if let failureContext {
                        await MainActor.run {
                            self.sendFailureNotice = SendFailureNotice(context: failureContext)
                        }
                    }
                    guard !isRecoverable || failureContext != nil else {
                        if didMutateOutgoingEnvelopes {
                            await self.refreshWindow()
                        }
                        return
                    }
                    await self.rememberFailedTransaction(transactionId)
                    let didFailPendingEdit = await self.failPendingMessageEdit(
                        transactionId: transactionId
                    )
                    if !didFailPendingEdit, didMutateOutgoingEnvelopes {
                        await self.refreshWindow()
                    }
                case .cancelledLocalEvent(let transactionId):
                    await self.rememberFailedTransaction(transactionId)
                    let didFailPendingEdit = await self.failPendingMessageEdit(
                        transactionId: transactionId
                    )
                    if !didFailPendingEdit, didMutateOutgoingEnvelopes {
                        await self.refreshWindow()
                    }
                default:
                    if didMutateOutgoingEnvelopes {
                        await self.refreshWindow()
                    }
                }
            }
        }

        // Bridge: batcher flush → window refresh
        let win = window
        diffBatcher.onFlush = { [weak win] summary in
            win?.refresh(origin: .timelineFlush(summary))
        }

        // Read path: window changes → UI
        window.onChange = { [weak self] newStored, prevStored, origin in
            self?.handleObservationChange(
                newStored: newStored,
                prevStored: prevStored,
                origin: origin
            )
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
                if !self.mode.isPreview {
                    PresenceTracker.shared.register(userIds: [userId], for: "chat")
                }
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
            guard let self else { return }
            await self.timelineService.startListening(subscribeForSync: !self.mode.isPreview)
            guard !self.mode.isPreview else { return }
            let terminalFailures = await self.pendingRedactions.retryPendingRedactions(
                roomId: self.roomId,
                timelineService: self.timelineService
            )
            guard !terminalFailures.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for failure in terminalFailures {
                    self.onRedactionFailed?(
                        failure.messageId,
                        failure.error,
                        .terminal
                    )
                }
            }
        }

        guard !mode.isPreview else { return }
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

    private func handleObservationChange(
        newStored: [StoredMessage],
        prevStored: [StoredMessage]?,
        origin: MessageWindowChangeOrigin
    ) {
        let previousDisplayIdentityKeys = Set(messages.flatMap(\.timelineIdentityKeys))
        let resolvedPending = pendingRedactions.reconcileResolvedPendingRedactions(roomId: roomId)
        let resolvedPendingIds = resolvedPending.messageIds
        let resolvedPendingKeys = resolvedPending.identityKeys.union(
            Self.identityKeys(
                for: resolvedPendingIds,
                in: newStored + (prevStored ?? [])
            )
        )
        let activePendingRedactionKeys = pendingRedactionKeys.union(resolvedPendingKeys)

        // 1. Detect newly redacted user messages (paint splash).
        //    Only for content that was a visible message — not call
        //    signaling carriers (zero-width-space body), system
        //    notices, or unsupported event types.
        let redactionCandidates: [RedactionTransitionCandidate]
        let animatedRedactions: [RedactionTransitionCandidate]
        let newlyRedactedIds: [String]
        let newlyRedactedIdentityKeys: Set<String>
        let redactionBatch: DetectedRedactionBatch
        if let prevStored {
            let prevByIdentity = Dictionary(
                prevStored.flatMap { stored in
                    stored.timelineIdentityKeys.map { ($0, stored) }
                },
                uniquingKeysWith: { existing, candidate in
                    Self.preferredTransitionPrevious(existing, candidate)
                }
            )
            redactionCandidates = newStored.compactMap { msg in
                guard msg.contentType == "redacted" else { return nil }
                guard let prev = Self.previousMessage(for: msg, in: prevByIdentity),
                      Self.isSplashEligiblePreviousContent(prev)
                else { return nil }
                return RedactionTransitionCandidate(message: msg, previous: prev)
            }
            animatedRedactions = Self.animationEligibleRedactions(
                candidates: redactionCandidates,
                origin: origin,
                previousDisplayIdentityKeys: previousDisplayIdentityKeys,
                pendingRedactionKeys: activePendingRedactionKeys
            )
            newlyRedactedIds = animatedRedactions.map(\.message.id)
            newlyRedactedIdentityKeys = Set(animatedRedactions.flatMap(\.identityKeys))
            redactionBatch = Self.detectedRedactionBatch(
                redactions: animatedRedactions,
                newStored: newStored,
                prevStored: prevStored
            )
        } else {
            redactionCandidates = []
            animatedRedactions = []
            newlyRedactedIds = []
            newlyRedactedIdentityKeys = []
            redactionBatch = DetectedRedactionBatch(messageIds: [], mediaGroups: [])
        }
        if !resolvedPendingIds.isEmpty {
            pendingRedactionIds.subtract(resolvedPendingIds)
            pendingRedactionKeys.subtract(resolvedPendingKeys)
        }
        Self.logTimelineHealth(
            origin: origin,
            newStored: newStored,
            prevStored: prevStored,
            redactionCandidates: redactionCandidates,
            animatedRedactions: animatedRedactions
        )

        Self.registerPendingPartialRedactions(
            into: &pendingPartialRedactions,
            newStored: newStored,
            animatedRedactions: animatedRedactions,
            hiddenMessageKeys: hiddenMessageKeys
        )
        Self.prunePartialReflowPreviews(
            in: &partialReflowPreviewsByMessageId,
            newStored: newStored
        )

        // 2. Build display array: filter hidden and already-redacted (keep newly-redacted for animation)
        let now = Date().timeIntervalSince1970
        let pendingRedactionRecords = pendingRedactions.pendingRecords(roomId: roomId)
        let pendingRedactionLookup = Self.pendingRedactionDisplayLookup(
            for: pendingRedactionRecords
        )
        schedulePendingRedactionPlaceholderRefresh(
            records: pendingRedactionRecords,
            now: now
        )
        let pendingReactionRemovalsByEventId = pendingReactions
            .pendingRemovalKeysByEventId(roomId: roomId)
        let rawMessages = newStored.compactMap { msg -> ChatMessage? in
            displayChatMessage(
                for: msg,
                pendingRedactionLookup: pendingRedactionLookup,
                pendingReactionRemovalsByEventId: pendingReactionRemovalsByEventId,
                now: now,
                visibleRedactedKeys: newlyRedactedIdentityKeys
            )
        }

        let deletedMediaGroupIds = Self.redactedMediaGroupIds(in: newStored)
        if !deletedMediaGroupIds.isEmpty || !newlyRedactedIds.isEmpty {
            logMediaGroup(
                "deleteReflow observation newlyRedacted=\(newlyRedactedIds.joined(separator: ",")) deletedGroups=\(deletedMediaGroupIds.sorted().joined(separator: ",")) hidden=\(hiddenMessageKeys.count)"
            )
        }
        let olderBoundary = window.peekOlderNeighbor()
        let newerBoundary = window.peekNewerNeighbor()
        let newMessages = buildRenderableMessages(
            from: rawMessages,
            deletedMediaGroupIds: deletedMediaGroupIds,
            partialReflowPreviewsByMessageId: partialReflowPreviewsByMessageId,
            olderBoundary: olderBoundary,
            newerBoundary: newerBoundary
        )

        // 3. Prefetch images
        Self.prefetchImages(newMessages)

        // 4. Compute table update
        let oldRows = self.rows
        setMessages(newMessages, olderBoundary: olderBoundary)

        let tableUpdate: TableUpdate
        var inPlaceUpdates: [(IndexPath, ChatMessage)] = []
        if prevStored == nil {
            tableUpdate = .reload
        } else {
            (tableUpdate, inPlaceUpdates) = Self.computeTableUpdate(old: oldRows, new: rows)
        }
        // 5. Emit (filter redacted from normal updates, send separately for animation)
        if !newlyRedactedIds.isEmpty {
            if case .batch(let del, let ins, let moves, let upd, let anim) = tableUpdate {
                let filtered = upd.filter { ip in
                    guard rows.indices.contains(ip.row),
                          let message = rows[ip.row].message
                    else { return true }
                    return !message.content.isRedacted
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

        // 7. Any materialized older rows in GRDB mean backward pagination
        // is not exhausted, even if a previous server round finished late.
        if window.hasOlderInDB {
            sdkPaginationExhausted = false
        }

        // 8. Auto-paginate if too few messages and GRDB + SDK both need more
        if newMessages.count < 20 && !isPaginating && !window.hasOlderInDB {
            loadOlderFromServer()
        }
    }

    /// Stable key for table diff comparison. Matrix eventId is the canonical
    /// identity once available; transactionId is only the pending local echo
    /// identity, and SDK uniqueId is only a positional fallback.
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
        return msg.eventId ?? msg.transactionId ?? msg.id
    }

    private static func stableKey(_ row: ChatTimelineRow) -> String {
        switch row {
        case .message(let message):
            return "message:\(stableKey(message))"
        case .dateDivider(let model):
            return model.id
        }
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
        let currentLocalSessionId = MatrixClientService.shared.currentLocalSessionId
        let mediaBatchPlan = Self.pendingRenderableMediaGroupPlan(
            from: envelopes.filter { $0.kind == .mediaBatch },
            rawMessages: rawMessages,
            currentUserId: currentUserId,
            currentLocalSessionId: currentLocalSessionId
        )
        let singleEnvelopePlan = Self.pendingRenderableSingleEnvelopePlan(
            from: envelopes.filter { $0.kind != .mediaBatch },
            rawMessages: rawMessages,
            currentUserId: currentUserId,
            currentLocalSessionId: currentLocalSessionId
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
            guard let stored = storedById[messageId] else {
                continue
            }
            for identityKey in stored.timelineIdentityKeys {
                guard pendingPartialRedactions[identityKey] == nil else { continue }
                pendingPartialRedactions[identityKey] = stored
            }
        }
    }

    func clearPendingAnimatedRedactions(_ messageIds: [String]) {
        guard !messageIds.isEmpty else { return }
        let storedMessages = window.currentStoredMessages()
        let identityKeys = Self.identityKeys(for: Set(messageIds), in: storedMessages)
        for identityKey in identityKeys {
            pendingPartialRedactions.removeValue(forKey: identityKey)
        }
        for messageId in messageIds {
            pendingPartialRedactions.removeValue(forKey: MessageIdentity.local(messageId).key)
        }
    }

    func restoreMessages(_ messageIds: [String]) {
        let idsToRestore = Set(messageIds)
        guard !idsToRestore.isEmpty else { return }

        let storedMessages = window.currentStoredMessages()
        let keysToRestore = Self.identityKeys(for: idsToRestore, in: storedMessages)
        hiddenMessageKeys.subtract(keysToRestore)
        pendingRedactionIds.subtract(idsToRestore)
        pendingRedactionKeys.subtract(keysToRestore)
        for identityKey in keysToRestore {
            pendingPartialRedactions.removeValue(forKey: identityKey)
        }

        let affectedMediaGroupIds = Set(
            storedMessages.compactMap { message -> String? in
                guard idsToRestore.contains(message.id) else { return nil }
                return message.toChatMessage()?.zynaAttributes.mediaGroup?.id
            }
        )

        if affectedMediaGroupIds.isEmpty {
            for messageId in idsToRestore {
                partialReflowPreviewsByMessageId.removeValue(forKey: messageId)
            }
        } else {
            partialReflowPreviewsByMessageId = partialReflowPreviewsByMessageId.filter { messageId, _ in
                guard let stored = storedMessages.first(where: { $0.id == messageId }) else { return false }
                let mediaGroupId = stored.toChatMessage()?.zynaAttributes.mediaGroup?.id
                return mediaGroupId.map { !affectedMediaGroupIds.contains($0) } ?? false
            }
        }

        let oldRows = rows
        let oldMessages = messages
        let visibleRedactedKeys = Set(
            oldMessages
                .filter { $0.content.isRedacted }
                .flatMap(\.timelineIdentityKeys)
        )
        let now = Date().timeIntervalSince1970
        let pendingRedactionRecords = pendingRedactions.pendingRecords(roomId: roomId)
        let pendingRedactionLookup = Self.pendingRedactionDisplayLookup(
            for: pendingRedactionRecords
        )
        schedulePendingRedactionPlaceholderRefresh(
            records: pendingRedactionRecords,
            now: now
        )
        let pendingReactionRemovalsByEventId = pendingReactions
            .pendingRemovalKeysByEventId(roomId: roomId)
        let rawMessages = storedMessages.compactMap { msg -> ChatMessage? in
            displayChatMessage(
                for: msg,
                pendingRedactionLookup: pendingRedactionLookup,
                pendingReactionRemovalsByEventId: pendingReactionRemovalsByEventId,
                now: now,
                visibleRedactedKeys: visibleRedactedKeys
            )
        }

        let olderBoundary = window.peekOlderNeighbor()
        let newerBoundary = window.peekNewerNeighbor()
        let newMessages = buildRenderableMessages(
            from: rawMessages,
            deletedMediaGroupIds: Self.redactedMediaGroupIds(in: storedMessages),
            partialReflowPreviewsByMessageId: partialReflowPreviewsByMessageId,
            olderBoundary: olderBoundary,
            newerBoundary: newerBoundary
        )
        setMessages(newMessages, olderBoundary: olderBoundary)

        let (tableUpdate, inPlaceUpdates) = Self.computeTableUpdate(old: oldRows, new: rows)
        onTableUpdate?(tableUpdate)
        for (indexPath, message) in inPlaceUpdates {
            onInPlaceUpdate?(indexPath, message)
        }
    }

    func areMessagesRedacted(_ messageIds: [String]) -> Bool {
        guard !messageIds.isEmpty else { return false }
        let storedMessages = window.currentStoredMessages()
        let redactedKeys = Set(
            storedMessages
                .filter { $0.contentType == "redacted" }
                .flatMap(\.timelineIdentityKeys)
        )
        return messageIds.allSatisfy { messageId in
            let identityKeys = Self.identityKeys(for: [messageId], in: storedMessages)
            return !identityKeys.isEmpty && !identityKeys.isDisjoint(with: redactedKeys)
        }
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
        currentUserId: String,
        currentLocalSessionId: String?
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
                currentUserId: currentUserId,
                currentLocalSessionId: currentLocalSessionId
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
        currentUserId: String,
        currentLocalSessionId: String?
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
                currentUserId: currentUserId,
                currentLocalSessionId: currentLocalSessionId
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
                isEditable: false,
                isEdited: false,
                isEditPending: false,
                isEditFailed: false,
                latestEditEventId: nil,
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
        var eventIndexById: [String: Int] = [:]
        var transactionIndexById: [String: Int] = [:]
        for item in group.items {
            if let eventId = item.eventId,
               !eventId.isEmpty,
               eventIndexById[eventId] == nil {
                eventIndexById[eventId] = item.itemIndex
            }
            if let transactionId = item.transactionId,
               !transactionId.isEmpty,
               transactionIndexById[transactionId] == nil {
                transactionIndexById[transactionId] = item.itemIndex
            }
        }

        var primaryMessageIndexByItemIndex: [Int: Int] = [:]
        var hiddenMessageIndices = Set<Int>()
        var syncedEventIndices: [Int: Int] = [:]
        var hasTransactionOnlyMessages = false
        var fallbackClaimedItemIndices = Set<Int>()

        for (messageIndex, message) in messages.enumerated() {
            guard message.isOutgoing,
                  case .image = message.content
            else {
                continue
            }

            let explicitItemIndex = message.eventId.flatMap { eventIndexById[$0] }
                ?? message.transactionId.flatMap { transactionIndexById[$0] }
                ?? pendingMediaGroupItemIndex(of: message, in: group)
            let fallbackItemIndex = explicitItemIndex == nil
                ? pendingMediaGroupFallbackItemIndex(
                    of: message,
                    in: group,
                    claimedItemIndices: fallbackClaimedItemIndices
                )
                : nil
            let relatedItemIndex = explicitItemIndex
                ?? fallbackItemIndex

            if let relatedItemIndex {
                hiddenMessageIndices.insert(messageIndex)
                if fallbackItemIndex != nil {
                    fallbackClaimedItemIndices.insert(relatedItemIndex)
                }
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

    private static func pendingMediaGroupFallbackItemIndex(
        of message: ChatMessage,
        in group: OutgoingEnvelopeSnapshot,
        claimedItemIndices: Set<Int>
    ) -> Int? {
        guard message.zynaAttributes.mediaGroup == nil,
              message.timestamp >= group.createdAt.addingTimeInterval(-5),
              message.timestamp <= group.createdAt.addingTimeInterval(600),
              normalized(message.content.visibleImageCaption) == normalized(group.caption)
        else {
            return nil
        }

        let dimensions: (width: UInt64?, height: UInt64?)? = {
            guard case .image(_, _, let width, let height, _, _) = message.content else {
                return nil
            }
            return (width, height)
        }()

        guard let dimensions else { return nil }
        let candidates = group.items
            .filter { item in
                !claimedItemIndices.contains(item.itemIndex)
                    && dimensionsMatch(expected: item.previewWidth, actual: dimensions.width)
                    && dimensionsMatch(expected: item.previewHeight, actual: dimensions.height)
            }
            .sorted { $0.itemIndex > $1.itemIndex }

        return candidates.first?.itemIndex
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
        currentUserId: String,
        currentLocalSessionId: String?
    ) -> PendingRenderableEnvelope {
        let isStaleSessionEnvelope = group.isStaleSession(currentSessionId: currentLocalSessionId)
        var primaryMessagesByItemIndex: [Int: ChatMessage] = [:]
        primaryMessagesByItemIndex.reserveCapacity(observedState.primaryMessageIndexByItemIndex.count)
        for (itemIndex, messageIndex) in observedState.primaryMessageIndexByItemIndex {
            guard rawMessages.indices.contains(messageIndex) else { continue }
            primaryMessagesByItemIndex[itemIndex] = rawMessages[messageIndex]
        }

        let mediaItems = group.items.map { item -> MediaGroupItem in
            let primaryMessage = primaryMessagesByItemIndex[item.itemIndex]
            let primaryImageContent: (source: MediaSource?, thumbnailSource: MediaSource?, width: UInt64?, height: UInt64?, caption: String?)? = {
                guard let primaryMessage,
                      case .image(let source, let thumbnailSource, let width, let height, let caption, _) = primaryMessage.content else {
                    return nil
                }
                return (source, thumbnailSource, width, height, caption)
            }()

            return MediaGroupItem(
                messageId: primaryMessage?.id ?? item.id,
                eventId: item.eventId ?? primaryMessage?.eventId,
                transactionId: item.transactionId ?? primaryMessage?.transactionId,
                source: item.mediaSource ?? primaryImageContent?.source,
                thumbnailSource: primaryImageContent?.thumbnailSource,
                previewImageData: item.previewImageData,
                previewIdentity: Self.pendingMediaPreviewIdentity(
                    groupId: group.id,
                    itemIndex: item.itemIndex
                ),
                width: item.previewWidth ?? primaryImageContent?.width,
                height: item.previewHeight ?? primaryImageContent?.height,
                caption: group.caption ?? primaryImageContent?.caption,
                sendStatus: isStaleSessionEnvelope ? "failed" : item.transportState.messageSendStatus
            )
        }

        let anchorIndex: Int? = {
            let indices = Array(observedState.primaryMessageIndexByItemIndex.values)
            guard !indices.isEmpty else { return nil }
            return group.captionPlacement == .top ? indices.min() : indices.max()
        }()

        let anchorMessage = anchorIndex.flatMap { rawMessages.indices.contains($0) ? rawMessages[$0] : nil }
        let sendStatus = isStaleSessionEnvelope
            ? "failed"
            : aggregatePendingMediaGroupSendStatus(from: mediaItems)
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
            isEditable: false,
            isEdited: false,
            isEditPending: false,
            isEditFailed: false,
            latestEditEventId: nil,
            zynaAttributes: ZynaMessageAttributes(),
            sendStatus: sendStatus
        )
        message.mediaGroupPresentation = presentation
        message.outgoingEnvelopeId = group.id
        message.isStaleOutgoingEnvelope = isStaleSessionEnvelope

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

            let isRelatedByContent = envelope.kind == .video
                && message.eventId != nil
                && hydratedMessage(message, matches: envelope)
            let isRelated = message.eventId.map { eventIds.contains($0) } == true
                || message.transactionId.map { transactionIds.contains($0) } == true
                || isRelatedByContent
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
        case (.video, .video):
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
        if isExplicitlyBound(primaryMessage, to: envelope) {
            return explicitlyBoundMessageIsRenderable(
                primaryMessage,
                envelopeKind: envelope.kind
            )
        }
        return hydratedMessage(primaryMessage, matches: envelope)
    }

    private static func isExplicitlyBound(
        _ message: ChatMessage,
        to envelope: OutgoingEnvelopeSnapshot
    ) -> Bool {
        let eventIds = Set(envelope.items.compactMap(\.eventId))
        if let eventId = message.eventId,
           eventIds.contains(eventId) {
            return true
        }

        let transactionIds = Set(envelope.items.compactMap(\.transactionId))
        if let transactionId = message.transactionId,
           transactionIds.contains(transactionId) {
            return true
        }

        return false
    }

    private static func explicitlyBoundMessageIsRenderable(
        _ message: ChatMessage,
        envelopeKind: OutgoingEnvelopeKind
    ) -> Bool {
        switch (envelopeKind, message.content) {
        case (.text, .text):
            return true
        case (.image, .image(let source, _, _, _, _, _)):
            return source != nil
        case (.video, .video(let source, _, _, _, _, _, _, _, _, _)):
            return source != nil
        case (.voice, .voice(let source, _, _)):
            return source != nil
        case (.file, .file(let source, _, _, _, _)):
            return source != nil
        default:
            return false
        }
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
            guard case .image(let source, _, let width, let height, let caption, _) = message.content,
                  source != nil
            else {
                return false
            }
            return normalized(caption) == normalized(imagePayload.caption)
                && dimensionsMatch(expected: imagePayload.width, actual: width)
                && dimensionsMatch(expected: imagePayload.height, actual: height)
        case .video(let videoPayload):
            guard case .video(let source, _, let width, let height, let duration, let filename, let mimetype, let size, let caption, _) = message.content,
                  source != nil
            else {
                return false
            }
            let durationMatches: Bool
            if let expectedDuration = videoPayload.duration,
               let actualDuration = duration {
                durationMatches = abs(actualDuration - expectedDuration) < 0.5
            } else {
                durationMatches = true
            }
            return filename == videoPayload.filename
                && normalized(caption) == normalized(videoPayload.caption)
                && dimensionsMatch(expected: videoPayload.width, actual: width)
                && dimensionsMatch(expected: videoPayload.height, actual: height)
                && durationMatches
                && (videoPayload.mimetype == nil || mimetype == videoPayload.mimetype)
                && (videoPayload.size == nil || size == videoPayload.size)
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
        currentUserId: String,
        currentLocalSessionId: String?
    ) -> PendingRenderableEnvelope {
        let isStaleSessionEnvelope = envelope.isStaleSession(currentSessionId: currentLocalSessionId)
        let primaryMessage = observedState.primaryMessageIndex.flatMap {
            rawMessages.indices.contains($0) ? rawMessages[$0] : nil
        }
        let primaryContent = primaryMessage?.content
        let primaryTimestamp = primaryMessage?.timestamp ?? envelope.createdAt
        let primarySenderId = primaryMessage?.senderId ?? currentUserId
        let sendStatus = isStaleSessionEnvelope
            ? "failed"
            : pendingSendStatus(
                transportState: envelope.primaryItem?.transportState,
                hydratedMessage: primaryMessage
            )

        let content: ChatMessageContent = {
            switch envelope.payload {
            case .text(let payload):
                return .text(body: payload.body)
            case .image(let payload):
                let primarySource: MediaSource?
                let primaryThumbnailSource: MediaSource?
                let primaryWidth: UInt64?
                let primaryHeight: UInt64?
                let primaryCaption: String?
                if case .image(let source, let thumbnailSource, let width, let height, let caption, _) = primaryContent {
                    primarySource = source
                    primaryThumbnailSource = thumbnailSource
                    primaryWidth = width
                    primaryHeight = height
                    primaryCaption = caption
                } else {
                    primarySource = nil
                    primaryThumbnailSource = nil
                    primaryWidth = nil
                    primaryHeight = nil
                    primaryCaption = nil
                }
                return .image(
                    source: envelope.primaryItem?.mediaSource ?? primarySource,
                    thumbnailSource: primaryThumbnailSource,
                    width: envelope.primaryItem?.previewWidth ?? payload.width ?? primaryWidth,
                    height: envelope.primaryItem?.previewHeight ?? payload.height ?? primaryHeight,
                    caption: payload.caption ?? primaryCaption,
                    previewImageData: envelope.primaryItem?.previewImageData
                )
            case .video(let payload):
                let primarySource: MediaSource?
                let primaryThumbnailSource: MediaSource?
                let primaryWidth: UInt64?
                let primaryHeight: UInt64?
                let primaryDuration: TimeInterval?
                let primaryCaption: String?
                if case .video(let source, let thumbnailSource, let width, let height, let duration, _, _, _, let caption, _) = primaryContent {
                    primarySource = source
                    primaryThumbnailSource = thumbnailSource
                    primaryWidth = width
                    primaryHeight = height
                    primaryDuration = duration
                    primaryCaption = caption
                } else {
                    primarySource = nil
                    primaryThumbnailSource = nil
                    primaryWidth = nil
                    primaryHeight = nil
                    primaryDuration = nil
                    primaryCaption = nil
                }
                return .video(
                    source: envelope.primaryItem?.mediaSource ?? primarySource,
                    thumbnailSource: primaryThumbnailSource,
                    width: envelope.primaryItem?.previewWidth ?? payload.width ?? primaryWidth,
                    height: envelope.primaryItem?.previewHeight ?? payload.height ?? primaryHeight,
                    duration: payload.duration ?? primaryDuration,
                    filename: payload.filename,
                    mimetype: payload.mimetype,
                    size: payload.size,
                    caption: payload.caption ?? primaryCaption,
                    previewThumbnailData: envelope.primaryItem?.previewImageData
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
            isEditable: false,
            isEdited: false,
            isEditPending: false,
            isEditFailed: false,
            latestEditEventId: nil,
            zynaAttributes: envelope.zynaAttributes,
            sendStatus: sendStatus
        )
        message.outgoingEnvelopeId = envelope.id
        message.isStaleOutgoingEnvelope = isStaleSessionEnvelope
        message.canRetryOutgoingEnvelope = (isStaleSessionEnvelope || envelope.primaryItem?.transportState == .failed)
            && envelope.isRetryableAfterSessionChange

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
        if hydratedMessage?.eventId != nil,
           hydratedMessage?.sendStatus == "read" {
            return "read"
        }
        return transportState?.messageSendStatus ?? "queued"
    }

    private static func replyEventId(of replyInfo: ReplyInfo?) -> String? {
        replyInfo?.eventId
    }

    private static func normalized(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let trimmed = caption
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func computeTableUpdate(old: [ChatTimelineRow], new: [ChatTimelineRow]) -> (TableUpdate, [(IndexPath, ChatMessage)]) {
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

        if !deletions.isEmpty {
            let deletedRows = deletions.prefix(8).compactMap { indexPath -> String? in
                guard old.indices.contains(indexPath.row) else { return nil }
                return debugTimelineRow(old[indexPath.row])
            }
            let insertedRows = insertions.prefix(8).compactMap { indexPath -> String? in
                guard new.indices.contains(indexPath.row) else { return nil }
                return debugTimelineRow(new[indexPath.row])
            }
            timelineHealthLog(
                "table diff delete=\(deletedRows.joined(separator: " || ")) insert=\(insertedRows.joined(separator: " || ")) old=\(old.count) new=\(new.count)"
            )
        }

        let newByKey = Dictionary(new.enumerated().map { (stableKey($1), $0) }, uniquingKeysWith: { _, last in last })
        var fullUpdates: [IndexPath] = []
        var inPlaceUpdates: [(IndexPath, ChatMessage)] = []

        for (oldIdx, oldRow) in old.enumerated() {
            guard !removedOldOffsets.contains(oldIdx) else { continue }
            guard let newIdx = newByKey[stableKey(oldRow)], oldRow != new[newIdx] else { continue }

            if case .message(let oldMessage) = oldRow,
               case .message(let newMessage) = new[newIdx],
               MessageCellNode.canUpdateInPlace(old: oldMessage, new: newMessage) {
                inPlaceUpdates.append((IndexPath(row: newIdx, section: 0), newMessage))
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

    private static func debugTimelineRow(_ row: ChatTimelineRow) -> String {
        switch row {
        case .message(let message):
            let detail: String
            let type: String
            switch message.content {
            case .text(let body), .notice(let body), .emote(let body):
                type = "text"
                detail = body
            case .image:
                type = "image"
                detail = "image"
            case .video(_, _, _, _, _, let filename, _, _, _, _):
                type = "video"
                detail = filename
            case .voice:
                type = "voice"
                detail = "voice"
            case .file(_, let filename, _, _, _):
                type = "file"
                detail = filename
            case .redacted:
                type = "redacted"
                detail = "redacted"
            case .pendingOutgoingMediaBatch:
                type = "pendingBatch"
                detail = "pendingBatch"
            case .callEvent(let callType, let callId, let reason):
                type = "call"
                detail = "\(callType.rawValue):\(callId):\(reason ?? "-")"
            case .systemEvent(let text, _):
                type = "system"
                detail = text
            case .unsupported(let typeName):
                type = "unsupported"
                detail = typeName
            }
            return "key=\(stableKey(row)) id=\(shortDebug(message.id)) event=\(shortDebug(message.eventId)) tx=\(shortDebug(message.transactionId)) type=\(type) ts=\(String(format: "%.3f", message.timestamp.timeIntervalSince1970)) detail=\(shortDebug(detail))"
        case .dateDivider(let model):
            return "key=\(stableKey(row)) divider=\(model.id)"
        }
    }

    private static func shortDebug(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "-" }
        guard value.count > 26 else { return value }
        return "\(value.prefix(12))...\(value.suffix(8))"
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
    }

    func jumpToOldest() {
        sdkPaginationExhausted = false
        window.jumpToOldest()
    }

    func indexOfMessage(eventId: String) -> Int? {
        rowIndexByEventId[eventId]
    }

    private func messageIndex(eventId: String) -> Int? {
        messageIndexByEventId[eventId]
    }

    // MARK: - Read Receipts

    /// Called by ChatViewController with the newest sufficiently visible
    /// event in the unobscured viewport. We only bootstrap the server
    /// baseline when the viewport is effectively at the live edge; after
    /// that receipts advance monotonically as the user reveals newer rows.
    func updateVisibleReadReceiptCandidate(
        eventId: String?,
        canEstablishBaseline: Bool
    ) {
        guard !mode.isPreview else { return }
        guard let eventId else {
            readReceiptWork?.cancel()
            pendingReadReceiptSend = nil
            return
        }

        let target = VisibleReadReceiptTarget(eventId: eventId)

        if readReceiptBaselineTarget == nil {
            guard canEstablishBaseline else { return }
            guard pendingReadReceiptSend != .bootstrap(target) else { return }
            guard lastBootstrapReadReceiptTarget != target else { return }
            scheduleReadReceiptSend(to: target, mode: .bootstrap(target))
            return
        }

        guard shouldAdvanceReadReceipt(to: target) else { return }
        guard pendingReadReceiptSend != .advance(target) else { return }

        scheduleReadReceiptSend(to: target, mode: .advance(target))
    }

    private func scheduleReadReceiptSend(
        to target: VisibleReadReceiptTarget,
        mode: PendingReadReceiptSend
    ) {
        readReceiptWork?.cancel()
        pendingReadReceiptSend = mode
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task {
                let didSend = await self.timelineService.sendReadReceipt(for: target.eventId)
                await MainActor.run {
                    self.finishReadReceiptSend(mode, didSend: didSend)
                }
            }
        }
        readReceiptWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finishReadReceiptSend(_ pending: PendingReadReceiptSend, didSend: Bool) {
        if pendingReadReceiptSend == pending {
            pendingReadReceiptSend = nil
        }

        guard didSend else {
            if case .bootstrap(let target) = pending,
               lastBootstrapReadReceiptTarget == target {
                lastBootstrapReadReceiptTarget = nil
            }
            return
        }

        switch pending {
        case .bootstrap(let target):
            lastBootstrapReadReceiptTarget = target
        case .advance(let target):
            establishReadReceiptBaseline(to: target)
        }
    }

    private func shouldAdvanceReadReceipt(to target: VisibleReadReceiptTarget) -> Bool {
        if let readReceiptBaselineTarget,
           !isReadReceiptTarget(target, newerThan: readReceiptBaselineTarget) {
            return false
        }
        if let pendingTarget = pendingReadReceiptSend?.target,
           !isReadReceiptTarget(target, newerThan: pendingTarget) {
            return false
        }
        return true
    }

    private func isReadReceiptTarget(
        _ lhs: VisibleReadReceiptTarget,
        newerThan rhs: VisibleReadReceiptTarget
    ) -> Bool {
        if lhs.eventId == rhs.eventId {
            return false
        }

        let lhsIndex = messageIndex(eventId: lhs.eventId)
        let rhsIndex = messageIndex(eventId: rhs.eventId)

        switch (lhsIndex, rhsIndex) {
        case let (.some(lhsIndex), .some(rhsIndex)):
            return lhsIndex < rhsIndex
        case (.some, .none):
            return isAtLiveEdge
        default:
            return false
        }
    }

    private func seedReadReceiptBaseline(eventId: String) {
        establishReadReceiptBaseline(to: VisibleReadReceiptTarget(eventId: eventId))
    }

    private func establishReadReceiptBaseline(to target: VisibleReadReceiptTarget) {
        if let readReceiptBaselineTarget,
           !isReadReceiptTarget(target, newerThan: readReceiptBaselineTarget) {
            return
        }

        readReceiptBaselineTarget = target
        lastBootstrapReadReceiptTarget = nil

        if let pendingTarget = pendingReadReceiptSend?.target,
           !isReadReceiptTarget(pendingTarget, newerThan: target) {
            readReceiptWork?.cancel()
            pendingReadReceiptSend = nil
        }
    }

    private func setMessages(_ newMessages: [ChatMessage], olderBoundary: ClusterNeighbor?) {
        messages = newMessages
        rows = Self.buildRows(from: newMessages, olderBoundary: olderBoundary)

        // Matrix event_ids identify one event, but SDK/local-echo
        // replacement can transiently surface the same event twice.
        // Navigation/read receipts only need one visible target.
        var messageIndices: [String: Int] = [:]
        messageIndices.reserveCapacity(newMessages.count)
        for (index, message) in newMessages.enumerated() {
            guard let eventId = message.eventId,
                  !eventId.isEmpty,
                  messageIndices[eventId] == nil else {
                continue
            }
            messageIndices[eventId] = index
        }
        messageIndexByEventId = messageIndices

        var rowIndices: [String: Int] = [:]
        rowIndices.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard let eventId = row.message?.eventId,
                  !eventId.isEmpty,
                  rowIndices[eventId] == nil else {
                continue
            }
            rowIndices[eventId] = index
        }
        rowIndexByEventId = rowIndices
    }

    private static func buildRows(
        from messages: [ChatMessage],
        olderBoundary: ClusterNeighbor?
    ) -> [ChatTimelineRow] {
        guard !messages.isEmpty else { return [] }

        let calendar = Calendar.current
        var result: [ChatTimelineRow] = []
        result.reserveCapacity(messages.count + min(messages.count, 16))

        for index in messages.indices {
            let message = messages[index]
            result.append(.message(message))

            let olderTimestamp: Date?
            if index + 1 < messages.count {
                olderTimestamp = messages[index + 1].timestamp
            } else {
                olderTimestamp = olderBoundary?.timestamp
            }

            let endsVisibleDayGroup = olderTimestamp.map {
                !calendar.isDate(message.timestamp, inSameDayAs: $0)
            } ?? true

            if endsVisibleDayGroup {
                result.append(.dateDivider(DateDividerModel.make(for: message.timestamp, calendar: calendar)))
            }
        }

        return result
    }

    // MARK: - Reply

    func setReplyTarget(_ message: ChatMessage?) {
        replyingTo = message
        if message != nil {
            activeEditAttemptId = nil
            editingDraftOverride = nil
            editingMessage = nil
            pendingForwardContent = nil
        }
    }

    func setEditingTarget(_ message: ChatMessage?) {
        activeEditAttemptId = nil
        editingDraftOverride = nil
        guard let message else {
            editingMessage = nil
            return
        }
        guard message.isTextEditable else { return }
        replyingTo = nil
        pendingForwardContent = nil
        editingMessage = message
    }

    func setPendingForward(preview: ChatMessage, content: RoomMessageEventContentWithoutRelation) {
        activeEditAttemptId = nil
        editingDraftOverride = nil
        replyingTo = nil
        editingMessage = nil
        pendingForwardContent = (preview, content)
    }

    func editingInputText(for message: ChatMessage) -> String? {
        editingDraftOverride ?? message.content.textBody
    }

    func clearPendingForward() {
        pendingForwardContent = nil
    }

    // MARK: - Actions

    private func refreshWindow() async {
        await MainActor.run {
            self.window.refresh(origin: .localMutation)
        }
    }

    @MainActor
    private func rememberSentTransaction(_ transactionId: String) {
        rememberTransaction(
            transactionId,
            ids: &recentlySentTransactionIds,
            order: &recentlySentTransactionOrder
        )
    }

    @MainActor
    private func hasRecentlySentTransaction(_ transactionId: String) -> Bool {
        recentlySentTransactionIds.contains(transactionId)
    }

    @MainActor
    private func rememberFailedTransaction(_ transactionId: String) {
        rememberTransaction(
            transactionId,
            ids: &recentlyFailedTransactionIds,
            order: &recentlyFailedTransactionOrder
        )
    }

    @MainActor
    private func hasRecentlyFailedTransaction(_ transactionId: String) -> Bool {
        recentlyFailedTransactionIds.contains(transactionId)
    }

    @MainActor
    private func rememberTransaction(
        _ transactionId: String,
        ids: inout Set<String>,
        order: inout [String]
    ) {
        if ids.insert(transactionId).inserted {
            order.append(transactionId)
        }

        while order.count > 128 {
            let removed = order.removeFirst()
            ids.remove(removed)
        }
    }

    @discardableResult
    private func markMessageEditPending(
        eventId: String
    ) async -> Bool {
        do {
            let didChange = try await DatabaseService.shared.dbQueue.write { [roomId] db -> Bool in
                try db.execute(
                    sql: """
                        UPDATE storedMessage
                        SET isEditPending = 1,
                            isEditFailed = 0,
                            editTransactionId = NULL,
                            pendingEditBody = NULL,
                            pendingEditZynaAttributesJSON = NULL
                        WHERE roomId = ?
                          AND eventId = ?
                          AND (isEditPending = 0
                               OR isEditFailed = 1
                               OR editTransactionId IS NOT NULL)
                    """,
                    arguments: [roomId, eventId]
                )
                return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
            }
            if didChange {
                logMessageEdit("pending event=\(eventId)")
                await refreshWindow()
            }
            return didChange
        } catch {
            logMessageEdit("failed to mark pending event=\(eventId): \(error)")
            return false
        }
    }

    @discardableResult
    private func bindPendingMessageEditTransaction(
        eventId: String,
        transactionId: String
    ) async -> Bool {
        do {
            let didChange = try await DatabaseService.shared.dbQueue.write { [roomId] db -> Bool in
                try db.execute(
                    sql: """
                        UPDATE storedMessage
                        SET editTransactionId = ?
                        WHERE roomId = ?
                          AND eventId = ?
                          AND isEditPending = 1
                          AND (editTransactionId IS NULL OR editTransactionId != ?)
                    """,
                    arguments: [transactionId, roomId, eventId, transactionId]
                )
                return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
            }
            if didChange {
                logMessageEdit("bound event=\(eventId) tx=\(transactionId)")
            }
            return didChange
        } catch {
            logMessageEdit("failed to bind pending edit event=\(eventId) tx=\(transactionId): \(error)")
            return false
        }
    }

    @discardableResult
    private func clearPendingMessageEdit(transactionId: String) async -> Bool {
        do {
            let didChange = try await DatabaseService.shared.dbQueue.write { [roomId] db -> Bool in
                try db.execute(
                    sql: """
                        UPDATE storedMessage
                        SET isEditPending = 0,
                            isEditFailed = 0,
                            editTransactionId = NULL,
                            pendingEditBody = NULL,
                            pendingEditZynaAttributesJSON = NULL
                        WHERE roomId = ?
                          AND editTransactionId = ?
                    """,
                    arguments: [roomId, transactionId]
                )
                return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
            }
            if didChange {
                logMessageEdit("confirmed tx=\(transactionId)")
                await refreshWindow()
            }
            return didChange
        } catch {
            logMessageEdit("failed to clear pending tx=\(transactionId): \(error)")
            return false
        }
    }

    @discardableResult
    private func clearPendingMessageEdit(eventId: String) async -> Bool {
        do {
            let didChange = try await DatabaseService.shared.dbQueue.write { [roomId] db -> Bool in
                try db.execute(
                    sql: """
                        UPDATE storedMessage
                        SET isEditPending = 0,
                            isEditFailed = 0,
                            editTransactionId = NULL,
                            pendingEditBody = NULL,
                            pendingEditZynaAttributesJSON = NULL
                        WHERE roomId = ?
                          AND eventId = ?
                    """,
                    arguments: [roomId, eventId]
                )
                return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
            }
            if didChange {
                logMessageEdit("cleared event=\(eventId)")
                await refreshWindow()
            }
            return didChange
        } catch {
            logMessageEdit("failed to clear pending event=\(eventId): \(error)")
            return false
        }
    }

    @discardableResult
    private func failPendingMessageEdit(transactionId: String) async -> Bool {
        do {
            let didChange = try await DatabaseService.shared.dbQueue.write { [roomId] db -> Bool in
                try db.execute(
                    sql: """
                        UPDATE storedMessage
                        SET isEditPending = 0,
                            isEditFailed = 1,
                            editTransactionId = NULL,
                            pendingEditBody = NULL,
                            pendingEditZynaAttributesJSON = NULL
                        WHERE roomId = ?
                          AND editTransactionId = ?
                    """,
                    arguments: [roomId, transactionId]
                )
                return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
            }
            if didChange {
                logMessageEdit("failed tx=\(transactionId)")
                await refreshWindow()
            }
            return didChange
        } catch {
            logMessageEdit("failed to mark edit failed tx=\(transactionId): \(error)")
            return false
        }
    }

    @discardableResult
    private func failPendingMessageEdit(eventId: String) async -> Bool {
        do {
            let didChange = try await DatabaseService.shared.dbQueue.write { [roomId] db -> Bool in
                try db.execute(
                    sql: """
                        UPDATE storedMessage
                        SET isEditPending = 0,
                            isEditFailed = 1,
                            editTransactionId = NULL,
                            pendingEditBody = NULL,
                            pendingEditZynaAttributesJSON = NULL
                        WHERE roomId = ?
                          AND eventId = ?
                    """,
                    arguments: [roomId, eventId]
                )
                return ((try Int.fetchOne(db, sql: "SELECT changes()")) ?? 0) > 0
            }
            if didChange {
                logMessageEdit("failed event=\(eventId)")
                await refreshWindow()
            }
            return didChange
        } catch {
            logMessageEdit("failed to mark edit failed event=\(eventId): \(error)")
            return false
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
            if receipt.retryableTransportFailure {
                let didChange = outgoingEnvelopes.markDispatchRetrying(
                    envelopeId: envelopeId,
                    itemIndex: itemIndex
                )
                OutgoingTextOutboxService.shared.kick(
                    reason: "retryable-failure",
                    envelopeId: envelopeId
                )
                if didChange {
                    await refreshWindow()
                }
                return
            }

            guard outgoingEnvelopes.markDispatchFailed(
                envelopeId: envelopeId,
                itemIndex: itemIndex
            ) else {
                return
            }
            publishSendFailureNotice(context: receipt.failureContext)
            await refreshWindow()
            return
        }

        let didMarkStarted = outgoingEnvelopes.markDispatchStarted(
            envelopeId: envelopeId,
            itemIndex: itemIndex
        )

        guard let transactionId = receipt.transactionId else {
            if didMarkStarted {
                await refreshWindow()
            }
            return
        }

        let didBindTransaction = outgoingEnvelopes.bindTransaction(
            envelopeId: envelopeId,
            itemIndex: itemIndex,
            transactionId: transactionId
        )
        let didBindEvent: Bool
        if let eventId = receipt.eventId {
            didBindEvent = outgoingEnvelopes.bindEvent(
                transactionId: transactionId,
                eventId: eventId
            )
        } else {
            didBindEvent = false
        }

        if didMarkStarted || didBindTransaction || didBindEvent {
            await refreshWindow()
        }
    }

    private func publishSendFailureNotice(context: OutgoingSendFailureContext?) {
        guard let context else { return }
        DispatchQueue.main.async { [weak self] in
            self?.sendFailureNotice = SendFailureNotice(context: context)
        }
    }

    private func publishSendFailureNotice(reason: OutgoingSendFailureReason?) {
        guard let reason else { return }
        publishSendFailureNotice(context: .reasonOnly(reason))
    }

    private func refreshComposerSendPermission() {
        let blocked = composerSendBlockedValue()
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isComposerSendBlocked != blocked else { return }
                self.isComposerSendBlocked = blocked
            }
            return
        }
        guard isComposerSendBlocked != blocked else { return }
        isComposerSendBlocked = blocked
    }

    private func composerSendBlockedValue() -> Bool {
        !mode.isPreview
            && requiresVerifiedDeviceForSending
            && !SessionVerificationService.shared.canSendEncryptedMessages
    }

    @discardableResult
    private func guardCanCreateOutgoingEnvelope() -> Bool {
        let blocked = composerSendBlockedValue()
        if Thread.isMainThread {
            if blocked != isComposerSendBlocked {
                isComposerSendBlocked = blocked
            }
        } else {
            refreshComposerSendPermission()
        }
        guard !blocked else {
            publishSendFailureNotice(reason: .ownDeviceVerificationRequired)
            return false
        }
        return true
    }

    private func sendOutgoingText(
        body: String,
        replyEventId: String? = nil,
        replyInfo: ReplyInfo? = nil,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes()
    ) async {
        let envelopeId = UUID().uuidString
        let transactionId = timelineService.prepareDirectRawTextTransactionId(
            replyEventId: replyEventId
        )
        let bindingToken = outgoingEnvelopes.createOutgoingText(
            roomId: roomId,
            envelopeId: envelopeId,
            body: body,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            transactionId: transactionId
        )
        await refreshWindow()

        if transactionId != nil {
            OutgoingTextOutboxService.shared.kick(
                reason: "new-envelope",
                envelopeId: envelopeId
            )
            return
        }

        let receipt: OutgoingDispatchReceipt
        if let replyEventId {
            receipt = await timelineService.sendReply(
                body,
                to: replyEventId,
                replyInfo: replyInfo,
                zynaAttributes: zynaAttributes,
                transactionId: transactionId,
                bindingToken: bindingToken
            )
        } else if zynaAttributes.isEmpty {
            receipt = await timelineService.sendMessage(
                body,
                bindingToken: bindingToken,
                transactionId: transactionId
            )
        } else {
            receipt = await timelineService.sendMessage(
                body,
                zynaAttributes: zynaAttributes,
                bindingToken: bindingToken,
                transactionId: transactionId
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
        let mimetype = "audio/mp4"
        let storedVoice = try? outgoingEnvelopes.storeOutgoingVoiceFile(
            sourceURL: fileURL,
            envelopeId: envelopeId
        )
        let transactionId = storedVoice == nil
            ? nil
            : DirectRawMediaSender.prepareVoiceTransactionId()
        let waveformPayload = waveform.map { sample -> UInt16 in
            let normalized = max(0, min(1, sample))
            return UInt16((normalized * 1024).rounded())
        }
        let bindingToken = outgoingEnvelopes.createOutgoingVoice(
            roomId: roomId,
            envelopeId: envelopeId,
            duration: duration,
            waveform: waveformPayload,
            localFileName: storedVoice?.fileName,
            replyInfo: nil,
            transactionId: transactionId
        )
        await refreshWindow()

        if let transactionId,
           let storedVoice {
            let didPrepare = PendingDirectVoiceService.shared.prepareVoice(
                envelopeId: envelopeId,
                itemIndex: 0,
                roomId: roomId,
                mimetype: mimetype
            )
            if didPrepare {
                OutgoingVoiceOutboxService.shared.kick(
                    reason: "new-voice",
                    envelopeId: envelopeId
                )
            } else {
                _ = outgoingEnvelopes.markDispatchFailed(
                    envelopeId: envelopeId,
                    itemIndex: 0
                )
                await refreshWindow()
            }
            _ = transactionId
            _ = storedVoice
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }

        let receipt = await timelineService.sendVoiceMessage(
            url: storedVoice?.url ?? fileURL,
            duration: duration,
            waveform: waveform,
            mimetype: mimetype,
            bindingToken: bindingToken
        )
        await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
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
        let transactionId = DirectRawMediaSender.prepareFileTransactionId()
        let bindingToken = outgoingEnvelopes.createOutgoingFile(
            roomId: roomId,
            envelopeId: envelopeId,
            filename: filename,
            mimetype: mimetype,
            size: fileSize,
            caption: caption,
            replyInfo: replyInfo,
            transactionId: transactionId
        )
        await refreshWindow()

        if let transactionId {
            let didPrepare = PendingDirectFileService.shared.prepareFile(
                envelopeId: envelopeId,
                itemIndex: 0,
                roomId: roomId,
                sourceURL: url,
                filename: filename,
                mimetype: mimetype ?? "application/octet-stream",
                size: fileSize
            )
            if didPrepare {
                OutgoingFileOutboxService.shared.kick(
                    reason: "new-file",
                    envelopeId: envelopeId
                )
            } else {
                _ = outgoingEnvelopes.markDispatchFailed(
                    envelopeId: envelopeId,
                    itemIndex: 0
                )
                await refreshWindow()
            }
            _ = transactionId
            return
        }

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
        guard let draft = forwardedMediaDraft(from: preview),
              let transactionId = DirectRawMediaSender.prepareForwardedMediaTransactionId()
        else {
            await sendOutgoingForwardedMediaLegacy(
                preview: preview,
                fallbackContent: fallbackContent,
                attrs: attrs,
                caption: caption,
                envelopeId: envelopeId
            )
            return
        }

        switch draft.kind {
        case .image:
            guard case .image(_, _, let width, let height, _, let previewImageData) = preview.content else {
                await timelineService.sendForwardedContent(fallbackContent)
                return
            }
            _ = outgoingEnvelopes.createOutgoingImage(
                roomId: roomId,
                envelopeId: envelopeId,
                caption: caption,
                width: width,
                height: height,
                previewImageData: previewImageData,
                previewSource: draft.source,
                replyInfo: nil,
                zynaAttributes: attrs
            )
        case .video:
            guard case .video(_, _, let width, let height, let duration, let filename, let mimetype, let size, _, let previewThumbnailData) = preview.content else {
                await timelineService.sendForwardedContent(fallbackContent)
                return
            }
            _ = outgoingEnvelopes.createOutgoingVideo(
                roomId: roomId,
                envelopeId: envelopeId,
                filename: filename,
                caption: caption,
                width: width,
                height: height,
                duration: duration,
                mimetype: mimetype,
                size: size,
                previewThumbnailData: previewThumbnailData,
                previewSource: draft.source,
                replyInfo: nil,
                zynaAttributes: attrs
            )
        case .voice:
            guard case .voice(_, let duration, let waveform) = preview.content else {
                await timelineService.sendForwardedContent(fallbackContent)
                return
            }
            _ = outgoingEnvelopes.createOutgoingVoice(
                roomId: roomId,
                envelopeId: envelopeId,
                duration: duration,
                waveform: waveform,
                previewSource: draft.source,
                replyInfo: nil,
                zynaAttributes: attrs
            )
        case .file:
            guard case .file(_, let filename, let mimetype, let size, _) = preview.content else {
                await timelineService.sendForwardedContent(fallbackContent)
                return
            }
            _ = outgoingEnvelopes.createOutgoingFile(
                roomId: roomId,
                envelopeId: envelopeId,
                filename: filename,
                mimetype: mimetype,
                size: size,
                caption: caption,
                previewSource: draft.source,
                replyInfo: nil,
                zynaAttributes: attrs
            )
        }
        await refreshWindow()

        let didPrepare = PendingForwardedMediaService.shared.prepareForwardedMedia(
            envelopeId: envelopeId,
            itemIndex: 0,
            roomId: roomId,
            draft: draft,
            caption: caption,
            transactionId: transactionId
        )
        if didPrepare {
            OutgoingForwardedMediaOutboxService.shared.kick(
                reason: "new-forwarded-media",
                envelopeId: envelopeId
            )
        } else {
            _ = outgoingEnvelopes.markDispatchFailed(
                envelopeId: envelopeId,
                itemIndex: 0
            )
            await refreshWindow()
        }
    }

    private func forwardedMediaDraft(
        from message: ChatMessage
    ) -> PendingForwardedMediaDraft? {
        switch message.content {
        case .image(let source?, let thumbnailSource, let width, let height, _, _):
            return PendingForwardedMediaDraft(
                kind: .image,
                source: source,
                thumbnailSource: thumbnailSource,
                filename: "image.jpg",
                mimetype: "image/jpeg",
                size: nil,
                width: width,
                height: height,
                duration: nil,
                waveform: []
            )
        case .video(let source?, let thumbnailSource, let width, let height, let duration, let filename, let mimetype, let size, _, _):
            return PendingForwardedMediaDraft(
                kind: .video,
                source: source,
                thumbnailSource: thumbnailSource,
                filename: filename,
                mimetype: mimetype ?? "video/mp4",
                size: size,
                width: width,
                height: height,
                duration: duration,
                waveform: []
            )
        case .voice(let source?, let duration, let waveform):
            return PendingForwardedMediaDraft(
                kind: .voice,
                source: source,
                thumbnailSource: nil,
                filename: "voice.m4a",
                mimetype: "audio/mp4",
                size: nil,
                width: nil,
                height: nil,
                duration: duration,
                waveform: waveform
            )
        case .file(let source?, let filename, let mimetype, let size, _):
            return PendingForwardedMediaDraft(
                kind: .file,
                source: source,
                thumbnailSource: nil,
                filename: filename,
                mimetype: mimetype ?? "application/octet-stream",
                size: size,
                width: nil,
                height: nil,
                duration: nil,
                waveform: []
            )
        default:
            return nil
        }
    }

    private func sendOutgoingForwardedMediaLegacy(
        preview: ChatMessage,
        fallbackContent: RoomMessageEventContentWithoutRelation,
        attrs: ZynaMessageAttributes,
        caption: String?,
        envelopeId: String
    ) async {
        switch preview.content {
        case .image(let source, _, let width, let height, _, let previewImageData):
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
        guard guardCanCreateOutgoingEnvelope() else { return }

        if let editing = editingMessage {
            guard let itemId = editing.itemIdentifier,
                  let originalBody = editing.content.textBody
            else {
                setEditingTarget(nil)
                return
            }

            let editedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !editedText.isEmpty else { return }
            guard editedText != originalBody.trimmingCharacters(in: .whitespacesAndNewlines) else {
                setEditingTarget(nil)
                return
            }

            editingMessage = nil
            activeEditAttemptId = nil
            editingDraftOverride = nil

            let attemptId = UUID()
            activeEditAttemptId = attemptId
            Task { [weak self] in
                guard let self else { return }
                if let eventId = editing.eventId,
                   let transactionId = DirectRawTextSender.prepareEditTransactionId(),
                   PendingMessageEditService.shared.prepareDirectRawEdit(
                       roomId: self.roomId,
                       eventId: eventId,
                       body: editedText,
                       zynaAttributes: editing.zynaAttributes,
                       transactionId: transactionId
                   ) {
                    await self.refreshWindow()
                    OutgoingEditOutboxService.shared.kick(reason: "new-edit")
                    await MainActor.run {
                        guard self.activeEditAttemptId == attemptId else { return }
                        self.activeEditAttemptId = nil
                    }
                    return
                }

                if let eventId = editing.eventId {
                    await self.markMessageEditPending(eventId: eventId)
                }

                let receipt = await self.timelineService.editMessage(
                    editedText,
                    itemId: itemId,
                    zynaAttributes: editing.zynaAttributes
                )

                if let eventId = editing.eventId {
                    if receipt.acceptedByTransport {
                        if let transactionId = receipt.transactionId,
                           await self.hasRecentlySentTransaction(transactionId) {
                            await self.clearPendingMessageEdit(eventId: eventId)
                        } else if let transactionId = receipt.transactionId,
                                  await self.hasRecentlyFailedTransaction(transactionId) {
                            await self.failPendingMessageEdit(eventId: eventId)
                        } else if let transactionId = receipt.transactionId {
                            await self.bindPendingMessageEditTransaction(
                                eventId: eventId,
                                transactionId: transactionId
                            )
                        }
                    } else {
                        await self.clearPendingMessageEdit(eventId: eventId)
                    }
                }

                await MainActor.run {
                    guard self.activeEditAttemptId == attemptId else { return }
                    self.activeEditAttemptId = nil
                    guard !receipt.acceptedByTransport else { return }
                    guard self.canRestoreFailedEditDraft?() ?? true else { return }
                    self.editingDraftOverride = editedText
                    self.replyingTo = nil
                    self.pendingForwardContent = nil
                    self.editingMessage = editing
                }
            }
            return
        }

        activeEditAttemptId = nil
        editingDraftOverride = nil

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
            let attrs = color.map { ZynaMessageAttributes(color: $0) }
                ?? ZynaMessageAttributes()
            Task { [weak self] in
                await self?.sendOutgoingText(
                    body: text,
                    replyEventId: eventId,
                    replyInfo: replyInfo,
                    zynaAttributes: attrs
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
        guard guardCanCreateOutgoingEnvelope() else { return }

        Task { [weak self] in
            await self?.sendOutgoingVoice(
                fileURL: fileURL,
                duration: duration,
                waveform: waveform
            )
        }
    }

    func sendFile(url: URL) {
        guard guardCanCreateOutgoingEnvelope() else { return }

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
        guard guardCanCreateOutgoingEnvelope() else { return }

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
        guard guardCanCreateOutgoingEnvelope() else { return }

        let videoCount = attachments.filter(\.isVideo).count
        if videoCount > 0 {
            logVideoSend(
                "sendComposerAttachments total=\(attachments.count) videos=\(videoCount) caption=\(caption ?? "<nil>")"
            )
        }

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
                case .video(let video):
                    logVideoSend(
                        "sendComposerAttachments item index=\(index) video=\(video.filename) bytes=\(video.size) size=\(video.width)x\(video.height) duration=\(String(format: "%.3f", video.duration))"
                    )
                    await self.sendSingleVideo(
                        video,
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
        let transactionId = DirectRawMediaSender.prepareImageTransactionId()
        let bindingToken = outgoingEnvelopes.createOutgoingImage(
            roomId: roomId,
            envelopeId: envelopeId,
            caption: caption,
            width: image.width,
            height: image.height,
            previewImageData: image.thumbnailData,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            transactionId: transactionId
        )
        await refreshWindow()

        if let transactionId {
            let didPrepare = PendingDirectImageService.shared.prepareImage(
                envelopeId: envelopeId,
                itemIndex: 0,
                roomId: roomId,
                image: image
            )
            if didPrepare {
                OutgoingImageOutboxService.shared.kick(
                    reason: "new-image",
                    envelopeId: envelopeId
                )
            } else {
                _ = outgoingEnvelopes.markDispatchFailed(
                    envelopeId: envelopeId,
                    itemIndex: 0
                )
                await refreshWindow()
            }
            _ = transactionId
            return
        }

        let receipt = await timelineService.sendImage(
            image: image,
            caption: caption,
            zynaAttributes: zynaAttributes,
            replyEventId: replyEventId,
            bindingToken: bindingToken
        )
        await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)
    }

    private func sendSingleVideo(
        _ video: ProcessedVideo,
        caption: String?,
        replyEventId: String?,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes
    ) async {
        let envelopeId = UUID().uuidString
        let transactionId = DirectRawMediaSender.prepareVideoTransactionId()
        logVideoSend(
            "singleVideo start envelope=\(envelopeId) filename=\(video.filename) bytes=\(video.size) size=\(video.width)x\(video.height) duration=\(String(format: "%.3f", video.duration)) caption=\(caption ?? "<nil>") reply=\(replyEventId ?? "<nil>") attrsEmpty=\(zynaAttributes.isEmpty)"
        )
        let bindingToken = outgoingEnvelopes.createOutgoingVideo(
            roomId: roomId,
            envelopeId: envelopeId,
            filename: video.filename,
            caption: caption,
            width: video.width,
            height: video.height,
            duration: video.duration,
            mimetype: video.mimetype,
            size: video.size,
            previewThumbnailData: video.thumbnailData,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
            transactionId: transactionId
        )
        logVideoSend(
            "singleVideo envelopeCreated envelope=\(envelopeId) bindingToken=\(bindingToken.isEmpty ? "<empty>" : bindingToken) tx=\(transactionId ?? "<nil>") thumbBytes=\(video.thumbnailSize)"
        )
        await refreshWindow()

        if let transactionId {
            let didPrepare = PendingDirectVideoService.shared.prepareVideo(
                envelopeId: envelopeId,
                itemIndex: 0,
                roomId: roomId,
                video: video
            )
            if didPrepare {
                OutgoingVideoOutboxService.shared.kick(
                    reason: "new-video",
                    envelopeId: envelopeId
                )
                cleanupProcessedVideoFiles(video, delay: 10)
            } else {
                _ = outgoingEnvelopes.markDispatchFailed(
                    envelopeId: envelopeId,
                    itemIndex: 0
                )
                cleanupProcessedVideoFiles(video)
                await refreshWindow()
            }
            _ = transactionId
            return
        }

        let receipt = await timelineService.sendVideo(
            video: video,
            caption: caption,
            zynaAttributes: zynaAttributes,
            replyEventId: replyEventId,
            bindingToken: bindingToken
        )
        logVideoSend(
            "singleVideo receipt envelope=\(envelopeId) accepted=\(receipt.acceptedByTransport) tx=\(receipt.transactionId ?? "<nil>")"
        )
        await completeOutgoingDispatch(envelopeId: envelopeId, receipt: receipt)
    }

    private func cleanupProcessedVideoFiles(_ video: ProcessedVideo, delay: TimeInterval = 0) {
        let videoURL = video.videoURL
        let thumbnailURL = video.thumbnailURL
        let workingDirectoryURL = video.videoURL.deletingLastPathComponent()
        let cleanup = {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            try? FileManager.default.removeItem(at: workingDirectoryURL)
        }

        if delay > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: cleanup)
        } else {
            DispatchQueue.global(qos: .utility).async(execute: cleanup)
        }
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
                        imageData: image.thumbnailData,
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
        let directTransactionIds: [String]? = {
            guard DirectRawMediaSender.isImageEnabled else { return nil }
            var transactionIds: [String] = []
            transactionIds.reserveCapacity(images.count)
            for _ in images {
                guard let transactionId = DirectRawMediaSender.prepareImageTransactionId() else {
                    return nil
                }
                transactionIds.append(transactionId)
            }
            return transactionIds
        }()
        let bindingTokens = outgoingEnvelopes.createOutgoingMediaBatch(
            roomId: roomId,
            envelopeId: mediaGroupId,
            caption: normalizedCaption,
            captionPlacement: captionPlacement,
            layoutOverride: layoutOverride,
            items: images.enumerated().map { index, image in
                OutgoingMediaDraftItem(
                    previewImageData: image.thumbnailData,
                    width: image.width,
                    height: image.height,
                    transactionId: directTransactionIds?[index]
                )
            },
            replyInfo: replyInfo
        )
        await refreshWindow()

        if directTransactionIds != nil {
            var didPrepareAll = true
            for (index, image) in images.enumerated() {
                let didPrepare = PendingDirectImageService.shared.prepareImage(
                    envelopeId: mediaGroupId,
                    itemIndex: index,
                    roomId: roomId,
                    image: image
                )
                didPrepareAll = didPrepareAll && didPrepare
            }

            if didPrepareAll {
                OutgoingImageOutboxService.shared.kick(
                    reason: "new-image-batch",
                    envelopeId: mediaGroupId
                )
            } else {
                for index in images.indices {
                    _ = outgoingEnvelopes.markDispatchFailed(
                        envelopeId: mediaGroupId,
                        itemIndex: index
                    )
                }
                await refreshWindow()
            }
            return
        }

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
                image: image,
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
        guard guardCanCreateOutgoingEnvelope() else { return }
        if let targetEventId = message.eventId,
           !targetEventId.isEmpty,
           DirectRawTextSender.isEnabled {
            let hasOwnReaction = message.reactions.contains {
                $0.key == key && $0.isOwn
            }
            let didPrepare = hasOwnReaction
                ? pendingReactions.prepareDirectRawRemoval(
                    roomId: roomId,
                    targetEventId: targetEventId,
                    key: key
                )
                : pendingReactions.prepareDirectRawAdd(
                    roomId: roomId,
                    targetEventId: targetEventId,
                    key: key
                )
            if didPrepare {
                Task { [weak self] in
                    await self?.refreshWindow()
                }
                OutgoingReactionOutboxService.shared.kick(reason: "new-reaction")
                return
            }
        }

        guard let itemId = message.itemIdentifier else { return }
        Task {
            await timelineService.toggleReaction(key, to: itemId)
        }
    }

    func discardOutgoingEnvelope(id envelopeId: String) {
        outgoingEnvelopes.deleteEnvelopes(ids: [envelopeId])
        Task { [weak self] in
            await self?.refreshWindow()
        }
    }

    func clearSendFailureNotice(id: UUID) {
        guard sendFailureNotice?.id == id else { return }
        sendFailureNotice = nil
    }

    @MainActor
    func makeRoomSendSecurityViewModel(
        context: OutgoingSendFailureContext
    ) -> RoomSendSecurityViewModel {
        RoomSendSecurityViewModel(room: room, context: context)
    }

    func handleBlockedComposerInteraction() {
        guard guardCanCreateOutgoingEnvelope() == false else { return }
    }

    func retryOutgoingEnvelope(id envelopeId: String) {
        Task { [weak self] in
            await self?.retryOutgoingEnvelopeNow(id: envelopeId)
        }
    }

    private func retryOutgoingEnvelopeNow(id envelopeId: String) async {
        guard let envelope = outgoingEnvelopes.envelope(id: envelopeId, roomId: roomId),
              envelope.isRetryableAfterSessionChange
        else {
            return
        }
        guard guardCanCreateOutgoingEnvelope() else { return }

        switch envelope.payload {
        case .text(let payload):
            await retryTextEnvelope(envelope, body: payload.body)
        case .voice(let payload):
            await retryVoiceEnvelope(envelope, payload: payload)
        default:
            return
        }
    }

    private func retryTextEnvelope(
        _ envelope: OutgoingEnvelopeSnapshot,
        body: String
    ) async {
        let retryEnvelopeId = UUID().uuidString
        let transactionId = timelineService.prepareDirectRawTextTransactionId(
            replyEventId: envelope.replyInfo?.eventId,
            existingTransactionId: envelope.items.first?.transactionId
        )
        let bindingToken = outgoingEnvelopes.createOutgoingText(
            roomId: roomId,
            envelopeId: retryEnvelopeId,
            body: body,
            replyInfo: envelope.replyInfo,
            zynaAttributes: envelope.zynaAttributes,
            transactionId: transactionId
        )
        outgoingEnvelopes.deleteEnvelopes(ids: [envelope.id])
        await refreshWindow()

        if transactionId != nil {
            OutgoingTextOutboxService.shared.kick(
                reason: "manual-retry",
                envelopeId: retryEnvelopeId
            )
            return
        }

        let receipt: OutgoingDispatchReceipt
        if let replyEventId = envelope.replyInfo?.eventId {
            receipt = await timelineService.sendReply(
                body,
                to: replyEventId,
                replyInfo: envelope.replyInfo,
                zynaAttributes: envelope.zynaAttributes,
                transactionId: transactionId,
                bindingToken: bindingToken
            )
        } else if envelope.zynaAttributes.isEmpty {
            receipt = await timelineService.sendMessage(
                body,
                bindingToken: bindingToken,
                transactionId: transactionId
            )
        } else {
            receipt = await timelineService.sendMessage(
                body,
                zynaAttributes: envelope.zynaAttributes,
                bindingToken: bindingToken,
                transactionId: transactionId
            )
        }

        await completeOutgoingDispatch(envelopeId: retryEnvelopeId, receipt: receipt)
    }

    private func retryVoiceEnvelope(
        _ envelope: OutgoingEnvelopeSnapshot,
        payload: OutgoingVoicePayload
    ) async {
        let retryEnvelopeId = UUID().uuidString
        guard let localFileName = payload.localFileName,
              let storedVoice = try? outgoingEnvelopes.copyOutgoingVoiceFile(
                fileName: localFileName,
                envelopeId: retryEnvelopeId
              )
        else {
            return
        }

        let transactionId = envelope.zynaAttributes.isEmpty
            ? DirectRawMediaSender.prepareVoiceTransactionId()
            : nil
        let bindingToken = outgoingEnvelopes.createOutgoingVoice(
            roomId: roomId,
            envelopeId: retryEnvelopeId,
            duration: payload.duration,
            waveform: payload.waveform,
            localFileName: storedVoice.fileName,
            replyInfo: envelope.replyInfo,
            zynaAttributes: envelope.zynaAttributes,
            transactionId: transactionId
        )
        outgoingEnvelopes.deleteEnvelopes(ids: [envelope.id])
        await refreshWindow()

        if transactionId != nil {
            let didPrepare = PendingDirectVoiceService.shared.prepareVoice(
                envelopeId: retryEnvelopeId,
                itemIndex: 0,
                roomId: roomId,
                mimetype: "audio/mp4"
            )
            if didPrepare {
                OutgoingVoiceOutboxService.shared.kick(
                    reason: "retry-voice",
                    envelopeId: retryEnvelopeId
                )
            } else {
                _ = outgoingEnvelopes.markDispatchFailed(
                    envelopeId: retryEnvelopeId,
                    itemIndex: 0
                )
                await refreshWindow()
            }
            return
        }

        let waveform = payload.waveform.map { sample in
            Float(sample) / 1024
        }
        let receipt = await timelineService.sendVoiceMessage(
            url: storedVoice.url,
            duration: payload.duration,
            waveform: waveform,
            zynaAttributes: envelope.zynaAttributes,
            bindingToken: bindingToken
        )
        await completeOutgoingDispatch(envelopeId: retryEnvelopeId, receipt: receipt)
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
        let intents = items.compactMap { item -> PendingRedactionIntent? in
            guard let itemIdentifier = item.itemIdentifier else { return nil }
            return PendingRedactionIntent(
                messageId: item.messageId,
                roomId: roomId,
                itemIdentifier: itemIdentifier
            )
        }
        guard !intents.isEmpty else { return }
        guard guardCanCreateOutgoingEnvelope() else { return }
        pendingRedactions.register(intents)
        pendingRedactionIds.formUnion(intents.map(\.messageId))
        pendingRedactionKeys.formUnion(
            intents.map {
                MessageIdentity.from(
                    messageId: $0.messageId,
                    itemIdentifier: $0.itemIdentifier
                ).key
            }
        )
        schedulePendingRedactionPlaceholderRefresh()
        OutgoingRedactionOutboxService.shared.kick(reason: "new-redaction")
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for intent in intents {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.pendingRedactions.attempt(
                                intent,
                                timelineService: self.timelineService
                            )
                        } catch {
                            await MainActor.run {
                                let attemptError = error as? PendingRedactionAttemptError
                                self.onRedactionFailed?(
                                    intent.messageId,
                                    attemptError?.underlyingError ?? error,
                                    attemptError?.disposition ?? .retryable
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func redactItemIdentifier(_ itemId: ChatItemIdentifier, messageId: String) {
        guard guardCanCreateOutgoingEnvelope() else { return }
        let intent = PendingRedactionIntent(
            messageId: messageId,
            roomId: roomId,
            itemIdentifier: itemId
        )
        pendingRedactions.register([intent])
        pendingRedactionIds.insert(messageId)
        pendingRedactionKeys.insert(
            MessageIdentity.from(messageId: messageId, itemIdentifier: itemId).key
        )
        schedulePendingRedactionPlaceholderRefresh()
        OutgoingRedactionOutboxService.shared.kick(reason: "new-redaction")
        Task {
            do {
                try await pendingRedactions.attempt(
                    intent,
                    timelineService: timelineService
                )
            } catch {
                await MainActor.run {
                    let attemptError = error as? PendingRedactionAttemptError
                    onRedactionFailed?(
                        messageId,
                        attemptError?.underlyingError ?? error,
                        attemptError?.disposition ?? .retryable
                    )
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

        let storedMessages = window.currentStoredMessages()
        let keysToHide = Self.identityKeys(for: idsToHide, in: storedMessages)
        hiddenMessageKeys.formUnion(keysToHide)
        for identityKey in keysToHide {
            pendingPartialRedactions.removeValue(forKey: identityKey)
        }
        for messageId in idsToHide {
            partialReflowPreviewsByMessageId.removeValue(forKey: messageId)
        }
        let oldRows = rows
        let oldMessages = messages
        var visibleRedactedKeys = Set(
            oldMessages
                .filter { $0.content.isRedacted }
                .flatMap(\.timelineIdentityKeys)
        )
        visibleRedactedKeys.subtract(keysToHide)
        let now = Date().timeIntervalSince1970
        let pendingRedactionRecords = pendingRedactions.pendingRecords(roomId: roomId)
        let pendingRedactionLookup = Self.pendingRedactionDisplayLookup(
            for: pendingRedactionRecords
        )
        schedulePendingRedactionPlaceholderRefresh(
            records: pendingRedactionRecords,
            now: now
        )
        let pendingReactionRemovalsByEventId = pendingReactions
            .pendingRemovalKeysByEventId(roomId: roomId)
        let rawMessages = storedMessages.compactMap { msg -> ChatMessage? in
            displayChatMessage(
                for: msg,
                pendingRedactionLookup: pendingRedactionLookup,
                pendingReactionRemovalsByEventId: pendingReactionRemovalsByEventId,
                now: now,
                visibleRedactedKeys: visibleRedactedKeys
            )
        }
        let deletedMediaGroupIds = Self.redactedMediaGroupIds(in: storedMessages)
        logMediaGroup(
            "deleteReflow hide messageIds=\(idsToHide.sorted().joined(separator: ",")) visibleRedactedKeys=\(visibleRedactedKeys.sorted().joined(separator: ",")) deletedGroups=\(deletedMediaGroupIds.sorted().joined(separator: ","))"
        )
        let olderBoundary = window.peekOlderNeighbor()
        let newerBoundary = window.peekNewerNeighbor()
        let newMessages = buildRenderableMessages(
            from: rawMessages,
            deletedMediaGroupIds: deletedMediaGroupIds,
            partialReflowPreviewsByMessageId: partialReflowPreviewsByMessageId,
            olderBoundary: olderBoundary,
            newerBoundary: newerBoundary
        )
        setMessages(newMessages, olderBoundary: olderBoundary)

        let (tableUpdate, inPlaceUpdates) = Self.computeTableUpdate(old: oldRows, new: rows)
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
        pendingRedactionPlaceholderWork?.cancel()
        readReceiptWork?.cancel()
        pendingReadReceiptSend = nil
        if !mode.isPreview {
            PresenceTracker.shared.unregister(for: "chat")
        }
        timelineService.onDiffs = nil
        timelineService.onOwnFullyReadMarker = nil
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
        if !Calendar.current.isDate(current.timestamp, inSameDayAs: neighbor.timestamp) { return true }
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
        let previewHydratedMessages = rawMessages.map { message in
            message.applyingPreviewImageData(
                partialReflowPreviewsByMessageId[message.id]?.imageData
            )
        }

        let normalized = previewHydratedMessages.map { message -> ChatMessage in
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
                guard case .image(let source, let thumbnailSource, let width, let height, let caption, _) = message.content else {
                    return nil
                }
                return MediaGroupItem(
                    messageId: message.id,
                    eventId: message.eventId,
                    transactionId: message.transactionId,
                    source: source,
                    thumbnailSource: thumbnailSource,
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

    private static func identityKeys(
        for messageIds: Set<String>,
        in storedMessages: [StoredMessage]
    ) -> Set<String> {
        guard !messageIds.isEmpty else { return [] }
        let storedById = Dictionary(
            storedMessages.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        var identityKeys = Set<String>()
        for messageId in messageIds {
            if let stored = storedById[messageId] {
                identityKeys.formUnion(stored.timelineIdentityKeys)
            } else {
                identityKeys.insert(MessageIdentity.local(messageId).key)
            }
        }
        return identityKeys
    }

    func timelineIdentityKeys(for messageIds: Set<String>) -> Set<String> {
        Self.identityKeys(for: messageIds, in: window.currentStoredMessages())
    }

    private func displayChatMessage(
        for message: StoredMessage,
        pendingRedactionLookup: PendingRedactionDisplayLookup,
        pendingReactionRemovalsByEventId: [String: Set<String>],
        now: TimeInterval,
        visibleRedactedKeys: Set<String>
    ) -> ChatMessage? {
        if Self.hasAnyIdentityKey(hiddenMessageKeys, for: message) { return nil }
        if let pendingPlaceholder = pendingRedactionPlaceholder(
            for: message,
            lookup: pendingRedactionLookup,
            now: now
        ) {
            return pendingPlaceholder
        }
        if let pending = Self.pendingPartialRedaction(
            for: message,
            in: pendingPartialRedactions
        ) {
            return pending.toChatMessage().map {
                Self.markPendingReactionRemovals(
                    in: $0,
                    removalsByEventId: pendingReactionRemovalsByEventId
                )
            }
        }
        if Self.hasAnyIdentityKey(pendingRedactionKeys, for: message) { return nil }
        if message.contentType == "redacted",
           message.timelineIdentityKeys.isDisjoint(with: visibleRedactedKeys) {
            return nil
        }
        return message.toChatMessage().map {
            Self.markPendingReactionRemovals(
                in: $0,
                removalsByEventId: pendingReactionRemovalsByEventId
            )
        }
    }

    private static func markPendingReactionRemovals(
        in message: ChatMessage,
        removalsByEventId: [String: Set<String>]
    ) -> ChatMessage {
        guard let eventId = message.eventId,
              let keys = removalsByEventId[eventId],
              !keys.isEmpty else {
            return message
        }

        var didChange = false
        let reactions = message.reactions.map { reaction in
            guard reaction.isOwn,
                  keys.contains(reaction.key),
                  !reaction.isPendingRemoval else {
                return reaction
            }
            didChange = true
            return MessageReaction(
                key: reaction.key,
                senders: reaction.senders,
                isOwn: reaction.isOwn,
                isPendingRemoval: true,
                legacyCount: reaction.legacyCount
            )
        }

        return didChange ? message.applyingReactions(reactions) : message
    }

    private func pendingRedactionPlaceholder(
        for message: StoredMessage,
        lookup: PendingRedactionDisplayLookup,
        now: TimeInterval
    ) -> ChatMessage? {
        guard let record = Self.pendingRedactionRecord(for: message, in: lookup),
              now - record.createdAt >= Self.pendingRedactionPlaceholderDelay
        else {
            return nil
        }

        return ChatMessage(
            id: "pending-redaction:\(record.messageId)",
            eventId: nil,
            transactionId: nil,
            itemIdentifier: nil,
            senderId: message.senderId,
            senderDisplayName: nil,
            senderAvatarUrl: nil,
            isOutgoing: false,
            timestamp: Date(timeIntervalSince1970: message.timestamp),
            content: .systemEvent(
                text: String(localized: "Deleting message..."),
                kind: .roomState
            ),
            reactions: [],
            replyInfo: nil,
            isEditable: false,
            isEdited: false,
            isEditPending: false,
            isEditFailed: false,
            latestEditEventId: nil,
            zynaAttributes: ZynaMessageAttributes(),
            sendStatus: "sent"
        )
    }

    private static func pendingRedactionRecord(
        for message: StoredMessage,
        in lookup: PendingRedactionDisplayLookup
    ) -> PendingRedactionRecord? {
        if let record = lookup.byMessageId[message.id] {
            return record
        }

        for identityKey in message.timelineIdentityKeys {
            if let record = lookup.byIdentityKey[identityKey] {
                return record
            }
        }
        return nil
    }

    private static func pendingRedactionDisplayLookup(
        for records: [PendingRedactionRecord]
    ) -> PendingRedactionDisplayLookup {
        var byMessageId: [String: PendingRedactionRecord] = [:]
        var byIdentityKey: [String: PendingRedactionRecord] = [:]

        for record in records {
            byMessageId[record.messageId] = record
            byIdentityKey[MessageIdentity.local(record.messageId).key] = record
            if let itemIdentifier = record.itemIdentifier {
                byIdentityKey[
                    MessageIdentity.from(
                        messageId: record.messageId,
                        itemIdentifier: itemIdentifier
                    ).key
                ] = record
            }
        }

        return PendingRedactionDisplayLookup(
            byMessageId: byMessageId,
            byIdentityKey: byIdentityKey
        )
    }

    private func schedulePendingRedactionPlaceholderRefresh(
        records: [PendingRedactionRecord]? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        pendingRedactionPlaceholderWork?.cancel()

        let records = records ?? pendingRedactions.pendingRecords(roomId: roomId)
        let nextDelay = records
            .map { $0.createdAt + Self.pendingRedactionPlaceholderDelay - now }
            .filter { $0 > 0 }
            .min()

        guard let nextDelay else {
            pendingRedactionPlaceholderWork = nil
            return
        }

        let work = DispatchWorkItem { [weak self] in
            Task { [weak self] in
                await self?.refreshWindow()
            }
        }
        pendingRedactionPlaceholderWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.05, nextDelay),
            execute: work
        )
    }

    private static func hasAnyIdentityKey(
        _ keys: Set<String>,
        for message: StoredMessage
    ) -> Bool {
        !message.timelineIdentityKeys.isDisjoint(with: keys)
    }

    private static func pendingPartialRedaction(
        for message: StoredMessage,
        in pending: [String: StoredMessage]
    ) -> StoredMessage? {
        for identityKey in message.timelineIdentityKeys {
            if let redaction = pending[identityKey] {
                return redaction
            }
        }
        return nil
    }

    private static func isSplashEligiblePreviousContent(_ message: StoredMessage) -> Bool {
        guard message.contentType != "redacted" else { return false }
        switch message.contentType {
        case "text", "notice", "emote":
            let body = (message.contentBody ?? "")
                .replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !body.isEmpty
        case "image", "video", "voice", "file":
            return true
        default:
            return false
        }
    }

    private static func preferredTransitionPrevious(
        _ existing: StoredMessage,
        _ candidate: StoredMessage
    ) -> StoredMessage {
        let existingEligible = isSplashEligiblePreviousContent(existing)
        let candidateEligible = isSplashEligiblePreviousContent(candidate)
        if existingEligible != candidateEligible {
            return existingEligible ? existing : candidate
        }
        if existing.timestamp != candidate.timestamp {
            return existing.timestamp > candidate.timestamp ? existing : candidate
        }
        return existing.id > candidate.id ? existing : candidate
    }

    private static func previousMessage(
        for redactedMessage: StoredMessage,
        in previousByIdentity: [String: StoredMessage]
    ) -> StoredMessage? {
        redactedMessage.timelineIdentityKeys
            .compactMap { previousByIdentity[$0] }
            .reduce(nil) { current, candidate in
                current.map { preferredTransitionPrevious($0, candidate) } ?? candidate
            }
    }

    private static func animationEligibleRedactions(
        candidates: [RedactionTransitionCandidate],
        origin: MessageWindowChangeOrigin,
        previousDisplayIdentityKeys: Set<String>,
        pendingRedactionKeys: Set<String>
    ) -> [RedactionTransitionCandidate] {
        candidates.filter { candidate in
            if !candidate.identityKeys.isDisjoint(with: pendingRedactionKeys) {
                return true
            }
            return origin.allowsRemoteRedactionAnimation
                && !candidate.identityKeys.isDisjoint(with: previousDisplayIdentityKeys)
        }
    }

    private static func logTimelineHealth(
        origin: MessageWindowChangeOrigin,
        newStored: [StoredMessage],
        prevStored: [StoredMessage]?,
        redactionCandidates: [RedactionTransitionCandidate],
        animatedRedactions: [RedactionTransitionCandidate]
    ) {
        var duplicateIdentityCounts: [String: Int] = [:]
        for message in newStored {
            for identityKey in message.timelineIdentityKeys {
                duplicateIdentityCounts[identityKey, default: 0] += 1
            }
        }
        let duplicateKeys = duplicateIdentityCounts
            .filter { $0.value > 1 }
            .keys
            .sorted()

        let suppressedRedactions = redactionCandidates.count - animatedRedactions.count

        var redactionRegressions: [String] = []
        if let prevStored {
            let previousByKey = Dictionary(
                prevStored.flatMap { stored in
                    stored.timelineIdentityKeys.map { ($0, stored) }
                },
                uniquingKeysWith: { existing, candidate in
                    existing.timestamp >= candidate.timestamp ? existing : candidate
                }
            )
            for message in newStored where message.contentType != "redacted" {
                if message.timelineIdentityKeys.contains(where: {
                    previousByKey[$0]?.contentType == "redacted"
                }) {
                    redactionRegressions.append(message.timelineIdentityKey)
                }
            }
        }

        guard !duplicateKeys.isEmpty
            || suppressedRedactions > 0
            || !redactionRegressions.isEmpty
        else {
            return
        }

        timelineHealthLog(
            "origin=\(origin.compactDescription) suppressedRedactions=\(suppressedRedactions) animatedRedactions=\(animatedRedactions.count) duplicateKeys=\(duplicateKeys.prefix(6).joined(separator: ",")) redactionRegressions=\(redactionRegressions.prefix(6).joined(separator: ","))"
        )
    }

    private static func registerPendingPartialRedactions(
        into pendingPartialRedactions: inout [String: StoredMessage],
        newStored: [StoredMessage],
        animatedRedactions: [RedactionTransitionCandidate],
        hiddenMessageKeys: Set<String>
    ) {
        let existingKeys = Set(newStored.flatMap(\.timelineIdentityKeys))
        pendingPartialRedactions = pendingPartialRedactions.filter {
            !hiddenMessageKeys.contains($0.key) && existingKeys.contains($0.key)
        }

        for redaction in animatedRedactions {
            let previous = redaction.previous
            guard previous.contentType == "image",
                  let mediaGroupId = previous.toChatMessage()?.zynaAttributes.mediaGroup?.id
            else {
                continue
            }
            for identityKey in redaction.identityKeys {
                guard pendingPartialRedactions[identityKey] == nil else { continue }
                pendingPartialRedactions[identityKey] = previous
            }
            logMediaGroup(
                "deleteReflow pending messageId=\(redaction.message.id) key=\(redaction.identityKey) group=\(mediaGroupId)"
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
        redactions: [RedactionTransitionCandidate],
        newStored: [StoredMessage],
        prevStored: [StoredMessage]
    ) -> DetectedRedactionBatch {
        guard !redactions.isEmpty else {
            return DetectedRedactionBatch(messageIds: [], mediaGroups: [])
        }

        let newlyRedactedIds = redactions.map(\.message.id)
        let identityKeys = Set(redactions.flatMap(\.identityKeys))
        let remainingLiveCounts = liveImageCountByMediaGroup(in: newStored)
        var groupedMessageIds: [String: Set<String>] = [:]
        var groupedAllMessageIds: [String: Set<String>] = [:]
        var groupedTotals: [String: Int] = [:]
        var groupOrder: [String] = []

        for redaction in redactions {
            let messageId = redaction.message.id
            let previous = redaction.previous
            guard previous.contentType == "image",
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
            mediaGroups: mediaGroups,
            identityKeys: identityKeys
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
            guard case .image(let source?, let thumbnailSource, let width, let height, _, _) = message.content else { continue }
            let displaySource = thumbnailSource ?? source
            guard MediaCache.shared.bubbleImage(
                for: displaySource,
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
                    source: displaySource,
                    maxPixelWidth: maxPixelWidth,
                    maxPixelHeight: maxPixelHeight,
                    knownAspectRatio: knownAspectRatio
                )
            }
        }
    }
}
