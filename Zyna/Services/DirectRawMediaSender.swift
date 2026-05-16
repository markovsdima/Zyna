//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

private let logDirectRawMedia = ScopedLog(.timeline)

enum DirectRawMediaSender {
    private static let imageDefaultsKey = "com.zyna.matrix.directRawImageSend.enabled"

    static var isImageEnabled: Bool {
        guard DirectRawTextSender.isEnabled else { return false }

        let env = ProcessInfo.processInfo.environment["ZYNA_DIRECT_RAW_IMAGE_SEND"]?.lowercased()
        if env == "1" || env == "true" || env == "yes" {
            return true
        }
        if env == "0" || env == "false" || env == "no" {
            return false
        }
        if UserDefaults.standard.object(forKey: imageDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: imageDefaultsKey)
        }
        return true
    }

    static func prepareImageTransactionId(
        existingTransactionId: String? = nil
    ) -> String? {
        guard isImageEnabled else { return nil }
        let transactionId = existingTransactionId ?? UUID()
            .uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        logDirectRawMedia("DirectRawImageTx prepared tx=\(transactionId)")
        return transactionId
    }

    static func uploadImage(
        room: Room,
        image: PendingDirectImageRecord,
        originalFileURL: URL,
        thumbnailFileURL: URL,
        transactionId: String
    ) async throws -> String {
        logDirectRawMedia(
            "DirectRawImageTx upload start tx=\(transactionId) bytes=\(image.originalSize) "
                + "thumbBytes=\(image.thumbnailSize) size=\(image.originalWidth)x\(image.originalHeight)"
        )
        let uploadedImageJSON = try await room.uploadImageForEvent(
            originalFilePath: originalFileURL.path(percentEncoded: false),
            thumbnailFilePath: thumbnailFileURL.path(percentEncoded: false),
            originalMimetype: image.originalMimetype,
            originalSize: UInt64(clamping: image.originalSize),
            originalWidth: UInt64(clamping: image.originalWidth),
            originalHeight: UInt64(clamping: image.originalHeight),
            thumbnailMimetype: image.thumbnailMimetype,
            thumbnailSize: UInt64(clamping: image.thumbnailSize),
            thumbnailWidth: UInt64(clamping: image.thumbnailWidth),
            thumbnailHeight: UInt64(clamping: image.thumbnailHeight),
            blurhash: image.blurhash
        )
        logDirectRawMedia(
            "DirectRawImageTx upload accepted tx=\(transactionId) uploadedBytes=\(uploadedImageJSON.count)"
        )
        return uploadedImageJSON
    }

    static func sendUploadedImage(
        room: Room,
        uploadedImageJSON: String,
        caption: String?,
        zynaAttributes: ZynaMessageAttributes,
        replyEventId: String?,
        transactionId: String
    ) async -> OutgoingDispatchReceipt {
        do {
            let captionPayload = imageCaptionPayload(
                caption: caption,
                zynaAttributes: zynaAttributes
            )
            logDirectRawMedia(
                "DirectRawImageTx send start tx=\(transactionId) reply=\(replyEventId ?? "-")"
            )
            let eventId = try await room.sendUploadedImageWithTransactionIdReturningEventId(
                uploadedImageJson: uploadedImageJSON,
                transactionId: transactionId,
                caption: captionPayload.plain,
                formattedCaption: captionPayload.formattedHTML,
                replyEventId: replyEventId
            )
            logDirectRawMedia(
                "DirectRawImageTx send accepted tx=\(transactionId) event=\(eventId)"
            )
            scheduleIntentionalCrashIfNeeded(
                point: "after-send-accepted",
                transactionId: transactionId
            )
            return .accepted(transactionId: transactionId, eventId: eventId)
        } catch {
            let receipt = rejectedReceipt(for: error)
            logDirectRawMedia(
                "DirectRawImageTx send failed tx=\(transactionId) retryable=\(receipt.retryableTransportFailure) error=\(error)"
            )
            await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
            return receipt
        }
    }

    static func rejectedReceipt(for error: Error) -> OutgoingDispatchReceipt {
        let context = OutgoingSendFailureContext.fromError(error)
        return .rejected(
            context: context,
            retryableTransportFailure: context == nil && isRetryableTransportError(error)
        )
    }

    static func scheduleIntentionalCrashIfNeeded(
        point: String,
        transactionId: String
    ) {
        let requested = ProcessInfo.processInfo
            .environment["ZYNA_DIRECT_RAW_IMAGE_CRASH_POINT"]?
            .lowercased()
        guard requested == point else { return }

        let delayMs = ProcessInfo.processInfo
            .environment["ZYNA_DIRECT_RAW_IMAGE_CRASH_DELAY_MS"]
            .flatMap(UInt64.init) ?? 250
        logDirectRawMedia(
            "DirectRawImageTx crash scheduled point=\(point) tx=\(transactionId) delayMs=\(delayMs)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) {
            fatalError("DirectRawImageTx intentional crash \(point) tx=\(transactionId)")
        }
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
                "retryable error",
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

    private static func imageCaptionPayload(
        caption: String?,
        zynaAttributes: ZynaMessageAttributes
    ) -> (plain: String?, formattedHTML: String?) {
        guard !zynaAttributes.isEmpty else {
            return (caption, nil)
        }

        let visibleCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userCaption = (visibleCaption?.isEmpty == false) ? visibleCaption! : "\u{200B}"
        let formattedHTML = ZynaHTMLCodec.encode(
            userHTML: ZynaHTMLCodec.escapeForHTMLAttribute(userCaption),
            attributes: zynaAttributes
        )
        return (userCaption, formattedHTML)
    }
}
