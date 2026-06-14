//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRTC
import MatrixRustSDK

private let logNativeCallReactions = ScopedLog(.call, prefix: "[matrixrtc-native-reactions]")

struct NativeMatrixRTCCallRaisedHandState: Equatable, Sendable {
    static let lowered = Self(reactionEventId: nil, membershipEventId: nil, raisedAt: nil)

    let reactionEventId: String?
    let membershipEventId: String?
    let raisedAt: Date?

    var isRaised: Bool {
        reactionEventId != nil && membershipEventId != nil && raisedAt != nil
    }
}

struct NativeMatrixRTCCallRaisedHandsSnapshot: Equatable, Sendable {
    static let empty = Self(localHand: .lowered, handsByParticipantId: [:])

    let localHand: NativeMatrixRTCCallRaisedHandState
    let handsByParticipantId: [String: NativeMatrixRTCCallRaisedHandState]
}

enum NativeMatrixRTCCallReactionTimelineEvent: Equatable, Sendable {
    case raisedHand(
        reactionEventId: String,
        membershipEventId: String,
        sender: String,
        timestamp: Date
    )
    case redaction(redactedEventId: String)
}

struct NativeMatrixRTCCallRaisedHandStore: Equatable, Sendable {
    private(set) var ownMembership: MatrixRTCCallMembership?
    private(set) var snapshot: NativeMatrixRTCCallRaisedHandsSnapshot = .empty

    private var membershipsByEventId: [String: MatrixRTCCallMembership] = [:]
    private var eventsByReactionEventId: [String: NativeMatrixRTCCallRaisedHandEvent] = [:]
    private var redactedReactionEventIds = Set<String>()

    mutating func reset() -> NativeMatrixRTCCallRaisedHandsSnapshot {
        ownMembership = nil
        membershipsByEventId = [:]
        eventsByReactionEventId = [:]
        redactedReactionEventIds = []
        snapshot = .empty
        return snapshot
    }

    mutating func updateMemberships(
        ownMembership: MatrixRTCCallMembership,
        memberships: [MatrixRTCCallMembership]
    ) -> NativeMatrixRTCCallRaisedHandsSnapshot? {
        let activeMemberships = memberships.contains(where: { $0.identity == ownMembership.identity })
            ? memberships
            : memberships + [ownMembership]
        let nextMemberships = Dictionary(
            activeMemberships.map { ($0.eventId, $0) },
            uniquingKeysWith: { lhs, _ in lhs }
        )

        guard self.ownMembership != ownMembership || membershipsByEventId != nextMemberships else {
            return nil
        }

        self.ownMembership = ownMembership
        membershipsByEventId = nextMemberships
        return rebuildSnapshotIfChanged()
    }

    mutating func apply(
        _ event: NativeMatrixRTCCallReactionTimelineEvent
    ) -> NativeMatrixRTCCallRaisedHandsSnapshot? {
        switch event {
        case .raisedHand(let reactionEventId, let membershipEventId, let sender, let timestamp):
            guard !redactedReactionEventIds.contains(reactionEventId) else {
                logNativeCallReactions(
                    "Ignored raised hand reaction event=\(reactionEventId) membership=\(membershipEventId) sender=\(sender) reason=already_redacted"
                )
                return nil
            }

            if let membership = membershipsByEventId[membershipEventId],
               membership.userId != sender {
                logNativeCallReactions(
                    "Ignored raised hand reaction event=\(reactionEventId) membership=\(membershipEventId) sender=\(sender) reason=sender_mismatch membershipUser=\(membership.userId)"
                )
                return nil
            }

            if membershipsByEventId[membershipEventId] == nil {
                logNativeCallReactions(
                    "Buffered raised hand reaction event=\(reactionEventId) membership=\(membershipEventId) sender=\(sender) reason=missing_membership knownMemberships=\(membershipsByEventId.keys.sorted().joined(separator: ","))"
                )
            } else {
                logNativeCallReactions(
                    "Accepted raised hand reaction event=\(reactionEventId) membership=\(membershipEventId) sender=\(sender)"
                )
            }
            eventsByReactionEventId[reactionEventId] = NativeMatrixRTCCallRaisedHandEvent(
                reactionEventId: reactionEventId,
                membershipEventId: membershipEventId,
                sender: sender,
                raisedAt: timestamp
            )

        case .redaction(let redactedEventId):
            redactedReactionEventIds.insert(redactedEventId)
            guard eventsByReactionEventId.removeValue(forKey: redactedEventId) != nil else {
                logNativeCallReactions(
                    "Ignored raised hand redaction redactedEvent=\(redactedEventId) reason=unknown_reaction knownReactions=\(eventsByReactionEventId.keys.sorted().joined(separator: ","))"
                )
                return nil
            }
            logNativeCallReactions("Accepted raised hand redaction redactedEvent=\(redactedEventId)")
        }

        return rebuildSnapshotIfChanged()
    }

