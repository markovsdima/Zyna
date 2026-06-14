//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRTC
import MatrixRustSDK

private let log = ScopedLog(.call, prefix: "[matrixrtc-native]")

struct MatrixRTCCallNotificationSendResult: Sendable {
    let sentNotification: Bool
    let notificationEventId: String?
    let sentLegacyFallback: Bool
    let legacyFallbackEventId: String?
    let notificationType: MatrixRTCCallNotificationType
    let senderTimestamp: Int64
    let lifetimeMilliseconds: Int64
}

final class MatrixRustSDKRTCCallNotificationClient: @unchecked Sendable {
    private let room: Room
    private let timestampProvider: @Sendable () -> Int64

    init(
        room: Room,
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        self.room = room
        self.timestampProvider = timestampProvider
    }

    func sendCallNotification(
        parentEventId: String,
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        notificationType: MatrixRTCCallNotificationType = .ring,
        callIntent: String? = nil
    ) async throws -> MatrixRTCCallNotificationSendResult {
        let content = MatrixRTCCallNotificationContent(
            parentEventId: parentEventId,
            notificationType: notificationType,
            senderTimestamp: timestampProvider(),
            callIntent: callIntent
        )

        let legacyContent = MatrixRTCLegacyCallNotifyContent(
            slot: slot,
            notificationType: notificationType
        )

        var firstError: Error?
        var sentNotification = false
        var sentLegacyFallback = false
        var notificationEventId: String?
        var legacyFallbackEventId: String?

        do {
            notificationEventId = try await room.sendRawWithTransactionIdReturningEventId(
                eventType: MatrixRTCCallNotificationContent.eventType,
                content: content.jsonString(),
                transactionId: "matrixrtc-notification-\(UUID().uuidString)"
            )
            sentNotification = true
        } catch {
            firstError = error
            log("Failed sending MatrixRTC notification event for room \(room.id()): \(error)")
        }

        do {
            legacyFallbackEventId = try await room.sendRawWithTransactionIdReturningEventId(
                eventType: MatrixRTCLegacyCallNotifyContent.eventType,
                content: legacyContent.jsonString(),
                transactionId: "matrixrtc-legacy-notify-\(UUID().uuidString)"
            )
            sentLegacyFallback = true
        } catch {
            if firstError == nil {
                firstError = error
            }
            log("Failed sending legacy MatrixRTC call notification fallback for room \(room.id()): \(error)")
        }

        guard sentNotification || sentLegacyFallback else {
            throw firstError ?? MatrixRustSDKRTCCallNotificationClientError.sendFailed
        }

        return .init(
            sentNotification: sentNotification,
            notificationEventId: notificationEventId,
            sentLegacyFallback: sentLegacyFallback,
            legacyFallbackEventId: legacyFallbackEventId,
            notificationType: notificationType,
            senderTimestamp: content.senderTimestamp,
            lifetimeMilliseconds: content.lifetime
        )
    }
}

private enum MatrixRustSDKRTCCallNotificationClientError: Error {
    case sendFailed
}
