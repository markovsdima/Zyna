//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// One attachment of a room, precomputed from an `EventTimelineItem` so views
/// never touch the FFI. `MediaSource` is a class without `Equatable`; identity
/// is its mxc URL, which is the same for plain and encrypted sources.
struct AttachmentItem: Identifiable, Equatable {

    enum Kind: String, Equatable {
        case image
        case video
        case file
        case audio
        case voice

        var isVisual: Bool { self == .image || self == .video }
    }

    struct ThumbnailRef: Equatable {
        let source: MediaSource
        let mxc: String
        let isEncrypted: Bool
        let width: Int?
        let height: Int?
        let sizeBytes: UInt64?
        let mimetype: String?

        static func == (lhs: ThumbnailRef, rhs: ThumbnailRef) -> Bool {
            lhs.mxc == rhs.mxc
                && lhs.isEncrypted == rhs.isEncrypted
                && lhs.width == rhs.width
                && lhs.height == rhs.height
                && lhs.sizeBytes == rhs.sizeBytes
                && lhs.mimetype == rhs.mimetype
        }
    }

    /// Matrix event id. Local echoes are never mapped, so this is always remote.
    let id: String
    let uniqueId: String
    let kind: Kind
    let timestampMs: UInt64
    let sender: String
    let senderName: String?
    let isOwn: Bool
    let filename: String
    let caption: String?
    let mimetype: String?
    let sizeBytes: UInt64?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let durationSeconds: TimeInterval?
    let blurhash: String?
    let isAnimated: Bool
    let source: MediaSource
    let sourceMxc: String
    let isSourceEncrypted: Bool
    let thumbnail: ThumbnailRef?

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
    }

    var aspectRatio: CGFloat? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    static func == (lhs: AttachmentItem, rhs: AttachmentItem) -> Bool {
        lhs.id == rhs.id
            && lhs.uniqueId == rhs.uniqueId
            && lhs.kind == rhs.kind
            && lhs.timestampMs == rhs.timestampMs
            && lhs.sender == rhs.sender
            && lhs.senderName == rhs.senderName
            && lhs.isOwn == rhs.isOwn
            && lhs.filename == rhs.filename
            && lhs.caption == rhs.caption
            && lhs.mimetype == rhs.mimetype
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.blurhash == rhs.blurhash
            && lhs.isAnimated == rhs.isAnimated
            && lhs.sourceMxc == rhs.sourceMxc
            && lhs.isSourceEncrypted == rhs.isSourceEncrypted
            && lhs.thumbnail == rhs.thumbnail
    }
}

// MARK: - Mapping from the SDK

extension AttachmentItem {

    private struct EventBase {
        let id: String
        let uniqueId: String
        let timestampMs: UInt64
        let sender: String
        let senderName: String?
        let isOwn: Bool
    }

    /// Mirrors `TimelineService.contentFromMessageType`: stickers, galleries,
    /// polls and text map to nil. Local echoes are skipped so ids never flip
    /// from transaction id to event id under the grid.
    static func make(from event: EventTimelineItem, uniqueId: String) -> AttachmentItem? {
        guard event.isRemote,
              case .eventId(let eventId) = event.eventOrTransactionId,
              case .msgLike(let msgLike) = event.content,
              case .message(let message) = msgLike.kind else {
            return nil
        }

        let senderName: String? = {
            if case .ready(let displayName, _, _) = event.senderProfile {
                return displayName
            }
            return nil
        }()
        let base = EventBase(
            id: eventId,
            uniqueId: uniqueId,
            timestampMs: event.timestamp,
            sender: event.sender,
            senderName: senderName,
            isOwn: event.isOwn
        )

        switch message.msgType {
        case .image(let content):
            return build(
                base: base,
                kind: .image,
                filename: content.filename,
                caption: content.caption,
                mimetype: content.info?.mimetype,
                sizeBytes: content.info?.size,
                pixelWidth: content.info?.width,
                pixelHeight: content.info?.height,
                durationSeconds: nil,
                blurhash: content.info?.blurhash,
                isAnimated: content.info?.isAnimated ?? false,
                source: content.source,
                thumbnailSource: content.info?.thumbnailSource,
                thumbnailInfo: content.info?.thumbnailInfo
            )

        case .video(let content):
            return build(
                base: base,
                kind: .video,
                filename: content.filename,
                caption: content.caption,
                mimetype: content.info?.mimetype,
                sizeBytes: content.info?.size,
                pixelWidth: content.info?.width,
                pixelHeight: content.info?.height,
                durationSeconds: content.info?.duration,
                blurhash: content.info?.blurhash,
                isAnimated: false,
                source: content.source,
                thumbnailSource: content.info?.thumbnailSource,
                thumbnailInfo: content.info?.thumbnailInfo
            )

        case .file(let content):
            let isVideo = TimelineService.isLikelyVideoFile(
                filename: content.filename,
                mimetype: content.info?.mimetype
            )
            return build(
                base: base,
                kind: isVideo ? .video : .file,
                filename: content.filename,
                caption: content.caption,
                mimetype: content.info?.mimetype,
                sizeBytes: content.info?.size,
                pixelWidth: nil,
                pixelHeight: nil,
                durationSeconds: nil,
                blurhash: nil,
                isAnimated: false,
                source: content.source,
                thumbnailSource: content.info?.thumbnailSource,
                thumbnailInfo: content.info?.thumbnailInfo
            )

        case .audio(let content):
            return build(
                base: base,
                kind: content.voice != nil ? .voice : .audio,
                filename: content.filename,
                caption: content.caption,
                mimetype: content.info?.mimetype,
                sizeBytes: content.info?.size,
                pixelWidth: nil,
                pixelHeight: nil,
                durationSeconds: content.audio?.duration ?? content.info?.duration,
                blurhash: nil,
                isAnimated: false,
                source: content.source,
                thumbnailSource: nil,
                thumbnailInfo: nil
            )

        default:
            return nil
        }
    }

