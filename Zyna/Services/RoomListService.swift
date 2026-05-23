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
    let lastMessageSenderName: String?
    let lastMessageTimestamp: Date?
    let unreadCount: UInt64
    let unreadMentionCount: UInt64
    let isMarkedUnread: Bool
    let isEncrypted: Bool
    let isSpace: Bool
    let isMuted: Bool
    /// Matrix user ID of the other person in a DM room, nil for group rooms.
    let directUserId: String?
    let spaceChildRoomCount: Int
    let spaceChildSpaceCount: Int
    let spaceRecentRooms: [SpaceChildSummary]
}

struct SpaceChildSummary: Codable, Equatable {
    let id: String
    let displayName: String
    let avatarURL: String?
    let directUserId: String?
}

struct SpaceChildrenSummary {
    let rooms: [RoomSummary]
    let spaces: [RoomSummary]
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
    private var spaceChildSummariesBySpaceId: [String: [RoomSummary]] = [:]
    private var spaceChildSpaceSummariesBySpaceId: [String: [RoomSummary]] = [:]
    private var locallyHiddenRoomIds = Set<String>()
    private var rebuildTask: Task<Void, Never>?
    private var rebuildRevision: UInt64 = 0
    private var isListening = false
    private var cancellables = Set<AnyCancellable>()

    private static let writeQueue = DispatchQueue(label: "com.zyna.db.rooms", qos: .userInitiated)
    private static let latestEventSettleDelay: Duration = .milliseconds(150)
    private static let spaceRecentRoomLimit = 4

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

    func cachedSpaceChildRooms(for spaceId: String) -> [RoomSummary] {
        spaceChildSummariesBySpaceId[spaceId] ?? []
    }

    func cachedSpaceChildSpaces(for spaceId: String) -> [RoomSummary] {
        spaceChildSpaceSummariesBySpaceId[spaceId] ?? []
    }

    func joinedRoomSummaries() async -> [RoomSummary] {
        let roomsSnapshot = rooms.filter { !locallyHiddenRoomIds.contains($0.id()) }
        guard !roomsSnapshot.isEmpty else {
            guard let clientRooms = MatrixClientService.shared.client?.rooms()
                .filter({ !locallyHiddenRoomIds.contains($0.id()) }),
                  !clientRooms.isEmpty else {
                return roomsSubject.value
            }

            return await Self.buildBaseSummaries(
                from: clientRooms,
                impactedRoomIds: [],
                previousSummaries: publishedSummariesByRoomId
            )
        }

        return await Self.buildBaseSummaries(
            from: roomsSnapshot,
            impactedRoomIds: [],
            previousSummaries: publishedSummariesByRoomId
        )
    }

    func refreshSpaceChildRooms(for spaceId: String) async -> [RoomSummary] {
        let children = await refreshSpaceChildren(for: spaceId)
        return children.rooms
    }

    func refreshSpaceChildren(for spaceId: String) async -> SpaceChildrenSummary {
        let children = await loadSpaceChildren(for: spaceId)
        spaceChildSummariesBySpaceId[spaceId] = children.rooms
        spaceChildSpaceSummariesBySpaceId[spaceId] = children.spaces
        return children
    }

    func addChild(_ childId: String, toSpace spaceId: String, context: String) async throws {
        guard let client = MatrixClientService.shared.client else {
            throw spaceRelationshipError(String(localized: "Matrix client is not ready."))
        }

        let spaceService = await client.spaceService()
        var lastError: Error?

        for attempt in 1...10 {
            _ = await waitForLocalRoom(roomId: childId)
            _ = await spaceService.topLevelJoinedSpaces()
            _ = try? await spaceService.getSpaceRoom(roomId: spaceId)
            _ = try? await spaceService.getSpaceRoom(roomId: childId)

            do {
                try await spaceService.addChildToSpace(childId: childId, spaceId: spaceId)
                if attempt > 1 {
                    logSpaceRelationship(
                        "Linked child after retry",
                        stage: "addChildToSpace",
                        context: context,
                        spaceId: spaceId,
                        childId: childId,
                        attempt: attempt
                    )
                }
                _ = await refreshSpaceChildren(for: spaceId)
                return
            } catch {
                lastError = error
                logSpaceRelationship(
                    "Space relationship retry scheduled",
                    stage: "addChildToSpace",
                    context: context,
                    spaceId: spaceId,
                    childId: childId,
                    attempt: attempt,
                    error: error
                )
                if attempt < 10 {
                    try? await Task.sleep(for: .milliseconds(350 + attempt * 250))
                }
            }
        }

        do {
            logSpaceRelationship(
                "Falling back to raw space state events",
                stage: "sendStateEventRaw",
                context: context,
                spaceId: spaceId,
                childId: childId,
                error: lastError
            )
            try await addChildWithRawStateEvents(childId: childId, spaceId: spaceId)
            logSpaceRelationship(
                "Linked child with raw state events",
                stage: "sendStateEventRaw",
                context: context,
                spaceId: spaceId,
                childId: childId
            )
            _ = await refreshSpaceChildren(for: spaceId)
        } catch {
            logSpaceRelationship(
                "Raw space state event fallback failed",
                stage: "sendStateEventRaw",
                context: context,
                spaceId: spaceId,
                childId: childId,
                error: error
            )
            throw error
        }
    }