    mutating func applyOwnRaisedHand(
        reactionEventId: String,
        membershipEventId: String,
        raisedAt: Date
    ) -> NativeMatrixRTCCallRaisedHandsSnapshot? {
        guard let ownMembership,
              ownMembership.eventId == membershipEventId else {
            return nil
        }

        eventsByReactionEventId[reactionEventId] = NativeMatrixRTCCallRaisedHandEvent(
            reactionEventId: reactionEventId,
            membershipEventId: membershipEventId,
            sender: ownMembership.userId,
            raisedAt: raisedAt
        )
        return rebuildSnapshotIfChanged()
    }

    mutating func applyOwnLoweredHand(
        reactionEventId: String,
        membershipEventId: String
    ) -> NativeMatrixRTCCallRaisedHandsSnapshot? {
        guard let existing = eventsByReactionEventId[reactionEventId],
              existing.membershipEventId == membershipEventId else {
            return nil
        }

        eventsByReactionEventId.removeValue(forKey: reactionEventId)
        return rebuildSnapshotIfChanged()
    }

    private mutating func rebuildSnapshotIfChanged() -> NativeMatrixRTCCallRaisedHandsSnapshot? {
        var nextHandsByParticipantId: [String: NativeMatrixRTCCallRaisedHandState] = [:]

        for event in eventsByReactionEventId.values {
            guard let membership = membershipsByEventId[event.membershipEventId],
                  membership.userId == event.sender else {
                continue
            }

            let participantId = membership.rtcBackendIdentity
            let nextHand = NativeMatrixRTCCallRaisedHandState(
                reactionEventId: event.reactionEventId,
                membershipEventId: event.membershipEventId,
                raisedAt: event.raisedAt
            )

            if let existing = nextHandsByParticipantId[participantId],
               let existingRaisedAt = existing.raisedAt,
               existingRaisedAt >= event.raisedAt {
                continue
            }

            nextHandsByParticipantId[participantId] = nextHand
        }

        let localHand = ownMembership
            .flatMap { nextHandsByParticipantId[$0.rtcBackendIdentity] }
            ?? .lowered
        let nextSnapshot = NativeMatrixRTCCallRaisedHandsSnapshot(
            localHand: localHand,
            handsByParticipantId: nextHandsByParticipantId
        )

        guard nextSnapshot != snapshot else { return nil }
        snapshot = nextSnapshot
        return nextSnapshot
    }
}

enum NativeMatrixRTCCallReactionEventParser {
    static let raisedHandKey = "🖐️"

    static func parse(_ event: RawRoomEvent) -> NativeMatrixRTCCallReactionTimelineEvent? {
        parse(rawEvent: rawEvent(from: event))
    }

    static func parse(rawJSON: String) -> NativeMatrixRTCCallReactionTimelineEvent? {
        guard let data = rawJSON.data(using: .utf8),
              let rawEvent = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parse(rawEvent: rawEvent)
    }

    static func parse(rawEvent: [String: Any]) -> NativeMatrixRTCCallReactionTimelineEvent? {
        guard let eventType = rawEvent["type"] as? String else { return nil }

        switch eventType {
        case "m.reaction":
            return parseRaisedHand(rawEvent: rawEvent)
        case "m.room.redaction":
            return parseRedaction(rawEvent: rawEvent)
        default:
            return nil
        }
    }

