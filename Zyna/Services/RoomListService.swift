//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK
import GRDB

// MARK: - Room Summary (UI-friendly model)

struct RoomSummary: Identifiable {
    let id: String
    let displayName: String
    let avatarURL: String?
    let lastMessage: String?
    let lastMessageTimestamp: Date?
    let unreadCount: UInt64
    let unreadMentionCount: UInt64
    let isMarkedUnread: Bool
    let isEncrypted: Bool
    /// Matrix user ID of the other person in a DM room, nil for group rooms.
    let directUserId: String?
}

private let logRooms = ScopedLog(.rooms)

// MARK: - Room List Service

final class ZynaRoomListService: NSObject {

    let roomsSubject = CurrentValueSubject<[RoomSummary], Never>([])

    private let matrixService = MatrixClientService.shared
    private var roomListService: RoomListService?
    private var roomList: RoomList?
    private var listUpdatesResult: RoomListEntriesWithDynamicAdaptersResult?
    private var loadingStateStreamHandle: TaskHandle?
    private var serviceStateHandle: TaskHandle?
    private var rooms: [Room] = []
    private var publishedSummariesByRoomId: [String: RoomSummary] = [:]
    private var locallyHiddenRoomIds = Set<String>()
    private var rebuildTask: Task<Void, Never>?
    private var rebuildRevision: UInt64 = 0
    private var isListening = false

    func room(for id: String) -> Room? {
        if let cached = rooms.first(where: { $0.id() == id }) {
            return cached
        }
        // Rooms from GRDB cache may be visible before the SDK room
        // list populates. Fall back to the client directly.
        if let room = try? MatrixClientService.shared.client?.getRoom(roomId: id) {
            return room
        }
        return MatrixClientService.shared.client?.rooms().first { $0.id() == id }
    }