    func removeChild(_ childId: String, fromSpace spaceId: String, context: String) async throws {
        guard let client = MatrixClientService.shared.client else {
            throw spaceRelationshipError(String(localized: "Matrix client is not ready."))
        }

        let spaceService = await client.spaceService()
        var lastError: Error?

        for attempt in 1...10 {
            _ = await waitForLocalRoom(roomId: childId)
            _ = await spaceService.topLevelJoinedSpaces()
            _ = try? await spaceService.getSpaceRoom(roomId: spaceId)
            _ = try? await spaceService.getSpaceRoom(roomId: childId)

            do {
                try await spaceService.removeChildFromSpace(childId: childId, spaceId: spaceId)
                if attempt > 1 {
                    logSpaceRelationship(
                        "Removed child after retry",
                        stage: "removeChildFromSpace",
                        context: context,
                        spaceId: spaceId,
                        childId: childId,
                        attempt: attempt
                    )
                }
                _ = await refreshSpaceChildren(for: spaceId)
                return
            } catch {
                lastError = error
                logSpaceRelationship(
                    "Space relationship removal retry scheduled",
                    stage: "removeChildFromSpace",
                    context: context,
                    spaceId: spaceId,
                    childId: childId,
                    attempt: attempt,
                    error: error
                )
                if attempt < 10 {
                    try? await Task.sleep(for: .milliseconds(350 + attempt * 250))
                }
            }
        }

        do {
            logSpaceRelationship(
                "Falling back to raw removal state events",
                stage: "sendStateEventRaw",
                context: context,
                spaceId: spaceId,
                childId: childId,
                error: lastError
            )
            try await removeChildWithRawStateEvents(childId: childId, spaceId: spaceId)
            logSpaceRelationship(
                "Removed child with raw state events",
                stage: "sendStateEventRaw",
                context: context,
                spaceId: spaceId,
                childId: childId
            )
            _ = await refreshSpaceChildren(for: spaceId)
        } catch {
            logSpaceRelationship(
                "Raw removal state event fallback failed",
                stage: "sendStateEventRaw",
                context: context,
                spaceId: spaceId,
                childId: childId,
                error: error
            )
            throw error
        }
    }