    static func diagnosticSummary(_ event: RawRoomEvent) -> String? {
        diagnosticSummary(rawEvent(from: event))
    }

    private static func rawEvent(from event: RawRoomEvent) -> [String: Any] {
        var rawEvent: [String: Any] = [:]
        if let data = event.rawJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rawEvent = parsed
        }

        rawEvent["type"] = event.eventType
        rawEvent["content"] = jsonObject(from: event.contentJson) ?? [:]
        if let eventId = event.eventId {
            rawEvent["event_id"] = eventId
        }
        if let sender = event.sender {
            rawEvent["sender"] = sender
        }
        if let originServerTsMs = event.originServerTsMs {
            rawEvent["origin_server_ts"] = NSNumber(value: originServerTsMs)
        }
        return rawEvent
    }

    private static func jsonObject(from rawJSON: String) -> [String: Any]? {
        guard let data = rawJSON.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func diagnosticSummary(_ rawEvent: [String: Any]) -> String? {
        guard let eventType = rawEvent["type"] as? String,
              [
                "m.reaction",
                "m.room.redaction",
                "io.element.call.reaction"
              ].contains(eventType) else {
            return nil
        }

        let eventId = rawEvent["event_id"] as? String ?? "nil"
        let sender = rawEvent["sender"] as? String ?? "nil"
        let content = rawEvent["content"] as? [String: Any]
        let relation = content?["m.relates_to"] as? [String: Any]
        let relationType = relation?["rel_type"] as? String ?? "nil"
        let relatedEventId = relation?["event_id"] as? String ?? "nil"

        switch eventType {
        case "m.reaction":
            let key = relation?["key"] as? String ?? "nil"
            return "raw type=m.reaction event=\(eventId) sender=\(sender) relType=\(relationType) relatesTo=\(relatedEventId) key=\(key)"
        case "m.room.redaction":
            let redactedEventId = rawEvent["redacts"] as? String
                ?? content?["redacts"] as? String
                ?? "nil"
            return "raw type=m.room.redaction event=\(eventId) sender=\(sender) redacts=\(redactedEventId)"
        case "io.element.call.reaction":
            let emoji = content?["emoji"] as? String ?? "nil"
            let name = content?["name"] as? String ?? "nil"
            return "raw type=io.element.call.reaction event=\(eventId) sender=\(sender) relType=\(relationType) relatesTo=\(relatedEventId) emoji=\(emoji) name=\(name)"
        default:
            return nil
        }
    }

    private static func parseRaisedHand(
        rawEvent: [String: Any]
    ) -> NativeMatrixRTCCallReactionTimelineEvent? {
        guard let reactionEventId = rawEvent["event_id"] as? String,
              let sender = rawEvent["sender"] as? String,
              let content = rawEvent["content"] as? [String: Any],
              let relation = content["m.relates_to"] as? [String: Any],
              let relationType = relation["rel_type"] as? String,
              relationType == "m.annotation",
              let membershipEventId = relation["event_id"] as? String,
              let key = relation["key"] as? String,
              key == raisedHandKey else {
            return nil
        }

        return .raisedHand(
            reactionEventId: reactionEventId,
            membershipEventId: membershipEventId,
            sender: sender,
            timestamp: timestamp(from: rawEvent)
        )
    }

    private static func parseRedaction(
        rawEvent: [String: Any]
    ) -> NativeMatrixRTCCallReactionTimelineEvent? {
        let content = rawEvent["content"] as? [String: Any]
        guard let redactedEventId = rawEvent["redacts"] as? String
                ?? content?["redacts"] as? String else {
            return nil
        }
        return .redaction(redactedEventId: redactedEventId)
    }

    private static func timestamp(from rawEvent: [String: Any]) -> Date {
        if let timestamp = rawEvent["origin_server_ts"] as? TimeInterval {
            return Date(timeIntervalSince1970: timestamp / 1_000)
        }
        if let timestamp = rawEvent["origin_server_ts"] as? NSNumber {
            return Date(timeIntervalSince1970: timestamp.doubleValue / 1_000)
        }
        return Date()
    }
}

