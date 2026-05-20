//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

struct PublicRoomSearchResult: Equatable {
    let roomId: String
    let name: String
    let topic: String?
    let alias: String?
    let avatarURL: String?
    let joinedMembers: UInt64

    init(room: RoomDescription) {
        let displayName = room.name ?? room.alias ?? room.roomId
        self.roomId = room.roomId
        self.name = displayName
        self.topic = room.topic
        self.alias = room.alias
        self.avatarURL = room.avatarUrl
        self.joinedMembers = room.joinedMembers
    }
}

struct RoomsUnifiedSearchSnapshot {
    let query: String
    let localChats: [RoomModel]
    let users: [UserProfile]
    let publicRooms: [PublicRoomSearchResult]
    let isSearchingPeople: Bool
    let isSearchingRooms: Bool
    let errorMessage: String?
}

@MainActor
final class RoomsUnifiedSearchViewModel {

    var onSnapshotChanged: ((RoomsUnifiedSearchSnapshot) -> Void)?
    var onOpenTargetReady: ((ChatOpenTarget) -> Void)?
    var onError: ((String) -> Void)?

    private let roomListService: ZynaRoomListService

    private var query = ""
    private var localChats: [RoomModel] = []
    private var users: [UserProfile] = []
    private var publicRooms: [PublicRoomSearchResult] = []
    private var roomDescriptions: [RoomDescription] = []
    private var isSearchingPeople = false
    private var isSearchingRooms = false
    private var errorMessage: String?

    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?
    private var roomTask: Task<Void, Never>?
    private var directRoomTask: Task<Void, Never>?
    private var joinRoomTask: Task<Void, Never>?
    private var roomSearch: RoomDirectorySearch?
    private var roomSearchHandle: TaskHandle?
    private var roomSearchListener: RoomDirectoryEntriesListener?

    static let minimumRemoteQueryLength = 3
    private static let remoteSearchDelay: Duration = .milliseconds(350)
    private static let searchBatchSize: UInt32 = 20

    init(roomListService: ZynaRoomListService) {
        self.roomListService = roomListService
    }

    deinit {
        debounceTask?.cancel()
        peopleTask?.cancel()
        roomTask?.cancel()
        directRoomTask?.cancel()
        joinRoomTask?.cancel()
        roomSearchHandle?.cancel()
    }

