// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import GRDB
import MatrixRustSDK

enum RoomPinnedActionError: Error { case timelineUnavailable }

struct RoomPinnedSnapshot: Equatable, Sendable {
    var eventIDs: [String]
    // nil means the SDK could not read permissions, not a revocation.
    var canUnpin: Bool?

    init(eventIDs: [String], canUnpin: Bool?) {
        var seen = Set<String>()
        self.eventIDs = eventIDs.filter { $0.hasPrefix("$") && seen.insert($0).inserted }
        self.canUnpin = canUnpin
    }

    init(_ info: RoomInfo) {
        self.init(eventIDs: info.pinnedEventIds, canUnpin: info.membership == .joined
            ? info.powerLevels?.canOwnUserPinUnpin() : false)
    }
}

struct RoomPinnedItem: Equatable, Sendable {
    let eventId: String
    let title: String
    let subtitle: String?
    var canOpen = true
    var canUnpin = false
    var isUnpinning = false
    var unpinError: String?
}

/// Deduplicate raw records before decoding previews. Message writes can
/// invalidate GRDB's table region even when no pinned event has changed.
struct RoomPinnedRecords: Equatable {
    let eventIDs: [String]
    let records: [StoredMessage?]
    let ignored: Set<String>

    static func read(eventIDs: [String], roomID: String, db: Database) throws -> Self {
        let ignored = try IgnoredContentStore.userIDs(in: db)
        var byID: [String: StoredMessage] = [:]
        // Usually one indexed query. Bound the arguments even for unusually
        // large pin state events, below SQLite's minimum variable limit.
        for start in stride(from: 0, to: eventIDs.count, by: 500) {
            let ids = eventIDs[start..<min(start + 500, eventIDs.count)]
            let batch = try StoredMessage.filter(Column("roomId") == roomID)
                .filter(ids.contains(Column("eventId"))).fetchAll(db)
            for record in batch {
                if let id = record.eventId { byID[id] = record }
            }
        }
        return Self(eventIDs: eventIDs, records: eventIDs.map { byID[$0] }, ignored: ignored)
    }

    func items() -> [RoomPinnedItem] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return zip(eventIDs, records).compactMap { id, stored in
            guard let stored else {
                return RoomPinnedItem(eventId: id, title: String(localized: "Pinned message"),
                    subtitle: String(localized: "Message not loaded yet"))
            }
            guard !ignored.contains(stored.senderId) else { return nil }
            let message = stored.toChatMessage()
            let preview = message?.content.textPreview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sender = stored.senderDisplayName.flatMap { $0.isEmpty ? nil : $0 } ?? stored.senderId
            let date = formatter.string(from: Date(timeIntervalSince1970: stored.timestamp))
            return RoomPinnedItem(eventId: id, title: preview.isEmpty ? String(localized: "Pinned message") : preview,
                subtitle: "\(sender) · \(date)",
                canOpen: ChatCatalogTarget.message.accepts(stored.contentType))
        }
    }
}

protocol RoomPinnedSource: Sendable {
    func load() async throws -> RoomPinnedSnapshot
    func unpin(_ eventID: String) async throws
    func observe(_ update: @escaping @Sendable (RoomPinnedSnapshot) -> Void) -> RoomProfileObservation
}

struct SDKRoomPinnedSource: RoomPinnedSource {
    let room: any RoomProtocol
    let removePin: @MainActor @Sendable (String) async throws -> Void

    func load() async throws -> RoomPinnedSnapshot {
        try await Task.detached {
            var snapshot = RoomPinnedSnapshot(try await room.roomInfo())
            // RoomInfo suppresses store errors. Retry that local read once:
            // sync may have supplied the missing state in the meantime.
            if snapshot.canUnpin == nil, let powers = try? await room.getPowerLevels() {
                snapshot.canUnpin = powers.canOwnUserPinUnpin()
            }
            return snapshot
        }.value
    }
    func unpin(_ eventID: String) async throws { try await removePin(eventID) }
    func observe(_ update: @escaping @Sendable (RoomPinnedSnapshot) -> Void) -> RoomProfileObservation {
        let handle = room.subscribeToRoomInfoUpdates(listener: PinnedInfoListener(update))
        return RoomProfileObservation { handle.cancel() }
    }
}

private final class PinnedInfoListener: RoomInfoListener {
    let update: @Sendable (RoomPinnedSnapshot) -> Void
    init(_ update: @escaping @Sendable (RoomPinnedSnapshot) -> Void) { self.update = update }
    func call(roomInfo: RoomInfo) { update(RoomPinnedSnapshot(roomInfo)) }
}

@MainActor
final class RoomPinnedMessagesModel: ObservableObject {
    @Published private(set) var items: [RoomPinnedItem] = []
    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published private(set) var actionError: String?
    private(set) var snapshot: RoomPinnedSnapshot?
    private let source: any RoomPinnedSource
    private let database: AccountDatabase
    private let roomID: String
    private let isCurrentSession: () -> Bool
    private var roomObservation: RoomProfileObservation?
    private var itemObservation: AnyDatabaseCancellable?
    private let projectionQueue = DispatchQueue(label: "zyna.profile.pins", qos: .userInitiated)
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var storedItems: [RoomPinnedItem] = []
    private var removingID: String?
    private var failedUnpinID: String?
    private var started = false
    private var generation = 0
    private var revision = 0
    private var itemRevision = 0

    init(roomID: String, database: AccountDatabase, source: any RoomPinnedSource,
         isCurrentSession: @escaping () -> Bool) {
        self.roomID = roomID
        self.database = database
        self.source = source
        self.isCurrentSession = isCurrentSession
    }