    private func loadSpaceChildren(for spaceId: String) async -> SpaceChildrenSummary {
        guard let client = MatrixClientService.shared.client else {
            return SpaceChildrenSummary(rooms: [], spaces: [])
        }
        let spaceService = await client.spaceService()
        guard let list = try? await spaceService.spaceRoomList(spaceId: spaceId) else {
            return SpaceChildrenSummary(rooms: [], spaces: [])
        }

        try? await list.paginate()
        let children = await list.rooms()

        let childRooms = children.filter { child in
            switch child.roomType {
            case .space:
                return false
            case .room, .custom:
                return true
            }
        }
        let childSpaces = children.filter { child in
            if case .space = child.roomType { return true }
            return false
        }
        let childRoomIds = childRooms.map(\.roomId)
        let childSpaceIds = childSpaces.map(\.roomId)

        let previousSummaries = publishedSummariesByRoomId
        let localChildRooms = (childRoomIds + childSpaceIds).compactMap { room(for: $0) }
        let summaries = await Self.buildBaseSummaries(
            from: localChildRooms,
            impactedRoomIds: Set(childRoomIds + childSpaceIds),
            previousSummaries: previousSummaries
        )
        let summariesById = Dictionary(
            summaries.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        let roomSummaries = childRooms
            .map { summariesById[$0.roomId] ?? Self.previewSummary(from: $0) }
            .sorted(by: Self.spaceActivitySort)
        let spaceSummaries = childSpaces
            .map { summariesById[$0.roomId] ?? Self.previewSummary(from: $0) }
            .sorted(by: Self.spaceActivitySort)

        return SpaceChildrenSummary(
            rooms: roomSummaries,
            spaces: spaceSummaries
        )
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

            let buildResult = await Self.buildSummaries(
                from: roomsSnapshot.filter { !hiddenRoomIds.contains($0.id()) },
                impactedRoomIds: impactedRoomIds.subtracting(hiddenRoomIds),
                previousSummaries: previousSummaries
            )
            let summaries = buildResult.summaries

            guard !Task.isCancelled, self.rebuildRevision == revision else { return }

            self.publishedSummariesByRoomId = Dictionary(
                summaries.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            self.spaceChildSummariesBySpaceId = buildResult.spaceChildSummariesBySpaceId
            self.spaceChildSpaceSummariesBySpaceId = buildResult.spaceChildSpaceSummariesBySpaceId
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
    ) async -> RoomListBuildResult {
        let summaries = await buildBaseSummaries(
            from: rooms,
            impactedRoomIds: impactedRoomIds,
            previousSummaries: previousSummaries
        )
        return await enrichSpaceSummaries(summaries)
    }

    private static func buildBaseSummaries(
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
                displayName: room.displayName() ?? (info.isSpace ? String(localized: "Untitled") : "Unknown"),
                avatarURL: avatarURL,
                lastMessage: lastPreview.body,
                lastMessageSenderName: lastPreview.senderName,
                lastMessageTimestamp: lastPreview.timestamp,
                unreadCount: info.numUnreadMessages,
                unreadMentionCount: info.numUnreadMentions,
                isMarkedUnread: info.isMarkedUnread,
                isEncrypted: room.encryptionState() != .notEncrypted,
                isSpace: info.isSpace,
                isMuted: info.cachedUserDefinedNotificationMode == .mute,
                directUserId: directUserId,
                spaceChildRoomCount: 0,
                spaceChildSpaceCount: 0,
                spaceRecentRooms: []
            ))
        }

