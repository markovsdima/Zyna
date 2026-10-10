//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

struct StoredMatrixRTCCall: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "storedMatrixRTCCall"

    var notificationEventId: String
    var roomId: String
    var parentEventId: String?
    var senderId: String
    var senderDisplayName: String?
    var isOutgoing: Bool
    var timestamp: TimeInterval
    var notificationType: String
    var callIntent: String?
    var expiresAt: TimeInterval?
    var declinedByJSON: String
    var isDirect: Bool
    var hasOwnJoin: Bool
    var hasRemoteJoin: Bool
    var hasOwnLeave: Bool
    var hasRemoteLeave: Bool
    var lastMembershipEventTimestamp: TimeInterval?
    var lastOwnLeaveTimestamp: TimeInterval?
    var lastRemoteLeaveTimestamp: TimeInterval?
    var outcome: String
    var updatedAt: TimeInterval

    init(
        notificationEventId: String,
        roomId: String,
        parentEventId: String?,
        senderId: String,
        senderDisplayName: String?,
        isOutgoing: Bool,
        timestamp: TimeInterval,
        notificationType: String,
        callIntent: String?,
        expiresAt: TimeInterval?,
        declinedByJSON: String,
        isDirect: Bool,
        hasOwnJoin: Bool,
        hasRemoteJoin: Bool,
        hasOwnLeave: Bool,
        hasRemoteLeave: Bool,
        lastMembershipEventTimestamp: TimeInterval?,
        lastOwnLeaveTimestamp: TimeInterval?,
        lastRemoteLeaveTimestamp: TimeInterval?,
        outcome: String,
        updatedAt: TimeInterval
    ) {
        self.notificationEventId = notificationEventId
        self.roomId = roomId
        self.parentEventId = parentEventId
        self.senderId = senderId
        self.senderDisplayName = senderDisplayName
        self.isOutgoing = isOutgoing
        self.timestamp = timestamp
        self.notificationType = notificationType
        self.callIntent = callIntent
        self.expiresAt = expiresAt
        self.declinedByJSON = declinedByJSON
        self.isDirect = isDirect
        self.hasOwnJoin = hasOwnJoin
        self.hasRemoteJoin = hasRemoteJoin
        self.hasOwnLeave = hasOwnLeave
        self.hasRemoteLeave = hasRemoteLeave
        self.lastMembershipEventTimestamp = lastMembershipEventTimestamp
        self.lastOwnLeaveTimestamp = lastOwnLeaveTimestamp
        self.lastRemoteLeaveTimestamp = lastRemoteLeaveTimestamp
        self.outcome = outcome
        self.updatedAt = updatedAt
    }

    init?(from message: ChatMessage, roomId: String) {
        guard case .matrixRTCCall(let details) = message.content,
              let eventId = message.eventId,
              !eventId.isEmpty else {
            return nil
        }

        self.init(
            notificationEventId: eventId,
            roomId: roomId,
            parentEventId: details.parentEventId,
            senderId: message.senderId,
            senderDisplayName: message.senderDisplayName,
            isOutgoing: message.isOutgoing,
            timestamp: message.timestamp.timeIntervalSince1970,
            notificationType: details.notificationType.rawValue,
            callIntent: details.callIntent,
            expiresAt: details.expiresAt,
            declinedByJSON: Self.encodeDeclinedBy(details.declinedBy),
            isDirect: false,
            hasOwnJoin: false,
            hasRemoteJoin: false,
            hasOwnLeave: false,
            hasRemoteLeave: false,
            lastMembershipEventTimestamp: nil,
            lastOwnLeaveTimestamp: nil,
            lastRemoteLeaveTimestamp: nil,
            outcome: (details.historyOutcome ?? .started).rawValue,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    var declinedBy: [String] {
        Self.decodeDeclinedBy(declinedByJSON)
    }

    var isVoiceCall: Bool {
        switch callIntent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "audio", "m.audio":
            return true
        default:
            return false
        }
    }

    var historyOutcome: MatrixRTCCallHistoryOutcome {
        MatrixRTCCallHistoryOutcome(rawValue: outcome) ?? .started
    }

    @discardableResult
    mutating func refreshProjection(
        isDirect: Bool,
        currentUserId: String,
        memberships: [StoredMatrixRTCCallMembership],
        now: Date = Date()
    ) -> Bool {
        let evidence = Self.membershipEvidence(
            for: self,
            in: memberships,
            currentUserId: currentUserId
        )
        let projectedOutcome = Self.projectedOutcome(
            isDirect: isDirect,
            isOutgoing: isOutgoing,
            notificationType: notificationType,
            expiresAt: expiresAt,
            declinedBy: declinedBy,
            hasOwnJoin: evidence.hasOwnJoin,
            hasRemoteJoin: evidence.hasRemoteJoin,
            hasOwnLeave: evidence.hasOwnLeave,
            hasRemoteLeave: evidence.hasRemoteLeave,
            currentUserId: currentUserId,
            now: now
        )
        let changed = self.isDirect != isDirect
            || self.hasOwnJoin != evidence.hasOwnJoin
            || self.hasRemoteJoin != evidence.hasRemoteJoin
            || self.hasOwnLeave != evidence.hasOwnLeave
            || self.hasRemoteLeave != evidence.hasRemoteLeave
            || self.lastMembershipEventTimestamp != evidence.lastMembershipEventTimestamp
            || self.lastOwnLeaveTimestamp != evidence.lastOwnLeaveTimestamp
            || self.lastRemoteLeaveTimestamp != evidence.lastRemoteLeaveTimestamp
            || self.outcome != projectedOutcome.rawValue

        self.isDirect = isDirect
        self.hasOwnJoin = evidence.hasOwnJoin
        self.hasRemoteJoin = evidence.hasRemoteJoin
        self.hasOwnLeave = evidence.hasOwnLeave
        self.hasRemoteLeave = evidence.hasRemoteLeave
        self.lastMembershipEventTimestamp = evidence.lastMembershipEventTimestamp
        self.lastOwnLeaveTimestamp = evidence.lastOwnLeaveTimestamp
        self.lastRemoteLeaveTimestamp = evidence.lastRemoteLeaveTimestamp
        self.outcome = projectedOutcome.rawValue
        if changed {
            self.updatedAt = now.timeIntervalSince1970
        }
        return changed
    }

    func outcome(
        isDirect: Bool,
        currentUserId: String,
        memberships: [StoredMatrixRTCCallMembership],
        now: Date = Date()
    ) -> MatrixRTCCallHistoryOutcome {
        let evidence = Self.membershipEvidence(
            for: self,
            in: memberships,
            currentUserId: currentUserId
        )
        return Self.projectedOutcome(
            isDirect: isDirect,
            isOutgoing: isOutgoing,
            notificationType: notificationType,
            expiresAt: expiresAt,
            declinedBy: declinedBy,
            hasOwnJoin: evidence.hasOwnJoin,
            hasRemoteJoin: evidence.hasRemoteJoin,
            hasOwnLeave: evidence.hasOwnLeave,
            hasRemoteLeave: evidence.hasRemoteLeave,
            currentUserId: currentUserId,
            now: now
        )
    }

    private static func projectedOutcome(
        isDirect: Bool,
        isOutgoing: Bool,
        notificationType: String,
        expiresAt: TimeInterval?,
        declinedBy: [String],
        hasOwnJoin: Bool,
        hasRemoteJoin: Bool,
        hasOwnLeave: Bool,
        hasRemoteLeave: Bool,
        currentUserId: String,
        now: Date
    ) -> MatrixRTCCallHistoryOutcome {
        guard !currentUserId.isEmpty else {
            return .started
        }

        if isDirect {
            if declinedBy.contains(currentUserId) {
                return .declinedByMe
            }
            if !declinedBy.isEmpty {
                return .declined
            }
            if isOutgoing, hasRemoteJoin {
                return .answered
            }
            if !isOutgoing, hasOwnJoin {
                return .answered
            }
            if notificationType == MatrixRTCCallNotificationKind.ring.rawValue {
                if isOutgoing, hasOwnLeave, !hasRemoteJoin {
                    return .cancelledByMe
                }
                if !isOutgoing, hasRemoteLeave, !hasOwnJoin {
                    return .missed
                }
            }
        }

        guard isDirect,
              notificationType == MatrixRTCCallNotificationKind.ring.rawValue,
              let expiresAt,
              expiresAt <= now.timeIntervalSince1970 else {
            return .started
        }

        if isOutgoing {
            return hasRemoteJoin ? .started : .unanswered
        } else {
            return hasOwnJoin ? .started : .missed
        }
    }

    private struct MembershipEvidence {
        var hasOwnJoin = false
        var hasRemoteJoin = false
        var hasOwnLeave = false
        var hasRemoteLeave = false
        var lastMembershipEventTimestamp: TimeInterval?
        var lastOwnLeaveTimestamp: TimeInterval?
        var lastRemoteLeaveTimestamp: TimeInterval?
    }

    private static func membershipEvidence(
        for call: StoredMatrixRTCCall,
        in memberships: [StoredMatrixRTCCallMembership],
        currentUserId: String
    ) -> MembershipEvidence {
        let matchingMemberships = matchingMemberships(for: call, in: memberships)
        let matchingJoinStateKeys = Set(
            matchingMemberships
                .filter { !$0.isLeave }
                .compactMap(\.stateKey)
        )

        return matchingMemberships
            .reduce(into: MembershipEvidence()) { evidence, membership in
                if membership.isLeave {
                    guard let stateKey = membership.stateKey,
                          matchingJoinStateKeys.contains(stateKey) else {
                        return
                    }
                }

                evidence.lastMembershipEventTimestamp = max(
                    evidence.lastMembershipEventTimestamp ?? membership.timestamp,
                    membership.timestamp
                )

                if membership.senderId == currentUserId {
                    if membership.isLeave {
                        evidence.hasOwnLeave = true
                        evidence.lastOwnLeaveTimestamp = max(
                            evidence.lastOwnLeaveTimestamp ?? membership.timestamp,
                            membership.timestamp
                        )
                    } else {
                        evidence.hasOwnJoin = true
                    }
                } else {
                    if membership.isLeave {
                        evidence.hasRemoteLeave = true
                        evidence.lastRemoteLeaveTimestamp = max(
                            evidence.lastRemoteLeaveTimestamp ?? membership.timestamp,
                            membership.timestamp
                        )
                    } else {
                        evidence.hasRemoteJoin = true
                    }
                }
            }
    }

    private static func matchingMemberships(
        for call: StoredMatrixRTCCall,
        in memberships: [StoredMatrixRTCCallMembership]
    ) -> [StoredMatrixRTCCallMembership] {
        let lowerBound = call.timestamp - 5
        let upperBound = (call.expiresAt ?? (call.timestamp + 4 * 60 * 60)) + 10

        return memberships.filter { membership in
            guard membership.roomId == call.roomId,
                  membership.timestamp >= lowerBound,
                  membership.timestamp <= upperBound else {
                return false
            }
            if let parentEventId = call.parentEventId,
               membership.eventId == parentEventId {
                return true
            }
            return membership.callIntent == nil
                || call.callIntent == nil
                || membership.callIntent == call.callIntent
        }
    }

    private static func encodeDeclinedBy(_ userIds: [String]) -> String {
        guard let data = try? JSONEncoder().encode(userIds.sorted()),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeDeclinedBy(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let userIds = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return userIds
    }
}

extension StoredMatrixRTCCall {

    static func upsertAndRefreshProjection(
        _ call: StoredMatrixRTCCall,
        currentUserId: String,
        in db: Database,
        now: Date = Date()
    ) throws {
        var projected = call
        guard !currentUserId.isEmpty else {
            if let existing = try StoredMatrixRTCCall.fetchOne(db, key: call.notificationEventId) {
                projected.isDirect = existing.isDirect
                projected.hasOwnJoin = existing.hasOwnJoin
                projected.hasRemoteJoin = existing.hasRemoteJoin
                projected.hasOwnLeave = existing.hasOwnLeave
                projected.hasRemoteLeave = existing.hasRemoteLeave
                projected.lastMembershipEventTimestamp = existing.lastMembershipEventTimestamp
                projected.lastOwnLeaveTimestamp = existing.lastOwnLeaveTimestamp
                projected.lastRemoteLeaveTimestamp = existing.lastRemoteLeaveTimestamp
                projected.outcome = existing.outcome
                projected.updatedAt = existing.updatedAt
            }
            try projected.save(db)
            try syncStoredMessageProjection(for: projected, in: db)
            return
        }
        _ = try refreshProjection(&projected, currentUserId: currentUserId, in: db, now: now)
        try projected.save(db)
        try syncStoredMessageProjection(for: projected, in: db)
    }

    static func upsertMembershipAndRefreshCallProjections(
        _ membership: StoredMatrixRTCCallMembership,
        currentUserId: String,
        in db: Database,
        now: Date = Date()
    ) throws {
        try membership.save(db)
        guard !currentUserId.isEmpty else { return }

        let calls = try potentiallyAffectedCalls(
            by: membership,
            in: db
        )
        for var call in calls {
            if try refreshProjection(&call, currentUserId: currentUserId, in: db, now: now) {
                try call.save(db)
                try syncStoredMessageProjection(for: call, in: db)
            }
        }
    }

    static func refreshRecentCallProjections(
        limit: Int,
        currentUserId: String,
        in db: Database,
        now: Date = Date()
    ) throws {
        guard !currentUserId.isEmpty else { return }

        let calls = try StoredMatrixRTCCall
            .order(Column("timestamp").desc)
            .limit(limit)
            .fetchAll(db)
        for var call in calls {
            if try refreshProjection(&call, currentUserId: currentUserId, in: db, now: now) {
                try call.save(db)
                try syncStoredMessageProjection(for: call, in: db)
            }
        }
    }

    static func refreshRoomCallProjections(
        roomId: String,
        currentUserId: String,
        in db: Database,
        now: Date = Date()
    ) throws {
        guard !currentUserId.isEmpty else { return }

        let calls = try StoredMatrixRTCCall
            .filter(Column("roomId") == roomId)
            .fetchAll(db)
        let isDirect = isDirectRoom(roomId: roomId, in: db)
        let memberships = try membershipsForProjection(
            calls: calls,
            roomId: roomId,
            in: db
        )
        for var call in calls {
            if call.refreshProjection(
                isDirect: isDirect,
                currentUserId: currentUserId,
                memberships: memberships,
                now: now
            ) {
                try call.save(db)
                try syncStoredMessageProjection(for: call, in: db)
            }
        }
    }

    static func refreshExpiredPendingCallProjections(
        roomId: String? = nil,
        currentUserId: String,
        in db: Database,
        now: Date = Date()
    ) throws {
        guard !currentUserId.isEmpty else { return }

        var request = StoredMatrixRTCCall
            .filter(Column("notificationType") == MatrixRTCCallNotificationKind.ring.rawValue)
            .filter(Column("outcome") == MatrixRTCCallHistoryOutcome.started.rawValue)
            .filter(Column("expiresAt") != nil)
            .filter(Column("expiresAt") <= now.timeIntervalSince1970)
        if let roomId {
            request = request.filter(Column("roomId") == roomId)
        }

        let calls = try request.fetchAll(db)
        for var call in calls {
            if try refreshProjection(&call, currentUserId: currentUserId, in: db, now: now) {
                try call.save(db)
                try syncStoredMessageProjection(for: call, in: db)
            }
        }
    }

    static func deleteMembershipAndRefreshCallProjections(
        eventId: String,
        currentUserId: String,
        in db: Database,
        now: Date = Date()
    ) throws {
        guard let membership = try StoredMatrixRTCCallMembership.fetchOne(db, key: eventId) else {
            return
        }
        let calls = try potentiallyAffectedCalls(by: membership, in: db)
        _ = try StoredMatrixRTCCallMembership.deleteOne(db, key: eventId)
        guard !currentUserId.isEmpty else { return }

        for var call in calls {
            if try refreshProjection(&call, currentUserId: currentUserId, in: db, now: now) {
                try call.save(db)
                try syncStoredMessageProjection(for: call, in: db)
            }
        }
    }

    private static func refreshProjection(
        _ call: inout StoredMatrixRTCCall,
        currentUserId: String,
        in db: Database,
        now: Date
    ) throws -> Bool {
        let memberships = try membershipsForProjection(call: call, in: db)
        return call.refreshProjection(
            isDirect: isDirectRoom(roomId: call.roomId, in: db),
            currentUserId: currentUserId,
            memberships: memberships,
            now: now
        )
    }

    private static func membershipsForProjection(
        call: StoredMatrixRTCCall,
        in db: Database
    ) throws -> [StoredMatrixRTCCallMembership] {
        let lowerBound = call.timestamp - 5
        let upperBound = (call.expiresAt ?? (call.timestamp + 4 * 60 * 60)) + 10
        return try StoredMatrixRTCCallMembership
            .filter(Column("roomId") == call.roomId)
            .filter(Column("timestamp") >= lowerBound && Column("timestamp") <= upperBound)
            .fetchAll(db)
    }

    private static func membershipsForProjection(
        calls: [StoredMatrixRTCCall],
        roomId: String,
        in db: Database
    ) throws -> [StoredMatrixRTCCallMembership] {
        guard !calls.isEmpty else { return [] }
        let lowerBound = calls
            .map { $0.timestamp - 5 }
            .min() ?? 0
        let upperBound = calls
            .map { ($0.expiresAt ?? ($0.timestamp + 4 * 60 * 60)) + 10 }
            .max() ?? 0
        return try StoredMatrixRTCCallMembership
            .filter(Column("roomId") == roomId)
            .filter(Column("timestamp") >= lowerBound && Column("timestamp") <= upperBound)
            .fetchAll(db)
    }

    private static func potentiallyAffectedCalls(
        by membership: StoredMatrixRTCCallMembership,
        in db: Database
    ) throws -> [StoredMatrixRTCCall] {
        let lowerBound = membership.timestamp - 4 * 60 * 60 - 10
        let upperBound = membership.timestamp + 5
        return try StoredMatrixRTCCall
            .filter(Column("roomId") == membership.roomId)
            .filter(Column("timestamp") >= lowerBound && Column("timestamp") <= upperBound)
            .fetchAll(db)
    }

    private static func isDirectRoom(roomId: String, in db: Database) -> Bool {
        guard let room = try? StoredRoom.fetchOne(db, key: roomId),
              let directUserId = room.directUserId else {
            return false
        }
        return !directUserId.isEmpty
    }

    private static func syncStoredMessageProjection(
        for call: StoredMatrixRTCCall,
        in db: Database
    ) throws {
        guard var message = try StoredMessage
            .filter(Column("roomId") == call.roomId)
            .filter(Column("eventId") == call.notificationEventId)
            .filter(Column("contentType") == "matrix_rtc_call")
            .fetchOne(db),
              let details = StoredMessage.decodeMatrixRTCCallDetails(
                message.contentMediaJSON,
                parentEventId: message.contentBody,
                callIntent: message.contentCaption,
                notificationType: message.contentMimetype
              ) else {
            return
        }

        message.contentMediaJSON = StoredMessage.encodeMatrixRTCCallDetails(
            details.withHistoryOutcome(call.historyOutcome)
        )
        try message.save(db)
    }
}

enum MatrixRTCCallHistoryOutcome: String, Codable, Equatable {
    case started
    case answered
    case declined
    case declinedByMe
    case cancelledByMe
    case missed
    case unanswered

    var displayText: String {
        switch self {
        case .started:
            return String(localized: "Call started")
        case .answered:
            return String(localized: "Call connected")
        case .declined:
            return String(localized: "Call declined")
        case .declinedByMe:
            return String(localized: "You declined a call")
        case .cancelledByMe:
            return String(localized: "You cancelled a call")
        case .missed:
            return String(localized: "Missed call")
        case .unanswered:
            return String(localized: "No answer")
        }
    }

    var isNegative: Bool {
        switch self {
        case .declined, .declinedByMe, .cancelledByMe, .missed, .unanswered:
            return true
        case .started, .answered:
            return false
        }
    }
}