    deinit { readTask?.cancel(); writeTask?.cancel() }

    func start() {
        guard !started, isCurrentSession() else { return }
        started = true
        generation += 1
        let generation = generation
        roomObservation = source.observe { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(generation) else { return }
                let resolved = self.resolvingPermissions(value)
                guard resolved != self.snapshot else { return }
                self.revision += 1
                self.apply(resolved)
            }
        }
        reload()
    }

    func reload() {
        guard started, isCurrentSession(), removingID == nil else { return }
        readTask?.cancel()
        revision += 1
        let revision = revision, generation = generation, source = source
        loadError = nil
        isLoading = snapshot == nil
        // Database recovery is independent of the room-info read. A newer
        // room update may supersede that read without cancelling this retry.
        if let snapshot { observeItems(snapshot.eventIDs) }
        readTask = Task { [weak self] in
            do {
                let value = try await source.load()
                guard let self, self.accepts(generation) else { return }
                if self.revision != revision {
                    // An initial listener snapshot can arrive while the
                    // fallback permission read is running. Fill only an
                    // unknown permission, never replace newer pins or rights.
                    if var current = self.snapshot, current.canUnpin == nil, value.canUnpin != nil {
                        current.canUnpin = value.canUnpin
                        self.apply(current)
                    }
                    return
                }
                self.apply(value)
            } catch {
                guard let self, self.accepts(generation), self.revision == revision else { return }
                self.loadError = MatrixActionFailure.message(for: error, action: .loadPins)
                self.isLoading = false
            }
        }
    }

    func unpin(_ eventID: String) {
        guard started, isCurrentSession(), removingID == nil,
              snapshot?.canUnpin == true, snapshot?.eventIDs.contains(eventID) == true else { return }
        readTask?.cancel()
        revision += 1
        let revision = revision, generation = generation, source = source
        removingID = eventID
        actionError = nil
        publish()
        writeTask = Task { [weak self] in
            do {
                let fresh = try await source.load()
                guard let self, self.accepts(generation) else { return }
                if self.revision == revision { self.apply(fresh) }
                // A failed permission read is not an explicit revocation.
                // Keep the last known value; the SDK/server validates writes.
                guard fresh.canUnpin != false, self.snapshot?.canUnpin == true else {
                    self.finishUnpin(error: String(localized: "You don't have permission to do this."))
                    return
                }
                if fresh.eventIDs.contains(eventID), self.snapshot?.eventIDs.contains(eventID) == true {
                    try await source.unpin(eventID)
                }
                guard self.accepts(generation) else { return }
                // Keep other live changes. The next room snapshot remains
                // authoritative, including a subsequent re-pin.
                if self.revision == revision, var value = self.snapshot {
                    value.eventIDs.removeAll { $0 == eventID }
                    self.apply(value)
                }
                self.finishUnpin(error: nil)
            } catch {
                guard let self, self.accepts(generation) else { return }
                self.finishUnpin(error: MatrixActionFailure.message(for: error, action: .unpin))
            }
        }
    }

    func stop() {
        started = false
        generation += 1
        readTask?.cancel(); writeTask?.cancel()
        roomObservation = nil
        itemObservation = nil
        removingID = nil
    }

    private func resolvingPermissions(_ value: RoomPinnedSnapshot) -> RoomPinnedSnapshot {
        var value = value
        if value.canUnpin == nil { value.canUnpin = snapshot?.canUnpin }
        return value
    }

    private func apply(_ value: RoomPinnedSnapshot) {
        let value = resolvingPermissions(value)
        guard snapshot != value || itemObservation == nil else { return }
        let changed = snapshot?.eventIDs != value.eventIDs
        snapshot = value
        if changed || itemObservation == nil { observeItems(value.eventIDs) }
        publish()
    }

    private func observeItems(_ eventIDs: [String]) {
        itemObservation = nil
        itemRevision += 1
        let itemRevision = itemRevision, generation = generation, roomID = roomID
        if eventIDs.isEmpty {
            storedItems = []; loadError = nil; isLoading = false; publish()
            return
        }
        let ids = Set(eventIDs)
        storedItems.removeAll { !ids.contains($0.eventId) }
        let observation = ValueObservation.tracking { db in
            try RoomPinnedRecords.read(eventIDs: eventIDs, roomID: roomID, db: db)
        }.removeDuplicates()
        itemObservation = database.observe(observation, on: projectionQueue, onError: { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(generation), self.itemRevision == itemRevision else { return }
                self.itemObservation = nil
                self.loadError = MatrixActionFailure.message(for: error, action: .loadPins)
                self.isLoading = false
            }
        }, onChange: { [weak self] records in
            let items = records.items()
            Task { @MainActor [weak self] in
                guard let self, self.accepts(generation), self.itemRevision == itemRevision else { return }
                self.storedItems = items
                self.loadError = nil
                self.isLoading = false
                self.publish()
            }
        })
    }

    private func finishUnpin(error: String?) {
        failedUnpinID = error == nil ? nil : removingID
        removingID = nil
        actionError = error
        publish()
    }

    private func publish() {
        let next = storedItems.map { item in
            var item = item
            item.canUnpin = snapshot?.canUnpin == true && removingID == nil
            item.isUnpinning = removingID == item.eventId
            item.unpinError = failedUnpinID == item.eventId ? actionError : nil
            return item
        }
        if next != items { items = next }
    }

    private func accepts(_ generation: Int) -> Bool {
        started && self.generation == generation && !Task.isCancelled && database.isActive && isCurrentSession()
    }

    #if DEBUG
    func waitForOperationsForTesting() async { await readTask?.value; await writeTask?.value }
    #endif
}