        return summaries
    }

    private struct RoomListBuildResult {
        let summaries: [RoomSummary]
        let spaceChildSummariesBySpaceId: [String: [RoomSummary]]
        let spaceChildSpaceSummariesBySpaceId: [String: [RoomSummary]]
    }

    private struct SpaceGraphEntry {
        let childRooms: [SpaceRoom]
        let childSpaces: [SpaceRoom]

        var childRoomIds: [String] { childRooms.map(\.roomId) }
        var childSpaceIds: [String] { childSpaces.map(\.roomId) }
    }

    private static func enrichSpaceSummaries(_ summaries: [RoomSummary]) async -> RoomListBuildResult {
        guard summaries.contains(where: \.isSpace),
              let client = MatrixClientService.shared.client else {
            return RoomListBuildResult(
                summaries: summaries,
                spaceChildSummariesBySpaceId: [:],
                spaceChildSpaceSummariesBySpaceId: [:]
            )
        }

        let summariesById = Dictionary(
            summaries.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var graph: [String: SpaceGraphEntry] = [:]

        let spaceService = await client.spaceService()
        for space in summaries where space.isSpace {
            if Task.isCancelled { break }
            guard let list = try? await spaceService.spaceRoomList(spaceId: space.id) else { continue }
            try? await list.paginate()
            let children = await list.rooms()

            var childRooms: [SpaceRoom] = []
            var childSpaces: [SpaceRoom] = []
            for child in children {
                switch child.roomType {
                case .space:
                    childSpaces.append(child)
                case .room, .custom:
                    childRooms.append(child)
                }
            }

            graph[space.id] = SpaceGraphEntry(
                childRooms: childRooms,
                childSpaces: childSpaces
            )
        }

        guard !graph.isEmpty else {
            return RoomListBuildResult(
                summaries: summaries,
                spaceChildSummariesBySpaceId: [:],
                spaceChildSpaceSummariesBySpaceId: [:]
            )
        }

        var childIds = Set<String>()
        for entry in graph.values {
            childIds.formUnion(entry.childRoomIds)
            childIds.formUnion(entry.childSpaceIds)
        }

        var spaceChildSummariesBySpaceId: [String: [RoomSummary]] = [:]
        var spaceChildSpaceSummariesBySpaceId: [String: [RoomSummary]] = [:]

        for (spaceId, entry) in graph {
            let childSummaries = entry.childRooms.map {
                summariesById[$0.roomId] ?? previewSummary(from: $0)
            }
            spaceChildSummariesBySpaceId[spaceId] = childSummaries.sorted(by: spaceActivitySort)
            spaceChildSpaceSummariesBySpaceId[spaceId] = entry.childSpaces
                .map { child in
                    let base = summariesById[child.roomId] ?? previewSummary(from: child)
                    guard let childEntry = graph[base.id] else { return base }
                    return enrichedSpaceSummary(
                        base,
                        entry: childEntry,
                        summariesById: summariesById
                    )
                }
                .sorted(by: spaceActivitySort)
        }

        let enriched: [RoomSummary] = summaries.compactMap { summary -> RoomSummary? in
            if childIds.contains(summary.id) {
                return nil
            }

            guard summary.isSpace, let entry = graph[summary.id] else {
                return summary
            }

            return enrichedSpaceSummary(
                summary,
                entry: entry,
                summariesById: summariesById
            )
        }

        let sortedSummaries = enriched.enumerated()
            .sorted { lhs, rhs in
                spaceListSort(lhs.element, rhs.element, leftIndex: lhs.offset, rightIndex: rhs.offset)
            }
            .map { $0.element }

        return RoomListBuildResult(
            summaries: sortedSummaries,
            spaceChildSummariesBySpaceId: spaceChildSummariesBySpaceId,
            spaceChildSpaceSummariesBySpaceId: spaceChildSpaceSummariesBySpaceId
        )
    }

    private static func enrichedSpaceSummary(
        _ summary: RoomSummary,
        entry: SpaceGraphEntry,
        summariesById: [String: RoomSummary]
    ) -> RoomSummary {
        let childSummaries = entry.childRooms.map {
            summariesById[$0.roomId] ?? previewSummary(from: $0)
        }
        let visibleChildren = childSummaries.filter { !$0.isMuted }
        let previewSource = visibleChildren.isEmpty ? childSummaries : visibleChildren
        let previewChildren = previewSource.sorted(by: spaceActivitySort)
        let latestChild = previewChildren.first

        return RoomSummary(
            id: summary.id,
            displayName: summary.displayName,
            avatarURL: summary.avatarURL,
            lastMessage: latestChild?.lastMessage,
            lastMessageSenderName: latestChild?.lastMessageSenderName,
            lastMessageTimestamp: visibleChildren.sorted(by: spaceActivitySort).first?.lastMessageTimestamp,
            unreadCount: UInt64(visibleChildren.reduce(0) { $0 + Int($1.unreadCount) }),
            unreadMentionCount: UInt64(visibleChildren.reduce(0) { $0 + Int($1.unreadMentionCount) }),
            isMarkedUnread: visibleChildren.contains(where: \.isMarkedUnread),
            isEncrypted: summary.isEncrypted,
            isSpace: true,
            isMuted: summary.isMuted,
            directUserId: nil,
            spaceChildRoomCount: entry.childRoomIds.count,
            spaceChildSpaceCount: entry.childSpaceIds.count,
            spaceRecentRooms: Array(previewChildren.prefix(spaceRecentRoomLimit)).map {
                SpaceChildSummary(
                    id: $0.id,
                    displayName: $0.displayName,
                    avatarURL: $0.avatarURL,
                    directUserId: $0.directUserId
                )
            }
        )
    }

    private static func previewSummary(from preview: SpaceRoom) -> RoomSummary {
        let displayName = preview.displayName.isEmpty
            ? (preview.canonicalAlias ?? String(localized: "Untitled"))
            : preview.displayName

        return RoomSummary(
            id: preview.roomId,
            displayName: displayName,
            avatarURL: preview.avatarUrl,
            lastMessage: nil,
            lastMessageSenderName: nil,
            lastMessageTimestamp: nil,
            unreadCount: 0,
            unreadMentionCount: 0,
            isMarkedUnread: false,
            isEncrypted: false,
            isSpace: preview.roomType == .space,
            isMuted: false,
            directUserId: nil,
            spaceChildRoomCount: 0,
            spaceChildSpaceCount: 0,
            spaceRecentRooms: []
        )
    }

    private func waitForLocalRoom(roomId: String) async -> Room? {
        for _ in 0..<20 {
            if let room = room(for: roomId) {
                return room
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return room(for: roomId)
    }

    private func addChildWithRawStateEvents(childId: String, spaceId: String) async throws {
        guard let spaceRoom = room(for: spaceId) else {
            throw spaceRelationshipError(String(localized: "Parent Storyline is not available locally."))
        }

        let childContent = try jsonString([
            "via": viaServers(for: childId),
            "suggested": false
        ])
        _ = try await spaceRoom.sendStateEventRaw(
            eventType: "m.space.child",
            stateKey: childId,
            content: childContent
        )

        guard let childRoom = await waitForLocalRoom(roomId: childId) else {
            return
        }

        let parentContent = try jsonString([
            "via": viaServers(for: spaceId),
            "canonical": true
        ])
        _ = try? await childRoom.sendStateEventRaw(
            eventType: "m.space.parent",
            stateKey: spaceId,
            content: parentContent
        )
    }

    private func removeChildWithRawStateEvents(childId: String, spaceId: String) async throws {
        guard let spaceRoom = room(for: spaceId) else {
            throw spaceRelationshipError(String(localized: "Parent Storyline is not available locally."))
        }

        _ = try await spaceRoom.sendStateEventRaw(
            eventType: "m.space.child",
            stateKey: childId,
            content: "{}"
        )

        guard let childRoom = await waitForLocalRoom(roomId: childId) else {
            return
        }

        _ = try? await childRoom.sendStateEventRaw(
            eventType: "m.space.parent",
            stateKey: spaceId,
            content: "{}"
        )
    }

    private func viaServers(for roomId: String) -> [String] {
        guard let serverName = roomId.split(separator: ":", maxSplits: 1).last,
              !serverName.isEmpty
        else {
            return []
        }
        return [String(serverName)]
    }

    private func jsonString(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw spaceRelationshipError(String(localized: "Could not encode Matrix state event content."))
        }
        return string
    }

    private func spaceRelationshipError(_ message: String) -> Error {
        NSError(
            domain: "Zyna.SpaceRelationship",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func logSpaceRelationship(
        _ title: String,
        stage: String,
        context: String,
        spaceId: String,
        childId: String,
        attempt: Int? = nil,
        error: Error? = nil
    ) {
        var parts = [
            title,
            "stage=\(stage)",
            "context=\(context)",
            "spaceId=\(spaceId)",
            "childId=\(childId)"
        ]
        if let attempt {
            parts.append("attempt=\(attempt)")
        }
        if let error {
            parts.append("localized=\(error.localizedDescription)")
            parts.append("reflected=\(String(reflecting: error))")
        }

        let message = "[SpaceRelationship] " + parts.joined(separator: " ")
        print(message)
        logRooms(message)
    }

    private static func spaceActivitySort(_ lhs: RoomSummary, _ rhs: RoomSummary) -> Bool {
        switch (lhs.lastMessageTimestamp, rhs.lastMessageTimestamp) {
        case let (left?, right?):
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func spaceListSort(
        _ lhs: RoomSummary,
        _ rhs: RoomSummary,
        leftIndex: Int,
        rightIndex: Int
    ) -> Bool {
        switch (lhs.lastMessageTimestamp, rhs.lastMessageTimestamp) {
        case let (left?, right?):
            guard left != right else { return leftIndex < rightIndex }
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return leftIndex < rightIndex
        }
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
        currentPreview: LatestMessagePreview,
        previousSummary: RoomSummary?
    ) -> Bool {
        guard let previousSummary else { return false }
        return currentPreview.body == previousSummary.lastMessage &&
            currentPreview.timestamp == previousSummary.lastMessageTimestamp
    }

    private struct LatestMessagePreview {
        let body: String?
        let senderName: String?
        let timestamp: Date?
    }

    private static func extractLastMessage(from value: LatestEventValue) -> LatestMessagePreview {
        let timestamp: Date
        let content: TimelineItemContent
        let senderName: String?

        switch value {
        case .none:
            return LatestMessagePreview(body: nil, senderName: nil, timestamp: nil)
        case .remote(let ts, let sender, let isOwn, let profile, let c):
            timestamp = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            content = c
            senderName = Self.senderDisplayName(sender: sender, isOwn: isOwn, profile: profile)
        case .local(let ts, let sender, let profile, let c, _):
            timestamp = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            content = c
            senderName = Self.senderDisplayName(sender: sender, isOwn: true, profile: profile)
        case .remoteInvite(let ts, _, _):
            return LatestMessagePreview(
                body: nil,
                senderName: nil,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            )
        }

        guard case .msgLike(let msgContent) = content else {
            return LatestMessagePreview(body: nil, senderName: senderName, timestamp: timestamp)
        }

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
            return LatestMessagePreview(body: nil, senderName: senderName, timestamp: timestamp)
        @unknown default:
            return LatestMessagePreview(body: nil, senderName: senderName, timestamp: timestamp)
        }

        return LatestMessagePreview(body: text, senderName: senderName, timestamp: timestamp)
    }

    private static func senderDisplayName(
        sender: String,
        isOwn: Bool,
        profile: ProfileDetails
    ) -> String {
        if isOwn {
            return String(localized: "You")
        }

        if case .ready(let displayName, _, _) = profile,
           let displayName,
           !displayName.isEmpty {
            return displayName
        }

        return sender
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