enum NativeMatrixRTCCallRaisedHandSender {
    static func raiseHand(
        room: Room,
        membershipEventId: String
    ) async throws -> String {
        let transactionId = "matrixrtc-raise-hand-\(UUID().uuidString)"
        let content: [String: Any] = [
            "m.relates_to": [
                "rel_type": "m.annotation",
                "event_id": membershipEventId,
                "key": NativeMatrixRTCCallReactionEventParser.raisedHandKey
            ],
            DirectRawTextSender.transactionIdContentKey: transactionId
        ]
        let data = try JSONSerialization.data(
            withJSONObject: content,
            options: [.sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw NativeMatrixRTCCallRaisedHandSenderError.invalidUTF8
        }

        logNativeCallReactions(
            "Sending raised hand reaction room=\(room.id()) membership=\(membershipEventId) tx=\(transactionId)"
        )
        let eventId = try await room.sendRawWithTransactionIdReturningEventId(
            eventType: "m.reaction",
            content: json,
            transactionId: transactionId
        )
        logNativeCallReactions(
            "Sent raised hand reaction room=\(room.id()) membership=\(membershipEventId) event=\(eventId) tx=\(transactionId)"
        )
        return eventId
    }

    static func lowerHand(
        room: Room,
        reactionEventId: String
    ) async throws -> String {
        let transactionId = "matrixrtc-lower-hand-\(UUID().uuidString)"
        logNativeCallReactions(
            "Sending raised hand redaction room=\(room.id()) reactionEvent=\(reactionEventId) tx=\(transactionId)"
        )
        let eventId = try await room.redactWithTransactionIdReturningEventId(
            eventId: reactionEventId,
            reason: nil,
            transactionId: transactionId
        )
        logNativeCallReactions(
            "Sent raised hand redaction room=\(room.id()) reactionEvent=\(reactionEventId) redactionEvent=\(eventId) tx=\(transactionId)"
        )
        return eventId
    }
}

final class NativeMatrixRTCCallReactionWatcher: @unchecked Sendable {
    private static let observedEventTypes = ["m.reaction", "m.room.redaction"]
    private static let relationBackfillLimit: UInt64 = 100
    private static let relationBackfillPageLimit = 5

    private let room: Room
    private let onEvent: @Sendable (NativeMatrixRTCCallReactionTimelineEvent) -> Void
    private let lock = NSLock()

    private var rawEventHandle: TaskHandle?
    private var backfilledMembershipEventIds = Set<String>()
    private var isCancelled = false

    init(
        room: Room,
        onEvent: @escaping @Sendable (NativeMatrixRTCCallReactionTimelineEvent) -> Void
    ) {
        self.room = room
        self.onEvent = onEvent
    }

    func start() async {
        logNativeCallReactions("Starting reaction watcher room=\(room.id())")
        try? await MatrixClientService.shared.roomListService?.subscribeToRooms(roomIds: [room.id()])

        let listener = NativeMatrixRTCCallRawRoomEventListener { [onEvent] rawEvent in
            let event = NativeMatrixRTCCallReactionEventParser.parse(rawEvent)
            if let summary = NativeMatrixRTCCallReactionEventParser.diagnosticSummary(rawEvent) {
                logNativeCallReactions(
                    "RawTimeline \(summary) parsed=\(event?.zynaDiagnosticDescription ?? "nil")"
                )
            }
            guard let event else { return }
            onEvent(event)
        }
        let handle = room.subscribeToRawTimelineEvents(
            eventTypes: Self.observedEventTypes,
            listener: listener
        )

        let handleToCancel: TaskHandle? = withLock {
            guard !isCancelled else { return handle }
            rawEventHandle = handle
            return nil
        }
        handleToCancel?.cancel()
        if handleToCancel == nil {
            logNativeCallReactions(
                "Reaction watcher started room=\(room.id()) events=\(Self.observedEventTypes.joined(separator: ","))"
            )
        }
    }

    func cancel() {
        let handleToCancel: TaskHandle? = withLock {
            isCancelled = true
            let handle = rawEventHandle
            rawEventHandle = nil
            return handle
        }
        handleToCancel?.cancel()
    }

