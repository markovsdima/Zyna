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
        guard isEnabled else { return nil }
        let transactionId = existingTransactionId ?? genTransactionId()
        logDirectRawText("DirectRawTx prepared tx=\(transactionId)")
        return transactionId
    }

    static func prepareEditTransactionId(
        existingTransactionId: String? = nil
    ) -> String? {
        guard isEnabled else { return nil }
        let transactionId = existingTransactionId ?? genTransactionId()
        logDirectRawText("DirectRawEditTx prepared tx=\(transactionId)")
        return transactionId
    }

    static func send(
        room: Room,
        body: String,
        replyInfo: ReplyInfo? = nil,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes(),
        transactionId: String
    ) async -> OutgoingDispatchReceipt {
        do {
            let eventId = try await sendRawTextMessage(
                room: room,
                body: body,
                replyInfo: replyInfo,
                zynaAttributes: zynaAttributes,
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

    static func sendEdit(
        room: Room,
        eventId: String,
        body: String,
        zynaAttributes: ZynaMessageAttributes = ZynaMessageAttributes(),
        transactionId: String
    ) async -> OutgoingDispatchReceipt {
        do {
            let editEventId = try await sendRawTextEdit(
                room: room,
                eventId: eventId,
                body: body,
                zynaAttributes: zynaAttributes,
                transactionId: transactionId
            )
            logDirectRawText(
                "DirectRawEditTx dispatch done event=\(eventId) edit=\(editEventId) tx=\(transactionId)"
            )
            return .accepted(transactionId: transactionId, eventId: editEventId)
        } catch {
            let receipt = rejectedReceipt(for: error)
            logDirectRawText(
                "DirectRawEditTx send failed event=\(eventId) tx=\(transactionId) "
                    + "retryable=\(receipt.retryableTransportFailure) error=\(error)"
            )
            return receipt
        }
    }

    private static func sendRawTextMessage(
        room: Room,
        body: String,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes,
        transactionId: String
    ) async throws -> String {
        let content = try rawTextMessageContentJSON(
            roomId: room.id(),
            body: body,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes,
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

    private static func sendRawTextEdit(
        room: Room,
        eventId: String,
        body: String,
        zynaAttributes: ZynaMessageAttributes,
        transactionId: String
    ) async throws -> String {
        let content = try rawTextEditContentJSON(
            body: body,
            eventId: eventId,
            zynaAttributes: zynaAttributes,
            transactionId: transactionId
        )
        do {
            logDirectRawText(
                "DirectRawEditTx send start event=\(eventId) tx=\(transactionId) marker=\(transactionIdContentKey)"
            )
            let editEventId = try await room.sendRawWithTransactionIdReturningEventId(
                eventType: "m.room.message",
                content: content,
                transactionId: transactionId
            )
            logDirectRawText(
                "DirectRawEditTx send accepted event=\(eventId) edit=\(editEventId) tx=\(transactionId)"
            )
            return editEventId
        } catch {
            await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
            throw error
        }
    }

    private static func rawTextMessageContentJSON(
        roomId: String,
        body: String,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes,
        transactionId: String
    ) throws -> String {
        let fallbackBody = replyInfo.map {
            plainReplyBody(body: body, replyInfo: $0)
        } ?? body

        var content: [String: Any] = [
            "msgtype": "m.text",
            "body": fallbackBody,
            transactionIdContentKey: transactionId
        ]

        if let replyInfo {
            content["m.relates_to"] = [
                "m.in_reply_to": [
                    "event_id": replyInfo.eventId
                ]
            ]
        }

        let htmlBody = formattedBody(
            roomId: roomId,
            body: body,
            replyInfo: replyInfo,
            zynaAttributes: zynaAttributes
        )
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

    private static func rawTextEditContentJSON(
        body: String,
        eventId: String,
        zynaAttributes: ZynaMessageAttributes,
        transactionId: String
    ) throws -> String {
        let newContent = rawTextNewContent(
            body: body,
            zynaAttributes: zynaAttributes
        )
        var content = newContent
        content["body"] = "* \(body)"
        if let formattedBody = newContent["formatted_body"] as? String {
            content["format"] = "org.matrix.custom.html"
            content["formatted_body"] = "* \(formattedBody)"
        }
        content["m.new_content"] = newContent
        content["m.relates_to"] = [
            "rel_type": "m.replace",
            "event_id": eventId
        ]
        content[transactionIdContentKey] = transactionId

        let data = try JSONSerialization.data(
            withJSONObject: content,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func rawTextNewContent(
        body: String,
        zynaAttributes: ZynaMessageAttributes
    ) -> [String: Any] {
        var content: [String: Any] = [
            "msgtype": "m.text",
            "body": body
        ]
        guard !zynaAttributes.isEmpty else { return content }

        let htmlBody = ZynaHTMLCodec.encode(
            userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(body),
            attributes: zynaAttributes
        )
        content["format"] = "org.matrix.custom.html"
        content["formatted_body"] = htmlBody
        return content
    }

    private static func formattedBody(
        roomId: String,
        body: String,
        replyInfo: ReplyInfo?,
        zynaAttributes: ZynaMessageAttributes
    ) -> String? {
        guard replyInfo != nil || !zynaAttributes.isEmpty else { return nil }

        var html = ZynaHTMLCodec.escapeForHTMLAttribute(body)
        if let replyInfo {
            html = htmlReplyFallback(roomId: roomId, replyInfo: replyInfo) + html
        }

        return ZynaHTMLCodec.encode(userHTML: html, attributes: zynaAttributes)
    }

    private static func plainReplyBody(body: String, replyInfo: ReplyInfo) -> String {
        var quotedLines = replyInfo.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
        if let firstLine = quotedLines.first {
            quotedLines[0] = "> <\(replyInfo.senderId)> \(firstLine.dropFirst(2))"
        } else {
            quotedLines = ["> <\(replyInfo.senderId)>"]
        }
        return "\(quotedLines.joined(separator: "\n"))\n\n\(body)"
    }

    private static func htmlReplyFallback(
        roomId: String,
        replyInfo: ReplyInfo
    ) -> String {
        let roomEventLink = ZynaHTMLCodec.escapeForHTMLAttribute(
            "https://matrix.to/#/\(roomId)/\(replyInfo.eventId)"
        )
        let senderLink = ZynaHTMLCodec.escapeForHTMLAttribute(
            "https://matrix.to/#/\(replyInfo.senderId)"
        )
        let senderName = ZynaHTMLCodec.escapeForHTMLAttribute(
            replyInfo.senderDisplayName ?? replyInfo.senderId
        )
        let quotedBody = htmlLineBreaks(
            ZynaHTMLCodec.escapeForHTMLAttribute(replyInfo.body)
        )

        return """
        <mx-reply><blockquote><a href="\(roomEventLink)">In reply to</a> <a href="\(senderLink)">\(senderName)</a><br>\(quotedBody)</blockquote></mx-reply>
        """
    }

    private static func htmlLineBreaks(_ html: String) -> String {
        html
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
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