    private static func build(
        base: EventBase,
        kind: Kind,
        filename: String,
        caption: String?,
        mimetype: String?,
        sizeBytes: UInt64?,
        pixelWidth: UInt64?,
        pixelHeight: UInt64?,
        durationSeconds: TimeInterval?,
        blurhash: String?,
        isAnimated: Bool,
        source: MediaSource,
        thumbnailSource: MediaSource?,
        thumbnailInfo: ThumbnailInfo?
    ) -> AttachmentItem {
        let thumbnail = thumbnailSource.map { thumbnailSource in
            ThumbnailRef(
                source: thumbnailSource,
                mxc: thumbnailSource.url(),
                isEncrypted: thumbnailSource.isEncryptedSource,
                width: thumbnailInfo?.width.map { Int($0) },
                height: thumbnailInfo?.height.map { Int($0) },
                sizeBytes: thumbnailInfo?.size,
                mimetype: thumbnailInfo?.mimetype
            )
        }
        return AttachmentItem(
            id: base.id,
            uniqueId: base.uniqueId,
            kind: kind,
            timestampMs: base.timestampMs,
            sender: base.sender,
            senderName: base.senderName,
            isOwn: base.isOwn,
            filename: filename,
            caption: caption,
            mimetype: mimetype,
            sizeBytes: sizeBytes,
            pixelWidth: pixelWidth.map { Int($0) },
            pixelHeight: pixelHeight.map { Int($0) },
            durationSeconds: durationSeconds,
            blurhash: (blurhash?.isEmpty == false) ? blurhash : nil,
            isAnimated: isAnimated,
            source: source,
            sourceMxc: source.url(),
            isSourceEncrypted: source.isEncryptedSource,
            thumbnail: thumbnail
        )
    }
}

// MARK: - Undecrypted events

/// An `m.room.encrypted` event still waiting for its Megolm session. Its
/// msgtype is unknown until it decrypts, so it is counted, never rendered.
struct PendingDecryption: Equatable {
    let uniqueId: String
    let eventId: String?
    let sessionId: String?
    let timestampMs: UInt64
    let cause: String

    static func make(from event: EventTimelineItem, uniqueId: String) -> PendingDecryption? {
        guard case .msgLike(let msgLike) = event.content,
              case .unableToDecrypt(let encrypted) = msgLike.kind else {
            return nil
        }
        var sessionId: String?
        let cause: String
        switch encrypted {
        case .megolmV1AesSha2(let id, let utdCause):
            sessionId = id
            cause = String(describing: utdCause)
        case .olmV1Curve25519AesSha2:
            cause = "olm"
        case .unknown:
            cause = "unknown"
        }
        let eventId: String? = {
            if case .eventId(let id) = event.eventOrTransactionId {
                return id
            }
            return nil
        }()
        return PendingDecryption(
            uniqueId: uniqueId,
            eventId: eventId,
            sessionId: sessionId,
            timestampMs: event.timestamp,
            cause: cause
        )
    }
}

// MARK: - Grouping

struct AttachmentMonthGroup: Identifiable, Equatable {
    /// `yyyy-MM`
    let id: String
    let title: String
    let items: [AttachmentItem]
}
