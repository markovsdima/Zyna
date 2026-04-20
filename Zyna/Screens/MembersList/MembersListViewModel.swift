//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

final class MembersListViewModel {

    /// Flat row stream so the VC works with 1D indexPaths.
    enum Row {
        case header(String)
        case member(MemberCellNode.Model)
    }

    private struct Classified {
        let invited: [MemberCellNode.Model]
        let joined: [MemberCellNode.Model]
    }

    /// Structural row stream — emits only on add/remove/sort changes,
    /// not on presence ticks. The VC drives a `reloadData()` from this.
    @Published private(set) var rows: [Row] = []
    @Published private(set) var isLoading: Bool = true

    /// Presence ticks for in-place cell updates. Decoupled from `rows`
    /// so a presence flap doesn't tear down all visible cells via a
    /// full table reload.
    let presenceTicks = PassthroughSubject<[String: UserPresence], Never>()

    private let room: Room
    private let presenceTag: String
    private var invited: [MemberCellNode.Model] = []
    private var joined: [MemberCellNode.Model] = []
    private var cancellables = Set<AnyCancellable>()
    private var roomInfoSubscription: TaskHandle?

    /// Coalescing reload flags. Touched only on main — MainActor
    /// isolation gives us exclusivity without a lock.
    private var isReloading = false
    private var needsReload = false

    /// Coalesces a burst of room-info callbacks into a single reload.
    /// `isReloading` only prevents overlap — 5 events still queue 5
    /// sequential reloads otherwise.
    private var roomInfoDebounce: DispatchWorkItem?
    private static let roomInfoDebounceMillis = 300

    init(room: Room) {
        self.room = room
        self.presenceTag = "members-list-\(room.id())"
        subscribePresence()
        reload()
        subscribeToRoomInfoUpdates()
    }

    deinit {
        roomInfoSubscription?.cancel()
        roomInfoDebounce?.cancel()
        PresenceTracker.shared.unregister(for: presenceTag)
    }

    // MARK: - Load

    /// SDK call + model construction off-main; publish on main.
    private func reload() {
        if isReloading {
            needsReload = true
            return
        }
        isReloading = true

        Task { [weak self] in
            guard let self else { return }

            // Two-phase load: the cached pass paints instantly so the
            // list isn't blank during sync; the authoritative pass then
            // overwrites with whatever changed (e.g. invites accepted
            // server-side after the cache was populated).
            if let cached = await self.loadOnce(noSync: true) {
                await MainActor.run { self.apply(cached) }
            }
            let synced = await self.loadOnce(noSync: false)
            await MainActor.run {
                if let synced { self.apply(synced) }
                self.isLoading = false
                self.isReloading = false
                if self.needsReload {
                    self.needsReload = false
                    self.reload()
                }
            }
        }
    }

    private func apply(_ result: Classified) {
        invited = result.invited
        joined = result.joined
        registerPresence()
        bakePresenceAndRebuild()
        isLoading = false
    }

    private func loadOnce(noSync: Bool) async -> Classified? {
        do {
            let iterator = try await (noSync ? room.membersNoSync() : room.members())
            let chunk = iterator.nextChunk(chunkSize: 10_000) ?? []
            guard !chunk.isEmpty else { return nil }
            return Self.classify(chunk)
        } catch {
            ScopedLog(.rooms)("Failed to load members (noSync=\(noSync)): \(error)")
            return nil
        }
    }

    private static func classify(_ members: [RoomMember]) -> Classified {
        var invited: [MemberCellNode.Model] = []
        var joined: [MemberCellNode.Model] = []
        for member in members {
            let model = buildModel(from: member)
            switch member.membership {
            case .invite: invited.append(model)
            case .join:   joined.append(model)
            default:      continue // banned / left / knocked — skipped in MVP
            }
        }
        return Classified(invited: invited, joined: joined)
    }

    private static func buildModel(from member: RoomMember) -> MemberCellNode.Model {
        let level: Int
        switch member.powerLevel {
        case .infinite:         level = 100
        case .value(let value): level = Int(value)
        }
        return MemberCellNode.Model(
            userId: member.userId,
            displayName: member.displayName,
            avatarUrl: member.avatarUrl,
            role: .from(powerLevel: level),
            presence: nil
        )
    }

    // MARK: - Presence

    /// Subscribed once at init so repeated reloads don't stack sinks.
    private func subscribePresence() {
        PresenceTracker.shared.$statuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.handlePresenceTick(statuses)
            }
            .store(in: &cancellables)
    }

    private func registerPresence() {
        let userIds = (invited + joined).map(\.userId)
        PresenceTracker.shared.register(userIds: userIds, for: presenceTag)
    }

    /// Update underlying model state for the next structural rebuild,
    /// then fan out the tick. The list does NOT resort — keeping order
    /// stable while a member is on screen avoids visual churn, and
    /// matches user expectation (members rarely flip online mid-glance).
    private func handlePresenceTick(_ statuses: [String: UserPresence]) {
        for i in invited.indices {
            invited[i].presence = statuses[invited[i].userId]
        }
        for i in joined.indices {
            joined[i].presence = statuses[joined[i].userId]
        }
        presenceTicks.send(statuses)
    }

    /// Bakes current presence into the model arrays then sorts and
    /// emits new rows. Called from structural reload paths only.
    private func bakePresenceAndRebuild() {
        let statuses = PresenceTracker.shared.statuses
        for i in invited.indices {
            invited[i].presence = statuses[invited[i].userId]
        }
        for i in joined.indices {
            joined[i].presence = statuses[joined[i].userId]
        }
        rebuildRows()
    }

    // MARK: - Room Info subscription

    private func subscribeToRoomInfoUpdates() {
        // Callback fires off-main; bounce so flags stay MainActor-isolated.
        let listener = RoomInfoCallbackListener { [weak self] in
            DispatchQueue.main.async { self?.scheduleDebouncedReload() }
        }
        roomInfoSubscription = room.subscribeToRoomInfoUpdates(listener: listener)
    }

    private func scheduleDebouncedReload() {
        roomInfoDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        roomInfoDebounce = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.roomInfoDebounceMillis),
            execute: work
        )
    }

    // MARK: - Rows

    private func rebuildRows() {
        invited.sort(by: Self.order)
        joined.sort(by: Self.order)

        var next: [Row] = []
        if !invited.isEmpty {
            next.append(.header(String(localized: "Invited")))
            next.append(contentsOf: invited.map(Row.member))
        }
        if !joined.isEmpty {
            // "Members" header only when separating from Invited above.
            if !invited.isEmpty {
                next.append(.header(String(localized: "Members")))
            }
            next.append(contentsOf: joined.map(Row.member))
        }
        rows = next
    }

    /// Online first, then lastSeen descending. No-presence users sink.
    private static func order(_ a: MemberCellNode.Model, _ b: MemberCellNode.Model) -> Bool {
        let aOnline = a.presence?.online ?? false
        let bOnline = b.presence?.online ?? false
        if aOnline != bOnline { return aOnline }
        let aSeen = a.presence?.lastSeen ?? .distantPast
        let bSeen = b.presence?.lastSeen ?? .distantPast
        return aSeen > bSeen
    }
}

// MARK: - Room Info listener

private final class RoomInfoCallbackListener: RoomInfoListener {
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func call(roomInfo: RoomInfo) {
        callback()
    }
}
