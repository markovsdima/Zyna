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
    let lastOwnMessageStatus: LastOwnMessageStatus?
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
    let spaceMetadata: SpaceRoomMetadata?
}

enum LastOwnMessageStatus: String, Codable, Equatable {
    case pending
    case sent
    case read
    case failed
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

final class SpaceChildrenObservation {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    deinit {
        cancel()
    }

    func cancel() {
        task.cancel()
    }
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
    private var spaceChildBootstrapInFlight = Set<String>()
    private var spaceChildBootstrapCompletedSpaceIds = Set<String>()
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

    private func cachedSpaceChildrenSummary(for spaceId: String) -> SpaceChildrenSummary {
        SpaceChildrenSummary(
            rooms: cachedSpaceChildRooms(for: spaceId),
            spaces: cachedSpaceChildSpaces(for: spaceId)
        )
    }

    fileprivate func hasCachedSpaceChildren(for spaceId: String) -> Bool {
        !cachedSpaceChildRooms(for: spaceId).isEmpty || !cachedSpaceChildSpaces(for: spaceId).isEmpty
    }

    private func hasSpaceChildrenCacheEntry(for spaceId: String) -> Bool {
        spaceChildSummariesBySpaceId[spaceId] != nil || spaceChildSpaceSummariesBySpaceId[spaceId] != nil
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
                refreshAllOwnMessageStatuses: true,
                previousSummaries: publishedSummariesByRoomId
            )
        }

