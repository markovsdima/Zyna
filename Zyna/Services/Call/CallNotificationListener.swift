//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

private let logCall = ScopedLog(.call)

/// Global listener for incoming call invites via SDK sync notifications.
/// Detects m.call.invite events in any room without requiring an open
/// chat / per-room TimelineService.
final class CallNotificationListener: SyncNotificationListener {

    func onNotification(notification: NotificationItem, roomId: String) {
        guard case .timeline(let event) = notification.event,
              let eventType = try? event.eventType(),
              case .messageLike(let content) = eventType,
              case .callInvite = content
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

        logCall("Call invite detected via sync notification in room \(roomId)")

        Task { @MainActor in
            guard let client = MatrixClientService.shared.client,
                  let room = try? client.getRoom(roomId: roomId)
            else {
                logCall("Failed to get room \(roomId) for incoming call")
                return
            }

            // Extract callId and SDP from the room's latest event
            guard let latestEvent = await room.latestEvent() else {
                logCall("No latest event for room \(roomId)")
                return
            }

            let callData = Self.extractCallData(from: latestEvent)
            guard let callId = callData.callId else {
                logCall("Failed to extract callId from invite")
                return
            }

            let callerName = notification.senderInfo.displayName

            // Create a TimelineService so signaling (answer, candidates,
            // hangup) can flow through the room's timeline.
            let timelineService = TimelineService(room: room)
            await timelineService.startListening()

            // Hold reference so it survives the call duration
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

    private static func extractCallData(
        from event: EventTimelineItem
    ) -> (callId: String?, offerSDP: String?) {
        guard let json = event.lazyProvider.debugInfo().originalJson,
              let data = json.data(using: .utf8),
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
