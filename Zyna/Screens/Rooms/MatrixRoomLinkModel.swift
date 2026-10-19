// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import MatrixRustSDK

struct MatrixLinkedRoom: Sendable {
    var info: RoomPreviewInfo
    let via: [String]
    let canJoinRestricted: Bool
    var room: Room?

    enum Action: Equatable { case open, join, knock }

    var action: Action? {
        switch info.membership {
        case .joined: return .open
        case .invited: return .join
        case .banned, .knocked: return nil
        case .left, .none: break
        }
        switch info.joinRule {
        case .public, .none: return .join
        case .restricted: return canJoinRestricted ? .join : nil
        case .knock: return .knock
        case .knockRestricted: return canJoinRestricted ? .join : .knock
        case .invite, .private, .custom: return nil
        }
    }

    /// Used only for a space's existing navigation screen. Build off-main.
    func spaceModel() -> RoomModel {
        RoomModel(id: info.roomId, name: info.name ?? info.canonicalAlias ?? info.roomId,
            lastMessage: "", lastMessageSenderName: nil, lastOwnMessageStatus: nil,
            timestamp: "", avatar: AvatarViewModel(userId: info.roomId,
                displayName: info.name, mxcAvatarURL: info.avatarUrl),
            isOnline: false, unreadCount: 0, unreadMentionCount: 0, isMarkedUnread: false,
            isEncrypted: false, isSpace: true, directUserId: nil, spaceChildRoomCount: 0,
            spaceChildSpaceCount: 0, spaceRecentRooms: [],
            spaceMetadata: SpaceRoomMetadata(canonicalAlias: info.canonicalAlias, topic: info.topic,
                joinRule: info.joinRule, worldReadable: info.isHistoryWorldReadable,
                guestCanJoin: false, membership: info.membership, via: via,
                joinedMembersCount: info.numJoinedMembers, childrenCount: 0))
    }
}

protocol MatrixRoomLinkSource: Sendable {
    func load(_ link: MatrixRoomLink) async throws -> MatrixLinkedRoom
    func join(_ preview: MatrixLinkedRoom) async throws -> MatrixLinkedRoom
    func knock(_ preview: MatrixLinkedRoom) async throws
}

struct SDKMatrixRoomLinkSource: MatrixRoomLinkSource {
    let client: Client

