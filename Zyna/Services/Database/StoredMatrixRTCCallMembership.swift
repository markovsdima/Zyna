//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRTC
import MatrixRustSDK

struct StoredMatrixRTCCallMembership: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "storedMatrixRTCCallMembership"

    var eventId: String
    var roomId: String
    var eventType: String
    var stateKey: String?
    var senderId: String
    var timestamp: TimeInterval
    var isLeave: Bool
    var userId: String?
    var deviceId: String?
    var memberId: String?
    var callIntent: String?
    var expiresAt: TimeInterval?

    init(
        eventId: String,
        roomId: String,
        eventType: String,
        stateKey: String?,
        senderId: String,
        timestamp: TimeInterval,
        isLeave: Bool,
        userId: String?,
        deviceId: String?,
        memberId: String?,
        callIntent: String?,
        expiresAt: TimeInterval?
    ) {
        self.eventId = eventId
        self.roomId = roomId
        self.eventType = eventType
        self.stateKey = stateKey
        self.senderId = senderId
        self.timestamp = timestamp
        self.isLeave = isLeave
        self.userId = userId
        self.deviceId = deviceId
        self.memberId = memberId
        self.callIntent = callIntent
        self.expiresAt = expiresAt
    }

    static func parse(from event: EventTimelineItem, roomId: String) -> StoredMatrixRTCCallMembership? {
        guard case .state(stateKey: let stateKey, content: let state) = event.content,
              case .custom(eventType: let eventType) = state,
              isMatrixRTCMembershipEventType(eventType),
              let rawJSON = event.lazyProvider.debugInfo().originalJson,
              let raw = RawStateEventPayload(json: rawJSON) else {
            return nil
        }

        let timestamp = TimeInterval(event.timestamp) / 1000
        guard !raw.eventId.isEmpty else { return nil }
        let contentJSON = raw.contentJSON
        let isLeave = raw.contentIsEmptyObject

        guard !isLeave else {
            return StoredMatrixRTCCallMembership(
                eventId: raw.eventId,
                roomId: roomId,
                eventType: eventType,
                stateKey: stateKey,
                senderId: event.sender,
                timestamp: timestamp,
                isLeave: true,
                userId: event.sender,
                deviceId: nil,
                memberId: nil,
                callIntent: nil,
                expiresAt: nil
            )
        }

        let rawEvent = MatrixRTCRawMembershipEvent(
            eventId: raw.eventId,
            eventType: eventType,
            stateKey: stateKey,
            sender: event.sender,
            originServerTimestamp: Int64(event.timestamp),
            contentJSON: contentJSON
        )
        guard let membership = try? MatrixRTCCallMembershipParser.parse(event: rawEvent) else {
            return nil
        }

        return StoredMatrixRTCCallMembership(
            eventId: raw.eventId,
            roomId: roomId,
            eventType: eventType,
            stateKey: stateKey,
            senderId: event.sender,
            timestamp: timestamp,
            isLeave: false,
            userId: membership.userId,
            deviceId: membership.deviceId,
            memberId: membership.memberId,
            callIntent: membership.callIntent,
            expiresAt: membership.absoluteExpiryTimestamp.map { TimeInterval($0) / 1000 }
        )
    }

    private static func isMatrixRTCMembershipEventType(_ eventType: String) -> Bool {
        eventType == MatrixRTCRawMembershipEvent.legacyCallMemberEventType
            || eventType == MatrixRTCRawMembershipEvent.rtcMemberEventType
    }
}

private struct RawStateEventPayload {
    let eventId: String
    let contentJSON: String
    let contentIsEmptyObject: Bool

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventId = root["event_id"] as? String,
              let content = root["content"] as? [String: Any],
              let contentData = try? JSONSerialization.data(withJSONObject: content),
              let contentJSON = String(data: contentData, encoding: .utf8) else {
            return nil
        }

        self.eventId = eventId
        self.contentJSON = contentJSON
        self.contentIsEmptyObject = content.isEmpty
    }
}
