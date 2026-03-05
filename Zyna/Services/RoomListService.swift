//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

// MARK: - Room Summary (UI-friendly model)

struct RoomSummary: Identifiable {
    let id: String
    let displayName: String
    let avatarURL: String?
    let lastMessage: String?
    let unreadCount: UInt64
    let isEncrypted: Bool
}

private let roomsLog = ScopedLog(.rooms)

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
    private var isListening = false
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        observeClientState()
    }

    private func observeClientState() {
        matrixService.stateSubject
            .sink { [weak self] state in
                roomsLog("Client state changed: \(state)")
                if case .syncing = state {
                    self?.startListening()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    private func startListening() {
        guard let sdkRoomListService = matrixService.roomListService else {
            roomsLog("roomListService is nil, cannot start listening")
            return
        }

        guard !isListening else {
            roomsLog("Already listening, skipping")
            return
        }
        isListening = true
        self.roomListService = sdkRoomListService

        // Observe RoomListService state
        let stateListener = ServiceStateListener { state in
            roomsLog("RoomListService state: \(state)")
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
                        roomsLog("Received \(updates.count) room list entry updates")
                        self.applyUpdates(updates)
                    }
                )
                self.listUpdatesResult = result

                // Forces the listener to be called with the current state
                _ = result.controller().setFilter(kind: .all(filters: [.nonLeft]))

                // Observe loading state — store stateStream handle to keep it alive
                let loadingResult = try roomList.loadingState(listener: LoadingStateListener { state in
                    roomsLog("RoomList loading state: \(state)")
                })
                self.loadingStateStreamHandle = loadingResult.stateStream
                roomsLog("Initial loading state: \(loadingResult.state)")

                roomsLog("Room list listener started")
            } catch {
                roomsLog("Failed to start room list listener: \(error)")
            }
        }
    }

    // MARK: - Apply Diffs

    private func applyUpdates(_ updates: [RoomListEntriesUpdate]) {
        for update in updates {
            switch update {
            case .reset(let values):
                rooms = values
            case .append(let values):
                rooms.append(contentsOf: values)
            case .pushBack(let value):
                rooms.append(value)
            case .pushFront(let value):
                rooms.insert(value, at: 0)
            case .insert(let index, let value):
                rooms.insert(value, at: Int(index))
            case .set(let index, let value):
                if Int(index) < rooms.count {
                    rooms[Int(index)] = value
                }
            case .remove(let index):
                if Int(index) < rooms.count {
                    rooms.remove(at: Int(index))
                }
            case .popBack:
                if !rooms.isEmpty { rooms.removeLast() }
            case .popFront:
                if !rooms.isEmpty { rooms.removeFirst() }
            case .truncate(let length):
                rooms = Array(rooms.prefix(Int(length)))
            case .clear:
                rooms = []
            }
        }

        let currentRooms = rooms
        roomsLog("Room count after diffs: \(currentRooms.count)")

        Task {
            var summaries: [RoomSummary] = []
            for room in currentRooms {
                guard let info = try? await room.roomInfo() else { continue }
                summaries.append(RoomSummary(
                    id: room.id(),
                    displayName: room.displayName() ?? "Unknown",
                    avatarURL: room.avatarUrl(),
                    lastMessage: nil,  // TODO: extract from timeline
                    unreadCount: info.notificationCount,
                    isEncrypted: room.encryptionState() != .notEncrypted
                ))
            }

            await MainActor.run { [weak self] in
                self?.roomsSubject.send(summaries)
            }

            roomsLog("Rooms updated: \(summaries.count) rooms")
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