    func load(_ link: MatrixRoomLink) async throws -> MatrixLinkedRoom {
        let worker = Task.detached { try await resolve(link) }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private func resolve(_ link: MatrixRoomLink) async throws -> MatrixLinkedRoom {
        var roomID = link.reference
        var via = link.via
        if link.reference.hasPrefix("#") {
            // Aliases can move between rooms. Resolve them even if an old
            // room's cached state still advertises the same canonical alias.
            guard let resolved = try await client.resolveRoomAlias(roomAlias: link.reference) else {
                throw URLError(.resourceUnavailable)
            }
            roomID = resolved.roomId
            for server in resolved.servers where !via.contains(server) { via.append(server) }
        }
        try Task.checkCancellation()
        if let room = try client.getRoom(roomId: roomID), room.membership() == .joined {
            return try await joined(room, via: via)
        }
        let preview = try await client.getRoomPreviewFromRoomId(roomId: roomID, viaServers: via)
        try Task.checkCancellation()
        let info = preview.info()
        // Sync may have accepted an invitation while the preview was loading.
        if let room = try client.getRoom(roomId: roomID), room.membership() == .joined {
            return try await joined(room, via: via)
        }
        return MatrixLinkedRoom(info: info, via: via,
            canJoinRestricted: canJoinRestricted(info.joinRule), room: nil)
    }

    private func canJoinRestricted(_ rule: JoinRule?) -> Bool {
        let rules: [AllowRule]
        switch rule {
        case .restricted(let values), .knockRestricted(let values): rules = values
        default: return false
        }
        return rules.contains {
            guard case .roomMembership(let id) = $0 else { return false }
            return (try? client.getRoom(roomId: id))?.membership() == .joined
        }
    }

    private func joined(_ room: Room, via: [String]) async throws -> MatrixLinkedRoom {
        let info = try await room.roomInfo()
        return MatrixLinkedRoom(info: RoomPreviewInfo(roomId: info.id,
            canonicalAlias: info.canonicalAlias, name: info.displayName ?? info.rawName,
            topic: info.topic, avatarUrl: info.avatarUrl,
            numJoinedMembers: info.joinedMembersCount, numActiveMembers: info.activeMembersCount,
            roomType: info.isSpace ? .space : .room, isHistoryWorldReadable: nil,
            membership: info.membership, joinRule: info.joinRule, isDirect: info.isDirect,
            heroes: info.heroes), via: via, canJoinRestricted: false, room: room)
    }

    func join(_ preview: MatrixLinkedRoom) async throws -> MatrixLinkedRoom {
        let worker = Task.detached {
            try Task.checkCancellation()
            let room: Room
            if let existing = try client.getRoom(roomId: preview.info.roomId), existing.membership() == .joined {
                room = existing
            } else {
                // Bind the action to the room that was previewed. An alias
                // may have been reassigned since the user opened the link.
                room = try await client.joinRoomByIdOrAlias(
                    roomIdOrAlias: preview.info.roomId, serverNames: preview.via)
            }
            // The join response already gives us a usable room. Do not wait
            // indefinitely for a sync echo before opening the chat.
            var value = preview
            value.info.membership = .joined
            value.room = room
            return value
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    func knock(_ preview: MatrixLinkedRoom) async throws {
        _ = try await client.knock(roomIdOrAlias: preview.info.roomId,
            reason: nil, serverNames: preview.via)
    }
}

@MainActor
final class MatrixRoomLinkModel: ObservableObject {
    @Published private(set) var preview: MatrixLinkedRoom?
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    let link: MatrixRoomLink
    var prepareOpen: ((MatrixLinkedRoom, String?) async throws -> PreparedPollNavigation)?
    var onReady: ((PreparedPollNavigation) -> Void)?
    var onNeedsPreview: (() -> Void)?
    var onFailure: (() -> Void)?
    var onCancelled: (() -> Void)?

    private let source: any MatrixRoomLinkSource
    private let isCurrentSession: () -> Bool
    private var started = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private let waitForTimeout: @Sendable (Duration) async throws -> Void
    private enum Opening { case preview, link, room }
    private var lastOpening = Opening.preview

    init(link: MatrixRoomLink, source: any MatrixRoomLinkSource,
         isCurrentSession: @escaping () -> Bool,
         waitForTimeout: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.waitForTimeout = waitForTimeout
        self.link = link
        self.source = source
        self.isCurrentSession = isCurrentSession
    }

    deinit { task?.cancel(); deadlineTask?.cancel() }
    var isCurrent: Bool { started && isCurrentSession() }

    func start() {
        guard !started else { return }
        started = true
        reload()
    }

    func reload() {
        run(opening: .link, limitsResolution: true) { [source, link] in try await source.load(link) }
    }

    func retry() {
        if lastOpening == .preview || preview?.action != .open { reload() }
        else { open(lastOpening) }
    }

    func openRoom() { open(.room) }

    private func open(_ opening: Opening) {
        guard let preview, preview.action == .open else { return }
        // The button opens the room the user has reviewed, even if its
        // alias was reassigned while the preview remained on screen.
        let target = MatrixRoomLink(reference: preview.info.roomId, via: preview.via,
                                    eventID: link.eventID)
        run(opening: opening, limitsResolution: true) { [source] in try await source.load(target) }
    }

    func performAction() {
        guard let preview, let action = preview.action else { return }
        switch action {
        case .open: open(.link)
        case .join: run(opening: .link) { [source] in try await source.join(preview) }
        case .knock:
            run(opening: .preview) { [source] in
                try await source.knock(preview)
                var value = preview
                value.info.membership = .knocked
                return value
            }
        }
    }

    private func run(opening: Opening, limitsResolution: Bool = false,
                     _ operation: @escaping () async throws -> MatrixLinkedRoom) {
        guard isCurrent, !isBusy else { return }
        generation += 1
        let generation = generation
        let eventID = opening == .link ? link.eventID : nil
        lastOpening = opening
        isBusy = true
        error = nil
        if limitsResolution { startDeadline(after: .seconds(10), generation: generation) }
        task = Task { [weak self] in
            var failed = false
            do {
                let value = try await operation()
                guard let self, self.accepts(generation) else { return }
                self.cancelDeadline()
                self.preview = value
                if opening != .preview, value.info.membership == .joined, let prepare = self.prepareOpen {
                    // The history loader has its own pagination budget, but
                    // an SDK await may outlive it while the network is down.
                    self.startDeadline(after: .seconds(35), generation: generation)
                    let prepared = try await prepare(value, eventID)
                    guard self.accepts(generation) else { return }
                    self.onReady?(PreparedPollNavigation { [weak self] in
                        guard let self, self.generation == generation, self.isCurrent else { return false }
                        return prepared.open()
                    })
                } else {
                    self.onNeedsPreview?()
                }
            } catch {
                guard let self, self.accepts(generation) else { return }
                if error is CancellationError {
                    // History navigation can be superseded without cancelling
                    // this task. Finish its UI too; no error alert is needed.
                    self.generation += 1
                    self.cancelDeadline()
                    self.isBusy = false
                    self.onCancelled?()
                    return
                }
                if let failure = error as? PollNavigationError {
                    self.error = failure == .unavailable
                        ? String(localized: "This message is unavailable or hidden.", table: "MatrixLinks")
                        : String(localized: "Couldn't load this message. Please try again.", table: "MatrixLinks")
                } else {
                    self.error = MatrixActionFailure.message(for: error,
                        action: self.preview == nil ? .previewRoom : .roomAction)
                }
                failed = self.error != nil
            }
            if let self, self.generation == generation {
                self.cancelDeadline()
                self.isBusy = false
                if failed { self.onFailure?() }
            }
        }
    }

    private func startDeadline(after duration: Duration, generation: Int) {
        cancelDeadline()
        let waitForTimeout = waitForTimeout
        deadlineTask = Task { [weak self] in
            do { try await waitForTimeout(duration) } catch { return }
            guard let self, self.accepts(generation), self.isBusy else { return }
            // Invalidate first. Do not await cancellation: a suspended SDK
            // request may keep waiting for connectivity despite cancellation.
            self.generation += 1
            self.task?.cancel()
            self.deadlineTask = nil
            self.isBusy = false
            self.error = String(localized: "The server took too long to respond. Check your connection and try again.")
            self.onFailure?()
        }
    }

    private func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    func routingFailed() {
        guard isCurrent else { return }
        error = String(localized: "Couldn't open this link. Please try again.", table: "MatrixLinks")
        isBusy = false
        onFailure?()
    }

    private func accepts(_ value: Int) -> Bool {
        generation == value && isCurrent && !Task.isCancelled
    }

    func stop() {
        started = false
        generation += 1
        task?.cancel()
        cancelDeadline()
        isBusy = false
    }

    #if DEBUG
    var operationForTesting: Task<Void, Never>? { task }
    func waitForOperationForTesting() async { await task?.value }
    #endif
}
