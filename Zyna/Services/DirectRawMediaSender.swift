//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

private let logDirectRawMedia = ScopedLog(.timeline)

enum DirectRawMediaSender {
    private static let imageDefaultsKey = "com.zyna.matrix.directRawImageSend.enabled"
    private static let videoDefaultsKey = "com.zyna.matrix.directRawVideoSend.enabled"
    private static let fileDefaultsKey = "com.zyna.matrix.directRawFileSend.enabled"
    private static let voiceDefaultsKey = "com.zyna.matrix.directRawVoiceSend.enabled"

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

    static var isVoiceEnabled: Bool {
        guard DirectRawTextSender.isEnabled else { return false }

        let env = ProcessInfo.processInfo.environment["ZYNA_DIRECT_RAW_VOICE_SEND"]?.lowercased()
        if env == "1" || env == "true" || env == "yes" {
            return true
        }
        if env == "0" || env == "false" || env == "no" {
            return false
        }
        if UserDefaults.standard.object(forKey: voiceDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: voiceDefaultsKey)
        }
        return true
    }

    static var isVideoEnabled: Bool {
        guard DirectRawTextSender.isEnabled else { return false }

        let env = ProcessInfo.processInfo.environment["ZYNA_DIRECT_RAW_VIDEO_SEND"]?.lowercased()
        if env == "1" || env == "true" || env == "yes" {
            return true
        }
        if env == "0" || env == "false" || env == "no" {
            return false
        }
        if UserDefaults.standard.object(forKey: videoDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: videoDefaultsKey)
        }
        return true
    }

    static var isFileEnabled: Bool {
        guard DirectRawTextSender.isEnabled else { return false }

        let env = ProcessInfo.processInfo.environment["ZYNA_DIRECT_RAW_FILE_SEND"]?.lowercased()
        if env == "1" || env == "true" || env == "yes" {
            return true
        }
        if env == "0" || env == "false" || env == "no" {
            return false
        }
        if UserDefaults.standard.object(forKey: fileDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: fileDefaultsKey)
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

    static func prepareVoiceTransactionId(
        existingTransactionId: String? = nil
    ) -> String? {
        guard isVoiceEnabled else { return nil }
        let transactionId = existingTransactionId ?? UUID()
            .uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        logDirectRawMedia("DirectRawVoiceTx prepared tx=\(transactionId)")
        return transactionId
    }

    static func prepareVideoTransactionId(
        existingTransactionId: String? = nil
    ) -> String? {
        guard isVideoEnabled else { return nil }
        let transactionId = existingTransactionId ?? UUID()
            .uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        logDirectRawMedia("DirectRawVideoTx prepared tx=\(transactionId)")
        return transactionId
    }

    static func prepareFileTransactionId(
        existingTransactionId: String? = nil
    ) -> String? {
        guard isFileEnabled else { return nil }
        let transactionId = existingTransactionId ?? UUID()
            .uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        logDirectRawMedia("DirectRawFileTx prepared tx=\(transactionId)")
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
            let captionPayload = mediaCaptionPayload(
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

    static func uploadVideo(
        room: Room,
        video: PendingDirectVideoRecord,
        originalFileURL: URL,
        thumbnailFileURL: URL,
        transactionId: String
    ) async throws -> String {
        logDirectRawMedia(
            "DirectRawVideoTx upload start tx=\(transactionId) bytes=\(video.originalSize) "
                + "thumbBytes=\(video.thumbnailSize) size=\(video.originalWidth)x\(video.originalHeight) "
                + "duration=\(String(format: "%.3f", video.originalDuration))"
        )
        let uploadedVideoJSON = try await room.uploadVideoForEvent(
            originalFilePath: originalFileURL.path(percentEncoded: false),
            thumbnailFilePath: thumbnailFileURL.path(percentEncoded: false),
            originalMimetype: video.originalMimetype,
            originalSize: UInt64(clamping: video.originalSize),
            originalDuration: video.originalDuration,
            originalWidth: UInt64(clamping: video.originalWidth),
            originalHeight: UInt64(clamping: video.originalHeight),
            thumbnailMimetype: video.thumbnailMimetype,
            thumbnailSize: UInt64(clamping: video.thumbnailSize),
            thumbnailWidth: UInt64(clamping: video.thumbnailWidth),
            thumbnailHeight: UInt64(clamping: video.thumbnailHeight),
            blurhash: video.blurhash,
            progressWatcher: nil
        )
        logDirectRawMedia(
            "DirectRawVideoTx upload accepted tx=\(transactionId) uploadedBytes=\(uploadedVideoJSON.count)"
        )
        return uploadedVideoJSON
    }

    static func sendUploadedVideo(
        room: Room,
        uploadedVideoJSON: String,
        caption: String?,
        zynaAttributes: ZynaMessageAttributes,
        replyEventId: String?,
        transactionId: String
    ) async -> OutgoingDispatchReceipt {
        do {
            let captionPayload = mediaCaptionPayload(
                caption: caption,
                zynaAttributes: zynaAttributes
            )
            logDirectRawMedia(
                "DirectRawVideoTx send start tx=\(transactionId) reply=\(replyEventId ?? "-")"
            )
            let eventId = try await room.sendUploadedVideoWithTransactionIdReturningEventId(
                uploadedVideoJson: uploadedVideoJSON,
                transactionId: transactionId,
                caption: captionPayload.plain,
                formattedCaption: captionPayload.formattedHTML,
                replyEventId: replyEventId
            )
            logDirectRawMedia(
                "DirectRawVideoTx send accepted tx=\(transactionId) event=\(eventId)"
            )
            scheduleVideoIntentionalCrashIfNeeded(
                point: "after-send-accepted",
                transactionId: transactionId
            )
            return .accepted(transactionId: transactionId, eventId: eventId)
        } catch {
            let receipt = rejectedReceipt(for: error)
            logDirectRawMedia(
                "DirectRawVideoTx send failed tx=\(transactionId) retryable=\(receipt.retryableTransportFailure) error=\(error)"
            )
            await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
            return receipt
        }
    }

    static func uploadVoice(
        room: Room,
        fileURL: URL,
        mimetype: String,
        duration: TimeInterval,
        waveform: [Float],
        transactionId: String
    ) async throws -> String {
        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0
        logDirectRawMedia(
            "DirectRawVoiceTx upload start tx=\(transactionId) bytes=\(fileSize) "
                + "duration=\(String(format: "%.3f", duration)) waveform=\(waveform.count)"
        )
        let uploadedVoiceJSON = try await room.uploadVoiceForEvent(
            filePath: fileURL.path(percentEncoded: false),
            mimetype: mimetype,
            size: fileSize,
            duration: duration,
            waveform: waveform
        )
        logDirectRawMedia(
            "DirectRawVoiceTx upload accepted tx=\(transactionId) uploadedBytes=\(uploadedVoiceJSON.count)"
        )
        return uploadedVoiceJSON
    }

    static func uploadFile(
        room: Room,
        file: PendingDirectFileRecord,
        fileURL: URL,
        transactionId: String
    ) async throws -> String {
        logDirectRawMedia(
            "DirectRawFileTx upload start tx=\(transactionId) filename=\(file.filename) bytes=\(file.size)"
        )
        let uploadedFileJSON = try await room.uploadFileForEvent(
            filePath: fileURL.path(percentEncoded: false),
            thumbnailFilePath: nil,
            mimetype: file.mimetype,
            size: UInt64(clamping: file.size),
            thumbnailMimetype: nil,
            thumbnailSize: nil,
            thumbnailWidth: nil,
            thumbnailHeight: nil,
            progressWatcher: nil
        )
        logDirectRawMedia(
            "DirectRawFileTx upload accepted tx=\(transactionId) uploadedBytes=\(uploadedFileJSON.count)"
        )
        return uploadedFileJSON
    }

    static func sendUploadedFile(
        room: Room,
        uploadedFileJSON: String,
        caption: String?,
        zynaAttributes: ZynaMessageAttributes,
        replyEventId: String?,
        transactionId: String
    ) async -> OutgoingDispatchReceipt {
        do {
            let captionPayload = mediaCaptionPayload(
                caption: caption,
                zynaAttributes: zynaAttributes
            )
            logDirectRawMedia(
                "DirectRawFileTx send start tx=\(transactionId) reply=\(replyEventId ?? "-")"
            )
            let eventId = try await room.sendUploadedFileWithTransactionIdReturningEventId(
                uploadedFileJson: uploadedFileJSON,
                transactionId: transactionId,
                caption: captionPayload.plain,
                formattedCaption: captionPayload.formattedHTML,
                replyEventId: replyEventId
            )
            logDirectRawMedia(
                "DirectRawFileTx send accepted tx=\(transactionId) event=\(eventId)"
            )
            scheduleFileIntentionalCrashIfNeeded(
                point: "after-send-accepted",
                transactionId: transactionId
            )
            return .accepted(transactionId: transactionId, eventId: eventId)
        } catch {
            let receipt = rejectedReceipt(for: error)
            logDirectRawMedia(
                "DirectRawFileTx send failed tx=\(transactionId) retryable=\(receipt.retryableTransportFailure) error=\(error)"
            )
            await MatrixClientService.shared.handleInvalidAccessTokenIfNeeded(error)
            return receipt
        }
    }

    static func scheduleVideoIntentionalCrashIfNeeded(
        point: String,
        transactionId: String
    ) {
        let requested = ProcessInfo.processInfo
            .environment["ZYNA_DIRECT_RAW_VIDEO_CRASH_POINT"]?
            .lowercased()
        guard requested == point else { return }

        let delayMs = ProcessInfo.processInfo
            .environment["ZYNA_DIRECT_RAW_VIDEO_CRASH_DELAY_MS"]
            .flatMap(UInt64.init) ?? 250
        logDirectRawMedia(
            "DirectRawVideoTx crash scheduled point=\(point) tx=\(transactionId) delayMs=\(delayMs)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) {
            fatalError("DirectRawVideoTx intentional crash \(point) tx=\(transactionId)")
        }
    }

    static func scheduleFileIntentionalCrashIfNeeded(
        point: String,
        transactionId: String
    ) {
        let requested = ProcessInfo.processInfo
            .environment["ZYNA_DIRECT_RAW_FILE_CRASH_POINT"]?
            .lowercased()
        guard requested == point else { return }

        let delayMs = ProcessInfo.processInfo
            .environment["ZYNA_DIRECT_RAW_FILE_CRASH_DELAY_MS"]
            .flatMap(UInt64.init) ?? 250
        logDirectRawMedia(
            "DirectRawFileTx crash scheduled point=\(point) tx=\(transactionId) delayMs=\(delayMs)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) {
            fatalError("DirectRawFileTx intentional crash \(point) tx=\(transactionId)")
        }
    }

    static func sendUploadedVoice(
        room: Room,
        uploadedVoiceJSON: String,
        replyEventId: String?,
        transactionId: String
    ) async -> OutgoingDispatchReceipt {
        do {
            logDirectRawMedia(
                "DirectRawVoiceTx send start tx=\(transactionId) reply=\(replyEventId ?? "-")"
            )
            let eventId = try await room.sendUploadedVoiceWithTransactionIdReturningEventId(
                uploadedVoiceJson: uploadedVoiceJSON,
                transactionId: transactionId,
                replyEventId: replyEventId
            )
            logDirectRawMedia(
                "DirectRawVoiceTx send accepted tx=\(transactionId) event=\(eventId)"
            )
            scheduleVoiceIntentionalCrashIfNeeded(
                point: "after-send-accepted",
                transactionId: transactionId
            )
            return .accepted(transactionId: transactionId, eventId: eventId)
        } catch {
            let receipt = rejectedReceipt(for: error)
            logDirectRawMedia(
                "DirectRawVoiceTx send failed tx=\(transactionId) retryable=\(receipt.retryableTransportFailure) error=\(error)"
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

    static func scheduleVoiceIntentionalCrashIfNeeded(
        point: String,
        transactionId: String
    ) {
        let requested = ProcessInfo.processInfo
            .environment["ZYNA_DIRECT_RAW_VOICE_CRASH_POINT"]?
            .lowercased()
        guard requested == point else { return }

        let delayMs = ProcessInfo.processInfo
            .environment["ZYNA_DIRECT_RAW_VOICE_CRASH_DELAY_MS"]
            .flatMap(UInt64.init) ?? 250
        logDirectRawMedia(
            "DirectRawVoiceTx crash scheduled point=\(point) tx=\(transactionId) delayMs=\(delayMs)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) {
            fatalError("DirectRawVoiceTx intentional crash \(point) tx=\(transactionId)")
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

    private static func mediaCaptionPayload(
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
