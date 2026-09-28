//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

struct RoomPollHistoryState: Equatable, Sendable {
    var generation = 0
    var rowCount = 0
    var pendingCount = 0
    var pendingSessionIDs: [String] = []
    var error: String?
}

@MainActor
protocol RoomPollHistorySource: AnyObject {
    var onChange: ((RoomPollHistoryState) -> Void)? { get set }
    func start() async throws
    func loadMore() async throws -> Bool
    func synchronize() async throws
    func retryDecryption()
    func stop()
}

/// A poll-only view of the shared SDK event cache, created on first access.
@MainActor
final class SDKRoomPollHistorySource: RoomPollHistorySource {
    // Encrypted items must survive filtering until their type is known.
    // The unstable types are the format emitted by the currently linked SDK.
    nonisolated static var filter: TimelineFilter {
        .eventFilter(filter: .includeEventTypes(eventTypes: [
            .messageLike(eventType: .unstablePollStart),
            .messageLike(eventType: .pollStart),
            .messageLike(eventType: .roomEncrypted)
        ]))
    }

    var onChange: ((RoomPollHistoryState) -> Void)?
    private let room: Room
    private let store: RoomPollHistoryStore
    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?
    private var pendingSessionIDs: [String] = []
    private var stopped = false

    init(room: Room, userID: String, catalog: RoomPollCatalog) {
        self.room = room
        store = RoomPollHistoryStore(catalog: catalog, userID: userID)
        store.onChange = { [weak self] state in
            guard let self, !self.stopped else { return }
            self.pendingSessionIDs = state.pendingSessionIDs
            self.onChange?(state)
        }
    }

    deinit { listenerHandle?.cancel() }

    func start() async throws {
        guard !stopped else { throw CancellationError() }
        guard timeline == nil else { return }
        let timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
            focus: .live(hideThreadedEvents: false), filter: Self.filter,
            internalIdPrefix: "poll-catalog", dateDividerMode: .daily,
            trackReadReceipts: .disabled, reportUtds: false))
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        let handle = await timeline.addListener(listener: PollHistoryListener(store: store))
        guard !stopped, !Task.isCancelled else {
            handle.cancel()
            throw CancellationError()
        }
        self.timeline = timeline
        listenerHandle = handle
    }

    func loadMore() async throws -> Bool {
        guard !stopped, !Task.isCancelled, let timeline else { throw CancellationError() }
        let reachedStart = try await timeline.paginateBackwards(numEvents: 100)
        // The event-cache reply can precede the listener's diff delivery.
        try await Task.sleep(for: .milliseconds(20))
        try await synchronize()
        return reachedStart
    }

    func synchronize() async throws { try await store.synchronize() }

    func retryDecryption() {
        guard !stopped, !pendingSessionIDs.isEmpty else { return }
        timeline?.retryDecryption(sessionIds: pendingSessionIDs)
    }

    func stop() {
        stopped = true
        listenerHandle?.cancel()
        listenerHandle = nil
        timeline = nil
        onChange = nil
        store.stop()
    }
}

private final class PollHistoryListener: TimelineListener {
    private let store: RoomPollHistoryStore
    init(store: RoomPollHistoryStore) { self.store = store }
    func onUpdate(diff: [TimelineDiff]) { store.enqueue(diff) }
}

struct RoomPollHistoryRow {
    var record: StoredMessage?
    var isPollStart = false
    var senderProfile: PollSenderProfile = .unavailable
    var pending: PendingDecryption?
}

enum RoomPollHistoryDiff {
    case append([RoomPollHistoryRow]), reset([RoomPollHistoryRow])
    case pushFront(RoomPollHistoryRow), pushBack(RoomPollHistoryRow)
    case insert(Int, RoomPollHistoryRow), set(Int, RoomPollHistoryRow)
    case remove(Int), truncate(Int)
    case clear, popFront, popBack
}

/// Maintains SDK positions only for undecrypted rows. Catalog writes preserve
/// event identity and survive timeline resets, trims, and reopens.
final class RoomPollHistoryStore: @unchecked Sendable {
    var onChange: ((RoomPollHistoryState) -> Void)?
    private let queue = DispatchQueue(label: "com.zyna.polls.history", qos: .userInitiated)
    private let catalog: RoomPollCatalog
    private let userID: String
    private var rows: [PendingDecryption?] = []
    private var pendingWrites: [(record: StoredMessage, isPollStart: Bool, senderProfile: PollSenderProfile)] = []
    private var state = RoomPollHistoryState()
    private var stopped = false

    init(catalog: RoomPollCatalog, userID: String) {
        self.catalog = catalog
        self.userID = userID
    }

    func enqueue(_ diffs: [TimelineDiff]) {
        queue.async { [self] in
            guard !stopped else { return }
            applyOnQueue(diffs.map(map))
        }
    }

    /// Test seam for the same positional mutations used by SDK callbacks.
    func apply(_ diffs: [RoomPollHistoryDiff]) {
        queue.sync { applyOnQueue(diffs) }
    }