    func update(query rawQuery: String, localChats: [RoomModel]) {
        generation += 1
        let currentGeneration = generation
        query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localChats = localChats
        users = []
        publicRooms = []
        roomDescriptions = []
        errorMessage = nil

        cancelRemoteSearch()

        guard query.count >= Self.minimumRemoteQueryLength else {
            isSearchingPeople = false
            isSearchingRooms = false
            publishSnapshot()
            return
        }

        isSearchingPeople = true
        isSearchingRooms = true
        publishSnapshot()

        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.remoteSearchDelay)
            } catch {
                return
            }

            await MainActor.run {
                guard let self, self.generation == currentGeneration else { return }
                // TODO(perf): if search grows to thousands of local rooms or
                // directory updates, move filtering/mapping off the main actor
                // and coalesce snapshots before reloading the Texture table.
                self.startPeopleSearch(query: self.query, generation: currentGeneration)
                self.startRoomDirectorySearch(query: self.query, generation: currentGeneration)
            }
        }
    }

    func clear() {
        generation += 1
        query = ""
        localChats = []
        users = []
        publicRooms = []
        roomDescriptions = []
        errorMessage = nil
        isSearchingPeople = false
        isSearchingRooms = false
        cancelRemoteSearch()
        publishSnapshot()
    }

    func openUser(_ user: UserProfile) {
        directRoomTask?.cancel()
        directRoomTask = Task { [weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                await MainActor.run { self.onError?(String(localized: "Matrix client is not ready.")) }
                return
            }

            do {
                if let existingRoom = try client.getDmRoom(userId: user.userId) {
                    await MainActor.run { self.onOpenTargetReady?(.live(existingRoom)) }
                    return
                }

                let roomId = try await client.createRoom(
                    request: CreateRoomParameters(
                        name: nil,
                        topic: nil,
                        isEncrypted: true,
                        isDirect: true,
                        visibility: .private,
                        preset: .trustedPrivateChat,
                        invite: [user.userId],
                        avatar: nil,
                        powerLevelContentOverride: nil,
                        joinRuleOverride: nil,
                        historyVisibilityOverride: nil,
                        canonicalAlias: nil
                    )
                )

                if let room = await self.waitForRoom(roomId: roomId) {
                    await MainActor.run { self.onOpenTargetReady?(.live(room)) }
                }
            } catch {
                await MainActor.run {
                    self.onError?(String(localized: "Failed to create chat: \(error.localizedDescription)"))
                }
            }
        }
    }

    func joinedRoom(for publicRoom: PublicRoomSearchResult) -> Room? {
        roomListService.room(for: publicRoom.roomId)
    }

    func joinPublicRoom(_ publicRoom: PublicRoomSearchResult) {
        if let existingRoom = roomListService.room(for: publicRoom.roomId) {
            onOpenTargetReady?(.live(existingRoom))
            return
        }

        joinRoomTask?.cancel()
        joinRoomTask = Task { [weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                await MainActor.run { self.onError?(String(localized: "Matrix client is not ready.")) }
                return
            }

            do {
                let roomIdOrAlias = publicRoom.alias ?? publicRoom.roomId
                let serverNames = Self.serverNames(for: publicRoom)
                let room = try await client.joinRoomByIdOrAlias(
                    roomIdOrAlias: roomIdOrAlias,
                    serverNames: serverNames
                )
                await MainActor.run { self.onOpenTargetReady?(.live(room)) }
            } catch {
                await MainActor.run {
                    self.onError?(String(localized: "Failed to join room: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func startPeopleSearch(query: String, generation: UInt64) {
        peopleTask?.cancel()
        peopleTask = Task { [weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                await MainActor.run {
                    guard self.generation == generation else { return }
                    self.users = []
                    self.isSearchingPeople = false
                    self.publishSnapshot()
                }
                return
            }

            do {
                let results = try await client.searchUsers(searchTerm: query, limit: 20)
                let currentUserId = try? client.userId()
                await MainActor.run {
                    guard self.generation == generation else { return }
                    self.users = results.results.filter { $0.userId != currentUserId }
                    self.isSearchingPeople = false
                    self.publishSnapshot()
                }
            } catch {
                await MainActor.run {
                    guard self.generation == generation else { return }
                    self.users = []
                    self.isSearchingPeople = false
                    self.errorMessage = error.localizedDescription
                    self.publishSnapshot()
                }
            }
        }
    }

    private func startRoomDirectorySearch(query: String, generation: UInt64) {
        roomTask?.cancel()
        roomSearchHandle?.cancel()
        roomSearchHandle = nil

        guard let client = MatrixClientService.shared.client else {
            isSearchingRooms = false
            publishSnapshot()
            return
        }

        let search = client.roomDirectorySearch()
        roomSearch = search
        let listener = RoomDirectoryEntriesListener { [weak self] updates in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                Self.applyRoomDirectoryUpdates(updates, to: &self.roomDescriptions)
                self.publicRooms = self.roomDescriptions.map(PublicRoomSearchResult.init)
                self.publishSnapshot()
            }
        }
        roomSearchListener = listener

        roomTask = Task { [weak self] in
            guard let self else { return }
            let handle = await search.results(listener: listener)
            await MainActor.run {
                guard self.generation == generation else {
                    handle.cancel()
                    return
                }
                self.roomSearchHandle = handle
            }

            do {
                try await search.search(
                    filter: query,
                    batchSize: Self.searchBatchSize,
                    viaServerName: nil
                )
                await MainActor.run {
                    guard self.generation == generation else { return }
                    self.isSearchingRooms = false
                    self.publishSnapshot()
                }
            } catch {
                await MainActor.run {
                    guard self.generation == generation else { return }
                    self.roomDescriptions = []
                    self.publicRooms = []
                    self.isSearchingRooms = false
                    self.errorMessage = error.localizedDescription
                    self.publishSnapshot()
                }
            }
        }
    }

    private func cancelRemoteSearch() {
        debounceTask?.cancel()
        debounceTask = nil
        peopleTask?.cancel()
        peopleTask = nil
        roomTask?.cancel()
        roomTask = nil
        roomSearchHandle?.cancel()
        roomSearchHandle = nil
        roomSearch = nil
        roomSearchListener = nil
    }

    private func publishSnapshot() {
        onSnapshotChanged?(
            RoomsUnifiedSearchSnapshot(
                query: query,
                localChats: localChats,
                users: users,
                publicRooms: publicRooms,
                isSearchingPeople: isSearchingPeople,
                isSearchingRooms: isSearchingRooms,
                errorMessage: errorMessage
            )
        )
    }

    private func waitForRoom(roomId: String) async -> Room? {
        for _ in 0..<20 {
            if let room = roomListService.room(for: roomId) {
                return room
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return roomListService.room(for: roomId)
    }

    private static func serverNames(for room: PublicRoomSearchResult) -> [String] {
        guard let alias = room.alias,
              let separator = alias.lastIndex(of: ":")
        else { return [] }

        let serverName = alias[alias.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return serverName.isEmpty ? [] : [serverName]
    }

    private static func applyRoomDirectoryUpdates(
        _ updates: [RoomDirectorySearchEntryUpdate],
        to rooms: inout [RoomDescription]
    ) {
        for update in updates {
            switch update {
            case .append(let values):
                rooms.append(contentsOf: values)
            case .clear:
                rooms.removeAll()
            case .pushFront(let value):
                rooms.insert(value, at: 0)
            case .pushBack(let value):
                rooms.append(value)
            case .popFront:
                guard !rooms.isEmpty else { continue }
                rooms.removeFirst()
            case .popBack:
                _ = rooms.popLast()
            case .insert(let index, let value):
                let idx = min(Int(index), rooms.count)
                rooms.insert(value, at: idx)
            case .set(let index, let value):
                let idx = Int(index)
                guard rooms.indices.contains(idx) else { continue }
                rooms[idx] = value
            case .remove(let index):
                let idx = Int(index)
                guard rooms.indices.contains(idx) else { continue }
                rooms.remove(at: idx)
            case .truncate(let length):
                let count = max(0, min(Int(length), rooms.count))
                rooms = Array(rooms.prefix(count))
            case .reset(let values):
                rooms = values
            }
        }
    }
}

private final class RoomDirectoryEntriesListener: RoomDirectorySearchEntriesListener {
    private let handler: @Sendable ([RoomDirectorySearchEntryUpdate]) -> Void

    init(handler: @escaping @Sendable ([RoomDirectorySearchEntryUpdate]) -> Void) {
        self.handler = handler
    }

    func onUpdate(roomEntriesUpdate: [RoomDirectorySearchEntryUpdate]) {
        handler(roomEntriesUpdate)
    }
}