    func backfill(memberships: [MatrixRTCCallMembership]) {
        let membershipEventIds = Array(Set(memberships.map(\.eventId)))
        let idsToBackfill: [String] = withLock {
            guard !isCancelled else { return [] }
            let ids = membershipEventIds.filter { !backfilledMembershipEventIds.contains($0) }
            backfilledMembershipEventIds.formUnion(ids)
            return ids
        }

        guard !idsToBackfill.isEmpty else { return }
        Task { [weak self] in
            await self?.backfill(membershipEventIds: idsToBackfill)
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private func backfill(membershipEventIds: [String]) async {
        for membershipEventId in membershipEventIds {
            guard !Task.isCancelled, !isWatcherCancelled() else { return }

            do {
                logNativeCallReactions(
                    "Backfilling raised hand reactions room=\(room.id()) membership=\(membershipEventId)"
                )
                try await backfill(membershipEventId: membershipEventId)
            } catch {
                markBackfillFailed(membershipEventId: membershipEventId)
                guard !Task.isCancelled, !isWatcherCancelled() else { return }
                logNativeCallReactions(
                    "Failed backfilling raised hand reactions room=\(room.id()) membership=\(membershipEventId): \(error)"
                )
            }
        }
    }

    private func backfill(membershipEventId: String) async throws {
        var nextToken: String?

        for pageIndex in 0..<Self.relationBackfillPageLimit {
            let relations = try await room.getEventRelations(
                eventId: membershipEventId,
                options: RawRoomRelationsOptions(
                    relationType: "m.annotation",
                    eventType: "m.reaction",
                    from: nextToken,
                    limit: Self.relationBackfillLimit,
                    direction: .backward,
                    recurse: false
                )
            )

            guard !Task.isCancelled, !isWatcherCancelled() else { return }

            for rawEvent in relations.chunk {
                let event = NativeMatrixRTCCallReactionEventParser.parse(rawEvent)
                if let summary = NativeMatrixRTCCallReactionEventParser.diagnosticSummary(rawEvent) {
                    logNativeCallReactions(
                        "RelationsBackfill \(summary) parsed=\(event?.zynaDiagnosticDescription ?? "nil")"
                    )
                }
                guard let event else { continue }
                onEvent(event)
            }

            guard let token = relations.nextBatchToken,
                  !token.isEmpty,
                  !relations.chunk.isEmpty else {
                return
            }
            nextToken = token

            if pageIndex == Self.relationBackfillPageLimit - 1 {
                logNativeCallReactions(
                    "Stopped raised hand relation backfill after page limit room=\(room.id()) membership=\(membershipEventId)"
                )
            }
        }
    }

    private func isWatcherCancelled() -> Bool {
        withLock { isCancelled }
    }

    private func markBackfillFailed(membershipEventId: String) {
        withLock {
            _ = backfilledMembershipEventIds.remove(membershipEventId)
        }
    }
}

private final class NativeMatrixRTCCallRawRoomEventListener: RawRoomEventListener, @unchecked Sendable {
    private let handler: @Sendable (RawRoomEvent) -> Void

    init(handler: @escaping @Sendable (RawRoomEvent) -> Void) {
        self.handler = handler
    }

    func onEvent(event: RawRoomEvent) {
        handler(event)
    }
}

private struct NativeMatrixRTCCallRaisedHandEvent: Equatable, Sendable {
    let reactionEventId: String
    let membershipEventId: String
    let sender: String
    let raisedAt: Date
}

private extension NativeMatrixRTCCallReactionTimelineEvent {
    var zynaDiagnosticDescription: String {
        switch self {
        case .raisedHand(let reactionEventId, let membershipEventId, let sender, _):
            return "raisedHand event=\(reactionEventId) membership=\(membershipEventId) sender=\(sender)"
        case .redaction(let redactedEventId):
            return "redaction redacts=\(redactedEventId)"
        }
    }
}

private enum NativeMatrixRTCCallRaisedHandSenderError: Error {
    case invalidUTF8
}