        return await Self.buildBaseSummaries(
            from: roomsSnapshot,
            impactedRoomIds: [],
            refreshAllOwnMessageStatuses: true,
            previousSummaries: publishedSummariesByRoomId
        )
    }

    func refreshSpaceChildRooms(for spaceId: String) async -> [RoomSummary] {
        let children = await refreshSpaceChildren(for: spaceId)
        return children.rooms
    }

    func refreshSpaceChildren(for spaceId: String) async -> SpaceChildrenSummary {
        guard let children = await loadSpaceChildren(for: spaceId) else {
            return cachedSpaceChildrenSummary(for: spaceId)
        }
        cacheSpaceChildren(children, for: spaceId)
        Self.writeSpaceChildrenToGRDB(children, for: spaceId)
        refreshPublishedSummariesFromSpaceChildCache(spaceId: spaceId)
        return children
    }

    func observeSpaceChildren(
        for spaceId: String,
        onUpdate: @escaping @MainActor (SpaceChildrenSummary) -> Void
    ) -> SpaceChildrenObservation {
        SpaceChildrenObservation(task: Task { [weak self] in
            guard let self else { return }
            let cachedFallback = SpaceChildrenSummary(
                rooms: cachedSpaceChildRooms(for: spaceId),
                spaces: cachedSpaceChildSpaces(for: spaceId)
            )
            await MainActor.run { onUpdate(cachedFallback) }

            guard let client = MatrixClientService.shared.client else {
                return
            }

            let spaceService = await client.spaceService()
            guard let list = try? await spaceService.spaceRoomList(spaceId: spaceId) else {
                return
            }

            let observer = SpaceChildrenLiveObserver(
                spaceId: spaceId,
                list: list,
                roomListService: self,
                onUpdate: onUpdate
            )

            let entriesListener = SpaceRoomListEntriesCallback { [weak observer] _ in
                guard let observer else { return }
                Task { await observer.scheduleReload() }
            }
            let paginationListener = SpaceRoomListPaginationCallback { [weak observer] state in
                guard let observer else { return }
                Task { await observer.handlePaginationState(state) }
            }
            let spaceListener = SpaceRoomListSpaceCallback { [weak observer] _ in
                guard let observer else { return }
                Task { await observer.scheduleReload() }
            }

            let roomUpdatesHandle = await list.subscribeToRoomUpdate(listener: entriesListener)
            let paginationHandle = list.subscribeToPaginationStateUpdates(listener: paginationListener)
            let spaceHandle = list.subscribeToSpaceUpdates(listener: spaceListener)

            await observer.handlePaginationState(list.paginationState())
            await observer.reloadAndEmit()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
            }

            roomUpdatesHandle.cancel()
            paginationHandle.cancel()
            spaceHandle.cancel()
            await observer.cancel()
        })
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

    func setChildLink(_ childId: String, toSpace spaceId: String, context: String) async throws {
        logSpaceRelationship(
            "Setting space child state event",
            stage: "sendStateEventRaw",
            context: context,
            spaceId: spaceId,
            childId: childId
        )
        try await sendSpaceChildState(childId: childId, spaceId: spaceId)
        _ = await refreshSpaceChildren(for: spaceId)
    }

    func removeChildLink(_ childId: String, fromSpace spaceId: String, context: String) async throws {
        logSpaceRelationship(
            "Removing space child state event",
            stage: "sendStateEventRaw",
            context: context,
            spaceId: spaceId,
            childId: childId
        )
        try await sendEmptySpaceChildState(childId: childId, spaceId: spaceId)
        _ = await refreshSpaceChildren(for: spaceId)
    }

    func setParentLink(_ spaceId: String, forChild childId: String, context: String) async throws {
        logSpaceRelationship(
            "Setting space parent state event",
            stage: "sendStateEventRaw",
            context: context,
            spaceId: spaceId,
            childId: childId
        )
        try await sendSpaceParentState(spaceId: spaceId, childId: childId)
    }

    func removeParentLink(_ spaceId: String, fromChild childId: String, context: String) async throws {
        logSpaceRelationship(
            "Removing space parent state event",
            stage: "sendStateEventRaw",
            context: context,
            spaceId: spaceId,
            childId: childId
        )
        try await sendEmptySpaceParentState(spaceId: spaceId, childId: childId)
    }

    private func loadSpaceChildren(for spaceId: String) async -> SpaceChildrenSummary? {
        guard let client = MatrixClientService.shared.client else {
            return nil
        }
        let spaceService = await client.spaceService()
        guard let list = try? await spaceService.spaceRoomList(spaceId: spaceId) else {
            return nil
        }

        let didPaginate = (try? await list.paginate()) != nil
        let children = await list.rooms()
        guard didPaginate || !children.isEmpty else { return nil }
        if children.isEmpty {
            switch list.paginationState() {
            case .idle(let endReached) where endReached:
                break
            default:
                return nil
            }
        }
        return await buildSpaceChildrenSummary(from: children)
    }

    fileprivate func cacheSpaceChildren(_ children: SpaceChildrenSummary, for spaceId: String) {
        spaceChildSummariesBySpaceId[spaceId] = children.rooms
        spaceChildSpaceSummariesBySpaceId[spaceId] = children.spaces
    }

    fileprivate func refreshPublishedSummariesFromSpaceChildCache(spaceId: String) {
        if !rooms.isEmpty {
            scheduleSummaryRebuild(for: rooms, impactedRoomIds: [spaceId])
            return
        }

        let currentSummaries = roomsSubject.value
        guard !currentSummaries.isEmpty else { return }

        let enriched = Self.enrichSpaceSummaries(
            currentSummaries,
            cachedSpaceChildSummariesBySpaceId: spaceChildSummariesBySpaceId,
            cachedSpaceChildSpaceSummariesBySpaceId: spaceChildSpaceSummariesBySpaceId
        )
        publishedSummariesByRoomId = Dictionary(
            enriched.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        Self.writeRoomsToGRDB(enriched)

        Task { @MainActor [weak self] in
            self?.roomsSubject.send(enriched)
        }
    }

    fileprivate func buildSpaceChildrenSummary(from children: [SpaceRoom]) async -> SpaceChildrenSummary {
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
            .map { Self.spaceChildSummary(from: $0, localSummary: summariesById[$0.roomId]) }
            .sorted(by: Self.spaceActivitySort)
        let spaceSummaries = childSpaces
            .map { Self.spaceChildSummary(from: $0, localSummary: summariesById[$0.roomId]) }
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
        guard let cached = try? dbQueue.read({ db in
            let rooms = try StoredRoom.order(Column("sortOrder").asc).fetchAll(db)
            let children = try StoredSpaceChild
                .order(Column("spaceId").asc, Column("isSpace").desc, Column("sortOrder").asc)
                .fetchAll(db)
            return (rooms: rooms, children: children)
        }) else { return }

        let childCaches = Self.spaceChildCaches(from: cached.children)
        spaceChildSummariesBySpaceId = childCaches.roomsBySpaceId
        spaceChildSpaceSummariesBySpaceId = childCaches.spacesBySpaceId

        guard !cached.rooms.isEmpty else {
            if !cached.children.isEmpty {
                logRooms("Loaded \(cached.children.count) cached space children from GRDB")
            }
            return
        }

        let summaries = Self.enrichSpaceSummaries(
            cached.rooms.map { $0.toRoomSummary() },
            cachedSpaceChildSummariesBySpaceId: childCaches.roomsBySpaceId,
            cachedSpaceChildSpaceSummariesBySpaceId: childCaches.spacesBySpaceId
        )
        publishedSummariesByRoomId = Dictionary(
            summaries.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        roomsSubject.send(summaries)
        logRooms("Loaded \(summaries.count) cached rooms from GRDB")
        if !cached.children.isEmpty {
            logRooms("Loaded \(cached.children.count) cached space children from GRDB")
        }
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
        let cachedSpaceChildSummaries = spaceChildSummariesBySpaceId
        let cachedSpaceChildSpaceSummaries = spaceChildSpaceSummariesBySpaceId
        let hiddenRoomIds = locallyHiddenRoomIds

        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }

            let buildResult = await Self.buildSummaries(
                from: roomsSnapshot.filter { !hiddenRoomIds.contains($0.id()) },
                impactedRoomIds: impactedRoomIds.subtracting(hiddenRoomIds),
                refreshAllOwnMessageStatuses: previousSummaries.isEmpty,
                previousSummaries: previousSummaries,
                cachedSpaceChildSummariesBySpaceId: cachedSpaceChildSummaries,
                cachedSpaceChildSpaceSummariesBySpaceId: cachedSpaceChildSpaceSummaries
            )
            let summaries = buildResult.summaries

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

            self.scheduleSpaceChildBootstrapIfNeeded(for: summaries)
            logRooms("Rooms updated: \(summaries.count) rooms")
        }
    }

    private func scheduleSpaceChildBootstrapIfNeeded(for summaries: [RoomSummary]) {
        let missingSpaceIds = summaries
            .filter(\.isSpace)
            .map(\.id)
            .filter { spaceId in
                !hasSpaceChildrenCacheEntry(for: spaceId)
                    && !spaceChildBootstrapInFlight.contains(spaceId)
                    && !spaceChildBootstrapCompletedSpaceIds.contains(spaceId)
            }

        guard !missingSpaceIds.isEmpty else { return }

        spaceChildBootstrapInFlight.formUnion(missingSpaceIds)
        Task { [weak self] in
            for spaceId in missingSpaceIds {
                guard let self, !Task.isCancelled else { return }
                guard let children = await self.loadSpaceChildren(for: spaceId) else {
                    self.spaceChildBootstrapInFlight.remove(spaceId)
                    continue
                }

                self.cacheSpaceChildren(children, for: spaceId)
                Self.writeSpaceChildrenToGRDB(children, for: spaceId)
                self.spaceChildBootstrapInFlight.remove(spaceId)
                self.spaceChildBootstrapCompletedSpaceIds.insert(spaceId)
                self.refreshPublishedSummariesFromSpaceChildCache(spaceId: spaceId)
                logRooms("Bootstrapped \(children.rooms.count) rooms and \(children.spaces.count) spaces for space \(spaceId)")
            }
        }
    }

    private static func buildSummaries(
        from rooms: [Room],
        impactedRoomIds: Set<String>,
        refreshAllOwnMessageStatuses: Bool = false,
        previousSummaries: [String: RoomSummary],
        cachedSpaceChildSummariesBySpaceId: [String: [RoomSummary]],
        cachedSpaceChildSpaceSummariesBySpaceId: [String: [RoomSummary]]
    ) async -> RoomListBuildResult {
        let summaries = await buildBaseSummaries(
            from: rooms,
            impactedRoomIds: impactedRoomIds,
            refreshAllOwnMessageStatuses: refreshAllOwnMessageStatuses,
            previousSummaries: previousSummaries
        )
        let enriched = enrichSpaceSummaries(
            summaries,
            cachedSpaceChildSummariesBySpaceId: cachedSpaceChildSummariesBySpaceId,
            cachedSpaceChildSpaceSummariesBySpaceId: cachedSpaceChildSpaceSummariesBySpaceId
        )
        return RoomListBuildResult(summaries: enriched)
    }

    private static func buildBaseSummaries(
        from rooms: [Room],
        impactedRoomIds: Set<String>,
        refreshAllOwnMessageStatuses: Bool = false,
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

            let previousSpaceSummary = info.isSpace ? previousSummaries[roomId] : nil
            let shouldRefreshOwnStatus = refreshAllOwnMessageStatuses
                || impactedRoomIds.contains(roomId)
                || previousSummaries[roomId] == nil
            let lastOwnMessageStatus: LastOwnMessageStatus?
            if let previousSpaceSummary {
                lastOwnMessageStatus = previousSpaceSummary.lastOwnMessageStatus
            } else if shouldRefreshOwnStatus {
                lastOwnMessageStatus = await Self.resolveLastOwnMessageStatus(for: room, preview: lastPreview)
            } else {
                lastOwnMessageStatus = previousSummaries[roomId]?.lastOwnMessageStatus
            }

            summaries.append(RoomSummary(
                id: roomId,
                displayName: room.displayName() ?? (info.isSpace ? String(localized: "Untitled") : "Unknown"),
                avatarURL: avatarURL,
                lastMessage: previousSpaceSummary?.lastMessage ?? lastPreview.body,
                lastMessageSenderName: previousSpaceSummary?.lastMessageSenderName ?? lastPreview.senderName,
                lastMessageTimestamp: previousSpaceSummary?.lastMessageTimestamp ?? lastPreview.timestamp,
                lastOwnMessageStatus: lastOwnMessageStatus,
                unreadCount: previousSpaceSummary?.unreadCount ?? info.numUnreadMessages,
                unreadMentionCount: previousSpaceSummary?.unreadMentionCount ?? info.numUnreadMentions,
                isMarkedUnread: previousSpaceSummary?.isMarkedUnread ?? info.isMarkedUnread,
                isEncrypted: room.encryptionState() != .notEncrypted,
                isSpace: info.isSpace,
                isMuted: info.cachedUserDefinedNotificationMode == .mute,
                directUserId: directUserId,
                spaceChildRoomCount: previousSpaceSummary?.spaceChildRoomCount ?? 0,
                spaceChildSpaceCount: previousSpaceSummary?.spaceChildSpaceCount ?? 0,
                spaceRecentRooms: previousSpaceSummary?.spaceRecentRooms ?? [],
                spaceMetadata: info.isSpace ? SpaceRoomMetadata(roomInfo: info) : nil
            ))
        }

        return summaries
    }

    private struct RoomListBuildResult {
        let summaries: [RoomSummary]
    }

    private struct SpaceChildCacheSnapshot {
        let roomsBySpaceId: [String: [RoomSummary]]
        let spacesBySpaceId: [String: [RoomSummary]]
    }

    private static func enrichSpaceSummaries(
        _ summaries: [RoomSummary],
        cachedSpaceChildSummariesBySpaceId: [String: [RoomSummary]],
        cachedSpaceChildSpaceSummariesBySpaceId: [String: [RoomSummary]]
    ) -> [RoomSummary] {
        let spaceIds = Set(summaries.filter(\.isSpace).map(\.id))
        guard !spaceIds.isEmpty else {
            return summaries
        }

        let summariesById = Dictionary(
            summaries.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        var childIds = Set<String>()
        for spaceId in spaceIds {
            childIds.formUnion((cachedSpaceChildSummariesBySpaceId[spaceId] ?? []).map(\.id))
            childIds.formUnion((cachedSpaceChildSpaceSummariesBySpaceId[spaceId] ?? []).map(\.id))
        }

        let enriched: [RoomSummary] = summaries.compactMap { summary -> RoomSummary? in
            if childIds.contains(summary.id) {
                return nil
            }

            guard summary.isSpace else {
                return summary
            }

            let cachedChildRooms = cachedSpaceChildSummariesBySpaceId[summary.id]
            let cachedChildSpaces = cachedSpaceChildSpaceSummariesBySpaceId[summary.id]
            guard cachedChildRooms != nil || cachedChildSpaces != nil else {
                return summary
            }

            let childRooms = (cachedChildRooms ?? []).map {
                updatedSpaceChildSummary($0, localSummary: summariesById[$0.id])
            }
            let childSpaces = (cachedChildSpaces ?? []).map {
                updatedSpaceChildSummary($0, localSummary: summariesById[$0.id])
            }

            return enrichedSpaceSummaryFromCachedChildren(
                summary,
                childRooms: childRooms,
                childSpaces: childSpaces
            )
        }

        return enriched.enumerated()
            .sorted { lhs, rhs in
                spaceListSort(lhs.element, rhs.element, leftIndex: lhs.offset, rightIndex: rhs.offset)
            }
            .map { $0.element }
    }

    private static func enrichedSpaceSummaryFromCachedChildren(
        _ summary: RoomSummary,
        childRooms: [RoomSummary],
        childSpaces: [RoomSummary]
    ) -> RoomSummary {
        let visibleChildren = childRooms.filter { !$0.isMuted }
        let previewSource = visibleChildren.isEmpty ? childRooms : visibleChildren
        let previewChildren = previewSource.sorted(by: spaceActivitySort)
        let latestChild = previewChildren.first
        let latestVisibleChild = visibleChildren.isEmpty ? nil : latestChild

        return RoomSummary(
            id: summary.id,
            displayName: summary.displayName,
            avatarURL: summary.avatarURL,
            lastMessage: latestChild?.lastMessage,
            lastMessageSenderName: latestChild?.lastMessageSenderName,
            lastMessageTimestamp: latestVisibleChild?.lastMessageTimestamp,
            lastOwnMessageStatus: latestChild?.lastOwnMessageStatus,
            unreadCount: UInt64(visibleChildren.reduce(0) { $0 + Int($1.unreadCount) }),
            unreadMentionCount: UInt64(visibleChildren.reduce(0) { $0 + Int($1.unreadMentionCount) }),
            isMarkedUnread: visibleChildren.contains(where: \.isMarkedUnread),
            isEncrypted: summary.isEncrypted,
            isSpace: true,
            isMuted: summary.isMuted,
            directUserId: nil,
            spaceChildRoomCount: childRooms.count,
            spaceChildSpaceCount: childSpaces.count,
            spaceRecentRooms: Array(previewChildren.prefix(spaceRecentRoomLimit)).map {
                SpaceChildSummary(
                    id: $0.id,
                    displayName: $0.displayName,
                    avatarURL: $0.avatarURL,
                    directUserId: $0.directUserId
                )
            },
            spaceMetadata: summary.spaceMetadata
        )
    }

    private static func updatedSpaceChildSummary(
        _ cachedSummary: RoomSummary,
        localSummary: RoomSummary?
    ) -> RoomSummary {
        guard let localSummary else { return cachedSummary }

        let usesCachedSpaceRollup = cachedSummary.isSpace
        return RoomSummary(
            id: localSummary.id,
            displayName: localSummary.displayName,
            avatarURL: localSummary.avatarURL,
            lastMessage: usesCachedSpaceRollup ? cachedSummary.lastMessage : localSummary.lastMessage,
            lastMessageSenderName: usesCachedSpaceRollup
                ? cachedSummary.lastMessageSenderName
                : localSummary.lastMessageSenderName,
            lastMessageTimestamp: usesCachedSpaceRollup
                ? cachedSummary.lastMessageTimestamp
                : localSummary.lastMessageTimestamp,
            lastOwnMessageStatus: usesCachedSpaceRollup
                ? cachedSummary.lastOwnMessageStatus
                : localSummary.lastOwnMessageStatus,
            unreadCount: usesCachedSpaceRollup ? cachedSummary.unreadCount : localSummary.unreadCount,
            unreadMentionCount: usesCachedSpaceRollup
                ? cachedSummary.unreadMentionCount
                : localSummary.unreadMentionCount,
            isMarkedUnread: usesCachedSpaceRollup ? cachedSummary.isMarkedUnread : localSummary.isMarkedUnread,
            isEncrypted: localSummary.isEncrypted,
            isSpace: localSummary.isSpace,
            isMuted: localSummary.isMuted,
            directUserId: localSummary.directUserId,
            spaceChildRoomCount: usesCachedSpaceRollup
                ? cachedSummary.spaceChildRoomCount
                : localSummary.spaceChildRoomCount,
            spaceChildSpaceCount: usesCachedSpaceRollup
                ? cachedSummary.spaceChildSpaceCount
                : localSummary.spaceChildSpaceCount,
            spaceRecentRooms: usesCachedSpaceRollup ? cachedSummary.spaceRecentRooms : localSummary.spaceRecentRooms,
            spaceMetadata: cachedSummary.spaceMetadata ?? localSummary.spaceMetadata
        )
    }

    private static func spaceChildCaches(from storedChildren: [StoredSpaceChild]) -> SpaceChildCacheSnapshot {
        let grouped = Dictionary(grouping: storedChildren, by: \.spaceId)
        var roomsBySpaceId: [String: [RoomSummary]] = [:]
        var spacesBySpaceId: [String: [RoomSummary]] = [:]

        for (spaceId, children) in grouped {
            let sorted = children.sorted {
                if $0.isSpace != $1.isSpace {
                    return $0.isSpace && !$1.isSpace
                }
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            roomsBySpaceId[spaceId] = sorted
                .filter { !$0.isSpace }
                .map { $0.toRoomSummary() }
            spacesBySpaceId[spaceId] = sorted
                .filter(\.isSpace)
                .map { $0.toRoomSummary() }
        }

        return SpaceChildCacheSnapshot(
            roomsBySpaceId: roomsBySpaceId,
            spacesBySpaceId: spacesBySpaceId
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
            lastOwnMessageStatus: nil,
            unreadCount: 0,
            unreadMentionCount: 0,
            isMarkedUnread: false,
            isEncrypted: false,
            isSpace: preview.roomType == .space,
            isMuted: false,
            directUserId: nil,
            spaceChildRoomCount: 0,
            spaceChildSpaceCount: 0,
            spaceRecentRooms: [],
            spaceMetadata: SpaceRoomMetadata(spaceRoom: preview)
        )
    }

    private static func spaceChildSummary(
        from child: SpaceRoom,
        localSummary: RoomSummary?
    ) -> RoomSummary {
        guard let localSummary else {
            return previewSummary(from: child)
        }

        return RoomSummary(
            id: localSummary.id,
            displayName: localSummary.displayName,
            avatarURL: localSummary.avatarURL,
            lastMessage: localSummary.lastMessage,
            lastMessageSenderName: localSummary.lastMessageSenderName,
            lastMessageTimestamp: localSummary.lastMessageTimestamp,
            lastOwnMessageStatus: localSummary.lastOwnMessageStatus,
            unreadCount: localSummary.unreadCount,
            unreadMentionCount: localSummary.unreadMentionCount,
            isMarkedUnread: localSummary.isMarkedUnread,
            isEncrypted: localSummary.isEncrypted,
            isSpace: localSummary.isSpace,
            isMuted: localSummary.isMuted,
            directUserId: localSummary.directUserId,
            spaceChildRoomCount: localSummary.spaceChildRoomCount,
            spaceChildSpaceCount: localSummary.spaceChildSpaceCount,
            spaceRecentRooms: localSummary.spaceRecentRooms,
            spaceMetadata: SpaceRoomMetadata(spaceRoom: child)
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
        try await sendSpaceChildState(childId: childId, spaceId: spaceId)
        try? await sendSpaceParentState(spaceId: spaceId, childId: childId)
    }

    private func removeChildWithRawStateEvents(childId: String, spaceId: String) async throws {
        try await sendEmptySpaceChildState(childId: childId, spaceId: spaceId)
        try? await sendEmptySpaceParentState(spaceId: spaceId, childId: childId)
    }

    private func sendSpaceChildState(childId: String, spaceId: String) async throws {
        guard let spaceRoom = room(for: spaceId) else {
            throw spaceRelationshipError(String(localized: "Parent Storyline is not available locally."))
        }

        let content = try jsonString([
            "via": viaServers(for: childId),
            "suggested": false
        ])
        _ = try await spaceRoom.sendStateEventRaw(
            eventType: "m.space.child",
            stateKey: childId,
            content: content
        )
    }

    private func sendEmptySpaceChildState(childId: String, spaceId: String) async throws {
        guard let spaceRoom = room(for: spaceId) else {
            throw spaceRelationshipError(String(localized: "Parent Storyline is not available locally."))
        }

        _ = try await spaceRoom.sendStateEventRaw(
            eventType: "m.space.child",
            stateKey: childId,
            content: "{}"
        )
    }

    private func sendSpaceParentState(spaceId: String, childId: String) async throws {
        guard let childRoom = await waitForLocalRoom(roomId: childId) else {
            throw spaceRelationshipError(String(localized: "Chat is not available locally."))
        }

        let content = try jsonString([
            "via": viaServers(for: spaceId),
            "canonical": true
        ])
        _ = try await childRoom.sendStateEventRaw(
            eventType: "m.space.parent",
            stateKey: spaceId,
            content: content
        )
    }

    private func sendEmptySpaceParentState(spaceId: String, childId: String) async throws {
        guard let childRoom = await waitForLocalRoom(roomId: childId) else {
            throw spaceRelationshipError(String(localized: "Chat is not available locally."))
        }

        _ = try await childRoom.sendStateEventRaw(
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

    fileprivate static func writeSpaceChildrenToGRDB(
        _ children: SpaceChildrenSummary,
        for spaceId: String
    ) {
        let dbQueue = DatabaseService.shared.dbQueue
        let storedChildren = storedSpaceChildren(
            roomSummariesBySpaceId: [spaceId: children.rooms],
            spaceSummariesBySpaceId: [spaceId: children.spaces]
        )

        writeQueue.async {
            do {
                try dbQueue.write { db in
                    _ = try StoredSpaceChild
                        .filter(Column("spaceId") == spaceId)
                        .deleteAll(db)
                    for child in storedChildren {
                        try child.insert(db)
                    }
                }
                logRooms("Persisted \(storedChildren.count) children for space \(spaceId) to GRDB")
            } catch {
                logRooms("Failed to persist children for space \(spaceId): \(error)")
            }
        }
    }

    private static func storedSpaceChildren(
        roomSummariesBySpaceId: [String: [RoomSummary]],
        spaceSummariesBySpaceId: [String: [RoomSummary]]
    ) -> [StoredSpaceChild] {
        var result: [StoredSpaceChild] = []
        let spaceIds = Set(roomSummariesBySpaceId.keys).union(spaceSummariesBySpaceId.keys)

        for spaceId in spaceIds.sorted() {
            // `sortOrder` is scoped to each section: nested spaces first,
            // child rooms second. Readers split by `isSpace` before sorting.
            for (index, summary) in (spaceSummariesBySpaceId[spaceId] ?? []).enumerated() {
                result.append(StoredSpaceChild(
                    spaceId: spaceId,
                    summary: summary,
                    sortOrder: index
                ))
            }
            for (index, summary) in (roomSummariesBySpaceId[spaceId] ?? []).enumerated() {
                result.append(StoredSpaceChild(
                    spaceId: spaceId,
                    summary: summary,
                    sortOrder: index
                ))
            }
        }

        return result
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
                    _ = try StoredSpaceChild
                        .filter(Column("spaceId") == roomId || Column("childId") == roomId)
                        .deleteAll(db)
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
        let localOwnMessageStatus: LastOwnMessageStatus?
        let needsReadReceiptSummary: Bool
    }

    private static func extractLastMessage(from value: LatestEventValue) -> LatestMessagePreview {
        let timestamp: Date
        let content: TimelineItemContent
        let senderName: String?
        let localOwnMessageStatus: LastOwnMessageStatus?
        let needsReadReceiptSummary: Bool

        switch value {
        case .none:
            return LatestMessagePreview(
                body: nil,
                senderName: nil,
                timestamp: nil,
                localOwnMessageStatus: nil,
                needsReadReceiptSummary: false
            )
        case .remote(let ts, let sender, let isOwn, let profile, let c):
            timestamp = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            content = c
            senderName = Self.senderDisplayName(sender: sender, isOwn: isOwn, profile: profile)
            localOwnMessageStatus = isOwn ? .sent : nil
            needsReadReceiptSummary = isOwn
        case .local(let ts, let sender, let profile, let c, let state):
            timestamp = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            content = c
            senderName = Self.senderDisplayName(sender: sender, isOwn: true, profile: profile)
            localOwnMessageStatus = Self.lastOwnMessageStatus(from: state)
            needsReadReceiptSummary = false
        case .remoteInvite(let ts, _, _):
            return LatestMessagePreview(
                body: nil,
                senderName: nil,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000),
                localOwnMessageStatus: nil,
                needsReadReceiptSummary: false
            )
        }

        guard case .msgLike(let msgContent) = content else {
            return LatestMessagePreview(
                body: nil,
                senderName: senderName,
                timestamp: timestamp,
                localOwnMessageStatus: localOwnMessageStatus,
                needsReadReceiptSummary: needsReadReceiptSummary
            )
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
            return LatestMessagePreview(
                body: nil,
                senderName: senderName,
                timestamp: timestamp,
                localOwnMessageStatus: localOwnMessageStatus,
                needsReadReceiptSummary: needsReadReceiptSummary
            )
        @unknown default:
            return LatestMessagePreview(
                body: nil,
                senderName: senderName,
                timestamp: timestamp,
                localOwnMessageStatus: localOwnMessageStatus,
                needsReadReceiptSummary: needsReadReceiptSummary
            )
        }

        return LatestMessagePreview(
            body: text,
            senderName: senderName,
            timestamp: timestamp,
            localOwnMessageStatus: localOwnMessageStatus,
            needsReadReceiptSummary: needsReadReceiptSummary
        )
    }

    private static func resolveLastOwnMessageStatus(
        for room: Room,
        preview: LatestMessagePreview
    ) async -> LastOwnMessageStatus? {
        guard preview.needsReadReceiptSummary else {
            return preview.localOwnMessageStatus
        }

        guard let summary = try? await room.latestOwnMainTimelineReadReceiptSummary() else {
            return preview.localOwnMessageStatus
        }
        return summary.hasReadReceiptFromOtherUser ? .read : .sent
    }

    private static func lastOwnMessageStatus(from state: LatestEventValueLocalState) -> LastOwnMessageStatus {
        switch state {
        case .isSending:
            return .pending
        case .hasBeenSent:
            return .sent
        case .cannotBeSent:
            return .failed
        }
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

// MARK: - Space Children Observation

private actor SpaceChildrenLiveObserver {
    private let spaceId: String
    private let list: SpaceRoomList
    private let roomListService: ZynaRoomListService
    private let onUpdate: @MainActor (SpaceChildrenSummary) -> Void
    private var isCancelled = false
    private var isPaginating = false
    private var paginationTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var reloadPending = false
    private var lastPaginationState: SpaceRoomListPaginationState = .idle(endReached: false)
    private static let reloadDebounceDelay: Duration = .milliseconds(120)

    init(
        spaceId: String,
        list: SpaceRoomList,
        roomListService: ZynaRoomListService,
        onUpdate: @escaping @MainActor (SpaceChildrenSummary) -> Void
    ) {
        self.spaceId = spaceId
        self.list = list
        self.roomListService = roomListService
        self.onUpdate = onUpdate
    }

    func reloadAndEmit() async {
        reloadPending = false
        await emitCurrentChildren()
    }

    func scheduleReload() {
        guard !isCancelled else { return }
        reloadPending = true
        guard reloadTask == nil else { return }

        reloadTask = Task {
            do {
                try await Task.sleep(for: Self.reloadDebounceDelay)
            } catch {
                return
            }
            await self.performScheduledReloads()
        }
    }

    private func performScheduledReloads() async {
        while !isCancelled, reloadPending {
            reloadPending = false
            await emitCurrentChildren()
        }
        reloadTask = nil
    }

    private func emitCurrentChildren() async {
        guard !isCancelled else { return }
        let children = await list.rooms()
        guard !isCancelled else { return }
        if children.isEmpty, !paginationEndReached {
            return
        }
        let summary = await roomListService.buildSpaceChildrenSummary(from: children)
        guard !isCancelled else { return }
        roomListService.cacheSpaceChildren(summary, for: spaceId)
        ZynaRoomListService.writeSpaceChildrenToGRDB(summary, for: spaceId)
        roomListService.refreshPublishedSummariesFromSpaceChildCache(spaceId: spaceId)
        await MainActor.run {
            onUpdate(summary)
        }
    }

    func handlePaginationState(_ state: SpaceRoomListPaginationState) {
        guard !isCancelled else { return }
        lastPaginationState = state
        paginateIfNeeded()
    }

    func cancel() {
        isCancelled = true
        paginationTask?.cancel()
        paginationTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        reloadPending = false
    }

    private func paginateIfNeeded() {
        guard !isCancelled, !isPaginating else { return }
        guard case .idle(let endReached) = lastPaginationState, !endReached else { return }

        isPaginating = true
        paginationTask = Task { [list] in
            let shouldContinue: Bool
            do {
                try await list.paginate()
                shouldContinue = true
            } catch {
                shouldContinue = false
                logRooms("Space child pagination failed: \(error)")
            }
            await self.didFinishPagination(shouldContinue: shouldContinue)
        }
    }

    private func didFinishPagination(shouldContinue: Bool) async {
        guard !isCancelled else { return }
        isPaginating = false
        paginationTask = nil

        if shouldContinue {
            lastPaginationState = list.paginationState()
        }
        scheduleReload()

        guard shouldContinue, !isCancelled else { return }
        paginateIfNeeded()
    }

    private var paginationEndReached: Bool {
        if case .idle(let endReached) = lastPaginationState {
            return endReached
        }
        return false
    }
}

// MARK: - SDK Listeners

private final class EntriesListener: @unchecked Sendable, RoomListEntriesListener {
    private let handler: ([RoomListEntriesUpdate]) -> Void

    init(handler: @escaping ([RoomListEntriesUpdate]) -> Void) {
        self.handler = handler
    }

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        handler(roomEntriesUpdate)
    }
}

private final class ServiceStateListener: @unchecked Sendable, RoomListServiceStateListener {
    private let handler: (RoomListServiceState) -> Void

    init(handler: @escaping (RoomListServiceState) -> Void) {
        self.handler = handler
    }

    func onUpdate(state: RoomListServiceState) {
        handler(state)
    }
}

private final class LoadingStateListener: @unchecked Sendable, RoomListLoadingStateListener {
    private let handler: (RoomListLoadingState) -> Void

    init(handler: @escaping (RoomListLoadingState) -> Void) {
        self.handler = handler
    }

    func onUpdate(state: RoomListLoadingState) {
        handler(state)
    }
}

private final class SpaceRoomListEntriesCallback: @unchecked Sendable, SpaceRoomListEntriesListener {
    private let handler: ([SpaceListUpdate]) -> Void

    init(handler: @escaping ([SpaceListUpdate]) -> Void) {
        self.handler = handler
    }

    func onUpdate(rooms: [SpaceListUpdate]) {
        handler(rooms)
    }
}

private final class SpaceRoomListPaginationCallback: @unchecked Sendable, SpaceRoomListPaginationStateListener {
    private let handler: (SpaceRoomListPaginationState) -> Void

    init(handler: @escaping (SpaceRoomListPaginationState) -> Void) {
        self.handler = handler
    }

    func onUpdate(paginationState: SpaceRoomListPaginationState) {
        handler(paginationState)
    }
}

private final class SpaceRoomListSpaceCallback: @unchecked Sendable, SpaceRoomListSpaceListener {
    private let handler: (SpaceRoom?) -> Void

    init(handler: @escaping (SpaceRoom?) -> Void) {
        self.handler = handler
    }

    func onUpdate(space: SpaceRoom?) {
        handler(space)
    }
}
