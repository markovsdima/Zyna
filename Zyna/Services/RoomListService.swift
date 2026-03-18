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
    let lastMessageTimestamp: Date?
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

    func room(for id: String) -> Room? {
        rooms.first { $0.id() == id }
    }
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
            applySingleUpdate(update)
        }

        let currentRooms = rooms
        roomsLog("Room count after diffs: \(currentRooms.count)")

        Task {
            var summaries: [RoomSummary] = []
            for room in currentRooms {
                guard let info = try? await room.roomInfo() else { continue }

                let (lastMessage, lastTimestamp) = Self.extractLastMessage(from: await room.latestEvent())

                summaries.append(RoomSummary(
                    id: room.id(),
                    displayName: room.displayName() ?? "Unknown",
                    avatarURL: room.avatarUrl(),
                    lastMessage: lastMessage,
                    lastMessageTimestamp: lastTimestamp,
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

    // swiftlint:disable:next cyclomatic_complexity
    private func applySingleUpdate(_ update: RoomListEntriesUpdate) {
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

    // MARK: - Last Message Extraction

    private static func extractLastMessage(from event: EventTimelineItem?) -> (String?, Date?) {
        guard let event else { return (nil, nil) }

        let timestamp = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)

        guard case .msgLike(let content) = event.content else { return (nil, nil) }

        let text: String
        switch content.kind {
        case .message(let message):
            text = textForMessageType(message.msgType)
        case .sticker:
            text = "Sticker"
        case .poll(let question, _, _, _, _, _, _):
            text = "Poll: \(question)"
        case .redacted:
            text = "..последнее сообщение удалено.."
        case .unableToDecrypt:
            text = "Encrypted message"
        case .other:
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