    func synchronize() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !stopped else { throw CancellationError() }
                    try flush()
                    publish { continuation.resume() }
                } catch {
                    publish(error: error) { continuation.resume(throwing: error) }
                }
            }
        }
    }

    func stop() { queue.async { [self] in stopped = true; pendingWrites.removeAll(); rows.removeAll() } }

    private func flush() throws {
        try catalog.ingest(pendingWrites)
        pendingWrites.removeAll()
    }

    private func applyOnQueue(_ diffs: [RoomPollHistoryDiff]) {
        guard !stopped else { return }
        func discover(_ values: [RoomPollHistoryRow]) -> [PendingDecryption?] {
            for row in values {
                if let record = row.record { pendingWrites.append((record, row.isPollStart, row.senderProfile)) }
            }
            return values.map(\.pending)
        }
        for diff in diffs {
            switch diff {
            case .append(let values): rows.append(contentsOf: discover(values))
            case .reset(let values): rows = discover(values)
            case .pushFront(let value): rows.insert(contentsOf: discover([value]), at: 0)
            case .pushBack(let value): rows.append(contentsOf: discover([value]))
            case .insert(let index, let value):
                guard (0...rows.count).contains(index) else { continue }
                rows.insert(contentsOf: discover([value]), at: index)
            case .set(let index, let value):
                guard rows.indices.contains(index) else { continue }
                rows[index] = discover([value])[0]
            case .remove(let index): if rows.indices.contains(index) { rows.remove(at: index) }
            case .truncate(let count): if count < rows.count { rows.removeLast(rows.count - max(0, count)) }
            case .clear: rows.removeAll()
            case .popFront: if !rows.isEmpty { rows.removeFirst() }
            case .popBack: if !rows.isEmpty { rows.removeLast() }
            }
        }
        let pending = rows.compactMap { $0 }
        state.generation += 1
        state.rowCount = rows.count
        state.pendingCount = pending.count
        state.pendingSessionIDs = Set(pending.compactMap(\.sessionId)).sorted()
        do { try flush(); publish() } catch { publish(error: error) }
    }

    /// All acknowledgments use this queue-to-main path, including explicit
    /// retries, so an older callback cannot replace a newer write result.
    private func publish(error: Error? = nil, completion: (() -> Void)? = nil) {
        var snapshot = state
        snapshot.error = error?.localizedDescription
        let published = snapshot
        let callback = onChange
        DispatchQueue.main.async {
            callback?(published)
            completion?()
        }
    }

    private func map(_ diff: TimelineDiff) -> RoomPollHistoryDiff {
        switch diff {
        case .append(let values): return .append(values.map(row))
        case .reset(let values): return .reset(values.map(row))
        case .pushFront(let value): return .pushFront(row(value))
        case .pushBack(let value): return .pushBack(row(value))
        case .insert(let index, let value): return .insert(Int(index), row(value))
        case .set(let index, let value): return .set(Int(index), row(value))
        case .remove(let index): return .remove(Int(index))
        case .truncate(let count): return .truncate(Int(count))
        case .clear: return .clear
        case .popFront: return .popFront
        case .popBack: return .popBack
        }
    }

    private func row(_ item: TimelineItem) -> RoomPollHistoryRow {
        guard let event = item.asEvent(), case .eventId(let id) = event.eventOrTransactionId,
              case .msgLike(let message) = event.content else { return RoomPollHistoryRow() }
        let content: ChatMessageContent
        let isPollStart: Bool
        switch message.kind {
        case .poll(let question, let kind, let maxSelections, let answers, let votes, let endTime, let edited):
            var snapshot = PollSnapshot.fromSDK(question: question, kind: kind, maxSelections: maxSelections,
                answers: answers, votes: votes, endTime: endTime, isEditable: event.isEditable,
                isEdited: edited, currentUserID: userID)
            if edited, let json = event.lazyProvider.debugInfo().latestEditJson,
               let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                snapshot.latestEditEventID = raw["event_id"] as? String
            }
            content = .poll(snapshot)
            isPollStart = true
        case .redacted:
            content = .redacted
            isPollStart = PollStore.isPollStartEvent(originalJSON: event.lazyProvider.debugInfo().originalJson)
        default:
            return RoomPollHistoryRow(pending: PendingDecryption.make(from: event, uniqueId: item.uniqueId().id))
        }
        let senderName: String?
        let senderProfile: PollSenderProfile
        if case .ready(let name, _, _) = event.senderProfile {
            senderName = name
            senderProfile = .ready(name: name)
        } else {
            senderName = nil
            senderProfile = .unavailable
        }
        let chatMessage = ChatMessage(id: id, eventId: id, transactionId: nil, itemIdentifier: .eventId(id),
            senderId: event.sender, senderDisplayName: senderName, senderAvatarUrl: nil, isOutgoing: event.isOwn,
            timestamp: Date(timeIntervalSince1970: Double(event.timestamp) / 1000), content: content,
            reactions: [], replyInfo: nil, isEditable: false, isEdited: false, isEditPending: false,
            isEditFailed: false, latestEditEventId: nil, zynaAttributes: ZynaMessageAttributes(), sendStatus: "synced")
        return RoomPollHistoryRow(record: StoredMessage(from: chatMessage, roomId: catalog.roomId),
                                  isPollStart: isPollStart, senderProfile: senderProfile)
    }
}
