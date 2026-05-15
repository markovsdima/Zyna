//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

private let logDirectRawText = ScopedLog(.timeline)

enum DirectRawTextSender {
    static let transactionIdContentKey = "com.zyna.client_txn_id"

    private static let defaultsKey = "com.zyna.matrix.directRawTextSend.enabled"

    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment["ZYNA_DIRECT_RAW_TEXT_SEND"]?.lowercased()
        if env == "1" || env == "true" || env == "yes" {
            return true
        }
        if env == "0" || env == "false" || env == "no" {
            return false
        }
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        return true
    }

    static func prepareTransactionId(
        replyEventId: String?,
        existingTransactionId: String? = nil
    ) -> String? {
        guard isEnabled,
              replyEventId == nil else { return nil }
        let transactionId = existingTransactionId ?? genTransactionId()
        logDirectRawText("DirectRawTx prepared tx=\(transactionId)")
        return transactionId
    }

    static func send(
        room: Room,
        body: String,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes(),
        transactionId: String
    ) async -> OutgoingDispatchReceipt {
        let htmlBody: String?
        if zynaAttributes.isEmpty {
            htmlBody = nil
        } else {
            htmlBody = ZynaHTMLCodec.encode(
                userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(body),
                attributes: zynaAttributes
            )
        }

        do {
            let eventId = try await sendRawTextMessage(
                room: room,
                body: body,
                htmlBody: htmlBody,
                transactionId: transactionId
            )
            if zynaAttributes.isEmpty {
                logDirectRawText(
                    "DirectRawTx dispatch done tx=\(transactionId) event=\(eventId)"
                )
            } else {
                logDirectRawText(
                    "DirectRawTx dispatch done attrs=true tx=\(transactionId) event=\(eventId)"
                )
            }
            return .accepted(transactionId: transactionId, eventId: eventId)
        } catch {
            let receipt = rejectedReceipt(for: error)
            if zynaAttributes.isEmpty {
                logDirectRawText(
                    "DirectRawTx send failed tx=\(transactionId) retryable=\(receipt.retryableTransportFailure) error=\(error)"
                )
            } else {
                logDirectRawText(
                    "DirectRawTx send failed attrs=true tx=\(transactionId) retryable=\(receipt.retryableTransportFailure) error=\(error)"
                )
            }
            return receipt
        }
    }

    private static func sendRawTextMessage(
        room: Room,
        body: String,
        htmlBody: String?,
        transactionId: String
    ) async throws -> String {
        let content = try rawTextMessageContentJSON(
            body: body,
            htmlBody: htmlBody,
            transactionId: transactionId
        )
        do {
            logDirectRawText(
                "DirectRawTx send start tx=\(transactionId) marker=\(transactionIdContentKey)"
            )
            let eventId = try await room.sendRawWithTransactionIdReturningEventId(
                eventType: "m.room.message",
                content: content,
                transactionId: transactionId
            )
            logDirectRawText("DirectRawTx send accepted tx=\(transactionId) event=\(eventId)")
            return eventId
        } catch {
            await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
            throw error
        }
    }

    private static func rawTextMessageContentJSON(
        body: String,
        htmlBody: String?,
        transactionId: String
    ) throws -> String {
        var content: [String: Any] = [
            "msgtype": "m.text",
            "body": body,
            transactionIdContentKey: transactionId
        ]
        if let htmlBody {
            content["format"] = "org.matrix.custom.html"
            content["formatted_body"] = htmlBody
        }
        let data = try JSONSerialization.data(
            withJSONObject: content,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func rejectedReceipt(for error: Error) -> OutgoingDispatchReceipt {
        let context = OutgoingSendFailureContext.fromError(error)
        return .rejected(
            context: context,
            retryableTransportFailure: context == nil && isRetryableTransportError(error)
        )
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive,
                 NSURLErrorDataNotAllowed:
                return true
            default:
                break
            }
        }

        let errorText = [
            String(reflecting: error),
            String(describing: error),
            nsError.localizedDescription
        ]
        .joined(separator: "\n")
        .lowercased()

        return containsAny(
            [
                "network",
                "not connected",
                "notconnectedtointernet",
                "connection lost",
                "networkconnectionlost",
                "timed out",
                "timeout",
                "cannot find host",
                "cannotfindhost",
                "cannot connect",
                "cannotconnecttohost",
                "connection refused",
                "dns",
                "temporarily unavailable",
                "service unavailable",
                "bad gateway",
                "gateway timeout",
                "server error",
                "servererror"
            ],
            in: errorText
        )
    }

    private static func containsAny(_ needles: [String], in haystack: String) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
