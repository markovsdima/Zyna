//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

private let logCall = ScopedLog(.call)
private let logMatrixRTC = ScopedLog(.call, prefix: "[matrixrtc-sync]")

struct IncomingMatrixRTCCallNotification: Sendable {
    enum Kind: Sendable {
        case ring
        case notification

        var logLabel: String {
            switch self {
            case .ring:
                return "ring"
            case .notification:
                return "notification"
            }
        }
    }

    let eventId: String
    let roomId: String
    let senderId: String
    let senderName: String?
    let roomName: String
    let kind: Kind
    let isVoiceCall: Bool
    let expiresAt: Date
}

/// Global listener for incoming call invites via SDK sync notifications.
/// Detects m.call.invite events in any room without requiring an open
/// chat / per-room TimelineService.
final class CallNotificationListener: SyncNotificationListener {
    static let matrixRTCIncomingCallSubject = PassthroughSubject<IncomingMatrixRTCCallNotification, Never>()

    private static let deliveredMatrixRTCNotificationIdsLock = NSLock()
    private static var deliveredMatrixRTCNotificationIds = Set<String>()

    func onNotification(notification: NotificationItem, roomId: String) {
        guard case .timeline(let event) = notification.event,
              let eventContent = try? event.content()
        else { return }

        Self.logMatrixRTCNotificationIfNeeded(
            eventContent: eventContent,
            notification: notification,
            roomId: roomId
        )
        Self.emitIncomingMatrixRTCNotificationIfNeeded(
            event: event,
            eventContent: eventContent,
            notification: notification,
            roomId: roomId
        )

        guard case .messageLike(let msgType) = eventContent,
              case .callInvite = msgType
        else { return }

        let eventTimestamp = Date(
            timeIntervalSince1970: TimeInterval(event.timestamp()) / 1000
        )
        guard abs(eventTimestamp.timeIntervalSinceNow) < 60 else {
            logCall("Ignoring old call invite in room \(roomId)")
            return
        }

        guard !CallService.shared.state.isActive else { return }

        let senderId = event.senderId()
        let ownUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        guard senderId != ownUserId else { return }

        // Parse callId and SDP directly from the notification's raw
        // JSON — more reliable than latestEvent() which may have
        // already moved on to a newer event.
        let callData = Self.extractCallData(from: notification.rawEvent)
        guard let callId = callData.callId else {
            logCall("Failed to extract callId from invite")
            return
        }

        logCall("Call invite detected via sync notification in room \(roomId)")

        Task { @MainActor in
            guard let client = MatrixClientService.shared.client,
                  let room = try? client.getRoom(roomId: roomId)
            else {
                logCall("Failed to get room \(roomId) for incoming call")
                return
            }

            let callerName = notification.senderInfo.displayName

            let timelineService = TimelineService(room: room)
            await timelineService.startListening()

            CallService.shared.attachTimelineService(timelineService)

            CallService.shared.handleIncomingCall(
                room: room,
                callId: callId,
                callerName: callerName,
                offerSDP: callData.offerSDP,
                timelineService: timelineService
            )
        }
    }

    // MARK: - Private

    private static func emitIncomingMatrixRTCNotificationIfNeeded(
        event: TimelineEvent,
        eventContent: TimelineEventContent,
        notification: NotificationItem,
        roomId: String
    ) {
        guard case .messageLike(let msgType) = eventContent,
              case .rtcNotification(let notificationType, let expirationTimestamp, let callIntent) = msgType
        else {
            return
        }

        let kind: IncomingMatrixRTCCallNotification.Kind
        switch notificationType {
        case .ring:
            kind = .ring
        case .notification:
            kind = .notification
        }

        let ownUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        let senderId = event.senderId()
        guard senderId != ownUserId else { return }

        let expirationDate = Date(timeIntervalSince1970: TimeInterval(expirationTimestamp) / 1000)
        guard expirationDate > Date() else {
            logMatrixRTC("Ignoring expired MatrixRTC \(kind.logLabel) room=\(roomId) event=\(event.eventId())")
            return
        }

        let eventId = event.eventId()
        guard markMatrixRTCNotificationDelivered(eventId) else {
            return
        }

        let incoming = IncomingMatrixRTCCallNotification(
            eventId: eventId,
            roomId: roomId,
            senderId: senderId,
            senderName: notification.senderInfo.displayName,
            roomName: notification.roomInfo.displayName,
            kind: kind,
            isVoiceCall: callIntent == .audio,
            expiresAt: expirationDate
        )

        logMatrixRTC("Incoming MatrixRTC \(kind.logLabel) room=\(roomId) event=\(eventId) sender=\(senderId) voice=\(incoming.isVoiceCall)")
        matrixRTCIncomingCallSubject.send(incoming)
    }

    private static func markMatrixRTCNotificationDelivered(_ eventId: String) -> Bool {
        deliveredMatrixRTCNotificationIdsLock.lock()
        defer { deliveredMatrixRTCNotificationIdsLock.unlock() }

        guard !deliveredMatrixRTCNotificationIds.contains(eventId) else {
            return false
        }

        deliveredMatrixRTCNotificationIds.insert(eventId)
        if deliveredMatrixRTCNotificationIds.count > 200 {
            deliveredMatrixRTCNotificationIds.remove(deliveredMatrixRTCNotificationIds.first!)
        }
        return true
    }

    private static func logMatrixRTCNotificationIfNeeded(
        eventContent: TimelineEventContent,
        notification: NotificationItem,
        roomId: String
    ) {
        guard case .messageLike(let msgType) = eventContent else { return }

        let contentDescription = String(describing: msgType)
        let lowercasedDescription = contentDescription.lowercased()
        guard lowercasedDescription.contains("rtc")
            || lowercasedDescription.contains("callnotify")
            || lowercasedDescription.contains("callinvite")
        else {
            return
        }

        let rawEventType = rawEventType(from: notification.rawEvent) ?? "unknown"
        logMatrixRTC("Notification item room=\(roomId) rawType=\(rawEventType) content=\(contentDescription) sender=\(notification.senderInfo.displayName ?? "unknown") noisy=\(String(describing: notification.isNoisy))")
    }

    private static func rawEventType(from rawJSON: String) -> String? {
        guard let data = rawJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return root["type"] as? String
    }

    private static func extractCallData(
        from rawJSON: String
    ) -> (callId: String?, offerSDP: String?) {
        guard let data = rawJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [String: Any],
              let callId = content["call_id"] as? String
        else { return (nil, nil) }

        let sdp: String? = {
            if let offer = content["offer"] as? [String: Any] {
                return offer["sdp"] as? String
            }
            return nil
        }()

        return (callId, sdp)
    }
}