    func removeRoomLocally(roomId: String, purgeTimeline: Bool = true) {
        locallyHiddenRoomIds.insert(roomId)
        rebuildRevision &+= 1
        rebuildTask?.cancel()

        let summaries = roomsSubject.value.filter { $0.id != roomId }
        publishedSummariesByRoomId = Dictionary(
            summaries.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        roomsSubject.send(summaries)

        Self.removeRoomFromGRDB(roomId: roomId, purgeTimeline: purgeTimeline)
    }
    private var cancellables = Set<AnyCancellable>()

    private static let writeQueue = DispatchQueue(label: "com.zyna.db.rooms", qos: .userInitiated)
    private static let latestEventSettleDelay: Duration = .milliseconds(150)

    override init() {
        super.init()
        loadCachedRooms()
        observeClientState()
    }

    private func loadCachedRooms() {
        let dbQueue = DatabaseService.shared.dbQueue
        guard let stored = try? dbQueue.read({ db in
            try StoredRoom.order(Column("sortOrder").asc).fetchAll(db)
        }), !stored.isEmpty else { return }

        let summaries = stored.map { $0.toRoomSummary() }
        publishedSummariesByRoomId = Dictionary(
            summaries.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        roomsSubject.send(summaries)
        logRooms("Loaded \(summaries.count) cached rooms from GRDB")
    }

    private func observeClientState() {
        matrixService.stateSubject
            .sink { [weak self] state in
                logRooms("Client state changed: \(state)")
                if case .syncing = state {
                    self?.startListening()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    private func startListening() {
        guard let sdkRoomListService = matrixService.roomListService else {
            logRooms("roomListService is nil, cannot start listening")
            return
        }

        guard !isListening else {
            logRooms("Already listening, skipping")
            return
        }
        isListening = true
        self.roomListService = sdkRoomListService

        // Observe RoomListService state
        let stateListener = ServiceStateListener { state in
            logRooms("RoomListService state: \(state)")
        }
        self.serviceStateHandle = sdkRoomListService.state(listener: stateListener)

        Task {
            do {
                let roomList = try await sdkRoomListService.allRooms()
                self.roomList = roomList

                // Set up entries with dynamic adapters
                let result = roomList.entriesWithDynamicAdapters(
                    pageSize: 200,
                    listener: EntriesListener { [weak self] updates in
                        guard let self else { return }
                        logRooms("Received \(updates.count) room list entry updates")
                        self.applyUpdates(updates)
                    }
                )
                self.listUpdatesResult = result

                // Forces the listener to be called with the current state
                _ = result.controller().setFilter(kind: .all(filters: [.nonLeft]))

                // Observe loading state — store stateStream handle to keep it alive
                let loadingResult = try roomList.loadingState(listener: LoadingStateListener { state in
                    logRooms("RoomList loading state: \(state)")
                })
                self.loadingStateStreamHandle = loadingResult.stateStream
                logRooms("Initial loading state: \(loadingResult.state)")

                logRooms("Room list listener started")
            } catch {
                logRooms("Failed to start room list listener: \(error)")
            }
        }
    }

    // MARK: - Apply Diffs

    private func applyUpdates(_ updates: [RoomListEntriesUpdate]) {
        var impactedRoomIds = Set<String>()
        for update in updates {
            applySingleUpdate(update, impactedRoomIds: &impactedRoomIds)
        }

        let currentRooms = rooms
        logRooms("Room count after diffs: \(currentRooms.count)")
        scheduleSummaryRebuild(for: currentRooms, impactedRoomIds: impactedRoomIds)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func applySingleUpdate(
        _ update: RoomListEntriesUpdate,
        impactedRoomIds: inout Set<String>
    ) {
        switch update {
        case .reset(let values):
            rooms = values
            let valueIds = Set(values.map { $0.id() })
            locallyHiddenRoomIds.formIntersection(valueIds)
            impactedRoomIds.formUnion(values.map { $0.id() })
        case .append(let values):
            rooms.append(contentsOf: values)
            impactedRoomIds.formUnion(values.map { $0.id() })
        case .pushBack(let value):
            rooms.append(value)
            impactedRoomIds.insert(value.id())
        case .pushFront(let value):
            rooms.insert(value, at: 0)
            impactedRoomIds.insert(value.id())
        case .insert(let index, let value):
            rooms.insert(value, at: Int(index))
            impactedRoomIds.insert(value.id())
        case .set(let index, let value):
            if Int(index) < rooms.count {
                let oldRoomId = rooms[Int(index)].id()
                rooms[Int(index)] = value
                if oldRoomId != value.id() {
                    locallyHiddenRoomIds.remove(oldRoomId)
                }
                impactedRoomIds.insert(value.id())
            }
        case .remove(let index):
            if Int(index) < rooms.count {
                let removed = rooms.remove(at: Int(index))
                locallyHiddenRoomIds.remove(removed.id())
            }
        case .popBack:
            if !rooms.isEmpty {
                let removed = rooms.removeLast()
                locallyHiddenRoomIds.remove(removed.id())
            }
        case .popFront:
            if !rooms.isEmpty {
                let removed = rooms.removeFirst()
                locallyHiddenRoomIds.remove(removed.id())
            }
        case .truncate(let length):
            if Int(length) < rooms.count {
                let removed = rooms.dropFirst(Int(length))
                for room in removed {
                    locallyHiddenRoomIds.remove(room.id())
                }
            }
            rooms = Array(rooms.prefix(Int(length)))
        case .clear:
            rooms = []
            locallyHiddenRoomIds.removeAll()
        }
    }

    private func scheduleSummaryRebuild(
        for roomsSnapshot: [Room],
        impactedRoomIds: Set<String>
    ) {
        rebuildRevision &+= 1
        let revision = rebuildRevision
        let previousSummaries = publishedSummariesByRoomId
        let hiddenRoomIds = locallyHiddenRoomIds

        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }

            let summaries = await Self.buildSummaries(
                from: roomsSnapshot.filter { !hiddenRoomIds.contains($0.id()) },
                impactedRoomIds: impactedRoomIds.subtracting(hiddenRoomIds),
                previousSummaries: previousSummaries
            )

            guard !Task.isCancelled, self.rebuildRevision == revision else { return }

            self.publishedSummariesByRoomId = Dictionary(
                summaries.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            Self.writeRoomsToGRDB(summaries)

            await MainActor.run { [weak self] in
                guard let self, self.rebuildRevision == revision else { return }
                self.roomsSubject.send(summaries)
            }

            logRooms("Rooms updated: \(summaries.count) rooms")
        }
    }

    private static func buildSummaries(
        from rooms: [Room],
        impactedRoomIds: Set<String>,
        previousSummaries: [String: RoomSummary]
    ) async -> [RoomSummary] {
        var summaries: [RoomSummary] = []

        for room in rooms {
            if Task.isCancelled { break }
            guard let info = try? await room.roomInfo() else { continue }

            let roomId = room.id()
            var lastPreview = Self.extractLastMessage(from: await room.latestEvent())

            if impactedRoomIds.contains(roomId),
               Self.shouldRetryLatestEvent(
                currentPreview: lastPreview,
                previousSummary: previousSummaries[roomId]
               ) {
                try? await Task.sleep(for: latestEventSettleDelay)
                if Task.isCancelled { break }
                lastPreview = Self.extractLastMessage(from: await room.latestEvent())
            }

            let directUserId: String? = info.isDirect ? info.heroes.first?.userId : nil

            var avatarURL = room.avatarUrl()
            if avatarURL == nil, let partnerId = directUserId,
               let client = MatrixClientService.shared.client {
                avatarURL = (try? await client.getProfile(userId: partnerId))?.avatarUrl
            }

            summaries.append(RoomSummary(
                id: roomId,
                displayName: room.displayName() ?? "Unknown",
                avatarURL: avatarURL,
                lastMessage: lastPreview.0,
                lastMessageTimestamp: lastPreview.1,
                unreadCount: info.numUnreadMessages,
                unreadMentionCount: info.numUnreadMentions,
                isMarkedUnread: info.isMarkedUnread,
                isEncrypted: room.encryptionState() != .notEncrypted,
                directUserId: directUserId
            ))
        }

        return summaries
    }

    // MARK: - GRDB Persistence

    private static func writeRoomsToGRDB(_ summaries: [RoomSummary]) {
        let dbQueue = DatabaseService.shared.dbQueue
        writeQueue.async {
            do {
                try dbQueue.write { db in
                    try StoredRoom.deleteAll(db)
                    for (index, summary) in summaries.enumerated() {
                        try StoredRoom(from: summary, sortOrder: index).insert(db)
                    }
                }
                logRooms("Persisted \(summaries.count) rooms to GRDB")
            } catch {
                logRooms("Failed to persist rooms: \(error)")
            }
        }
    }

    private static func removeRoomFromGRDB(roomId: String, purgeTimeline: Bool) {
        if purgeTimeline {
            let envelopeIds = Set(OutgoingEnvelopeService.shared
                .envelopes(roomId: roomId)
                .map(\.id))
            OutgoingEnvelopeService.shared.deleteEnvelopes(ids: envelopeIds)
        }

        let dbQueue = DatabaseService.shared.dbQueue
        writeQueue.async {
            do {
                try dbQueue.write { db in
                    _ = try StoredRoom.deleteOne(db, key: roomId)
                    if purgeTimeline {
                        _ = try StoredMessage
                            .filter(Column("roomId") == roomId)
                            .deleteAll(db)
                    }
                }
                logRooms("Removed room \(roomId) from local cache")
            } catch {
                logRooms("Failed to remove room \(roomId) from local cache: \(error)")
            }
        }
    }

    // MARK: - Last Message Extraction

    private static func shouldRetryLatestEvent(
        currentPreview: (String?, Date?),
        previousSummary: RoomSummary?
    ) -> Bool {
        guard let previousSummary else { return false }
        return currentPreview.0 == previousSummary.lastMessage &&
            currentPreview.1 == previousSummary.lastMessageTimestamp
    }

    private static func extractLastMessage(from value: LatestEventValue) -> (String?, Date?) {
        let timestamp: Date
        let content: TimelineItemContent

        switch value {
        case .none:
            return (nil, nil)
        case .remote(let ts, _, _, _, let c):
            timestamp = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            content = c
        case .local(let ts, _, _, let c, _):
            timestamp = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            content = c
        case .remoteInvite(let ts, _, _):
            return (nil, Date(timeIntervalSince1970: TimeInterval(ts) / 1000))
        }

        guard case .msgLike(let msgContent) = content else { return (nil, timestamp) }

        let text: String
        switch msgContent.kind {
        case .message(let message):
            text = textForMessageType(message.msgType)
        case .sticker:
            text = "Sticker"
        case .poll(let question, _, _, _, _, _, _):
            text = "Poll: \(question)"
        case .redacted:
            text = "..последнее сообщение удалено.."
        case .unableToDecrypt:
            text = String(localized: "Unable to decrypt message")
        case .liveLocation:
            text = "Live location"
        case .other:
            return (nil, timestamp)
        @unknown default:
            return (nil, timestamp)
        }

        return (text, timestamp)
    }

    private static func textForMessageType(_ msgType: MessageType) -> String {
        switch msgType {
        case .text(let content): return content.body
        case .emote(let content): return content.body
        case .notice(let content): return content.body
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Audio"
        case .file: return "File"
        case .location: return "Location"
        default: return "Message"
        }
    }
}

// MARK: - SDK Listeners

private final class EntriesListener: RoomListEntriesListener {
    private let handler: ([RoomListEntriesUpdate]) -> Void

    init(handler: @escaping ([RoomListEntriesUpdate]) -> Void) {
        self.handler = handler
    }

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        handler(roomEntriesUpdate)
    }
}

private final class ServiceStateListener: RoomListServiceStateListener {
    private let handler: (RoomListServiceState) -> Void

    init(handler: @escaping (RoomListServiceState) -> Void) {
        self.handler = handler
    }

    func onUpdate(state: RoomListServiceState) {
        handler(state)
    }
}

private final class LoadingStateListener: RoomListLoadingStateListener {
    private let handler: (RoomListLoadingState) -> Void

    init(handler: @escaping (RoomListLoadingState) -> Void) {
        self.handler = handler
    }

    func onUpdate(state: RoomListLoadingState) {
        handler(state)
    }
}
