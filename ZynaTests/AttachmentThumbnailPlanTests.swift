//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import Foundation
import MatrixRustSDK
@testable import Zyna

@Suite("AttachmentThumbnailPlan")
struct AttachmentThumbnailPlanTests {

    private func source(_ mxc: String) throws -> MediaSource {
        try MediaSource.fromUrl(url: mxc)
    }

    private func item(
        kind: AttachmentItem.Kind,
        encrypted: Bool,
        sizeBytes: UInt64?,
        thumbnailEncrypted: Bool? = nil
    ) throws -> AttachmentItem {
        let thumbnail: AttachmentItem.ThumbnailRef? = try thumbnailEncrypted.map { isEncrypted in
            AttachmentItem.ThumbnailRef(
                source: try source("mxc://example.org/thumb"),
                mxc: "mxc://example.org/thumb",
                isEncrypted: isEncrypted,
                width: 800,
                height: 600,
                sizeBytes: 90_000,
                mimetype: "image/jpeg"
            )
        }
        return AttachmentItem(
            id: "$event",
            uniqueId: "u1",
            kind: kind,
            timestampMs: 1_700_000_000_000,
            sender: "@alice:example.org",
            senderName: "Alice",
            isOwn: false,
            filename: "file.jpg",
            caption: nil,
            mimetype: "image/jpeg",
            sizeBytes: sizeBytes,
            pixelWidth: 4000,
            pixelHeight: 3000,
            durationSeconds: nil,
            blurhash: nil,
            isAnimated: false,
            source: try source("mxc://example.org/full"),
            sourceMxc: "mxc://example.org/full",
            isSourceEncrypted: encrypted,
            thumbnail: thumbnail
        )
    }

    @Test("Plain image without thumbnail uses the server thumbnail")
    func plainImage() throws {
        let plan = AttachmentThumbnailPlan.make(for: try item(kind: .image, encrypted: false, sizeBytes: 1_000_000), tilePixelSize: 384)
        guard case .fetch(let request, let reason) = plan else {
            Issue.record("expected fetch, got \(plan)")
            return
        }
        #expect(reason == .plainServerThumbnail)
        #expect(request.sdkKeyTag == "scale_384x384")
        #expect(request.mxc == "mxc://example.org/full")
    }

    @Test("Encrypted thumbnail file is fetched as full content of the thumbnail")
    func encryptedThumbnail() throws {
        let plan = AttachmentThumbnailPlan.make(
            for: try item(kind: .image, encrypted: true, sizeBytes: 9_000_000, thumbnailEncrypted: true),
            tilePixelSize: 384
        )
        guard case .fetch(let request, let reason) = plan else {
            Issue.record("expected fetch, got \(plan)")
            return
        }
        #expect(reason == .encryptedThumbnailFile)
        #expect(request.sdkKeyTag == "file")
        #expect(request.mxc == "mxc://example.org/thumb")
    }

    @Test("Plain thumbnail on an encrypted event still uses the server")
    func plainThumbnailOnEncryptedEvent() throws {
        let plan = AttachmentThumbnailPlan.make(
            for: try item(kind: .image, encrypted: true, sizeBytes: nil, thumbnailEncrypted: false),
            tilePixelSize: 384
        )
        guard case .fetch(let request, let reason) = plan else {
            Issue.record("expected fetch, got \(plan)")
            return
        }
        #expect(reason == .plainServerThumbnail)
        #expect(request.mxc == "mxc://example.org/thumb")
    }

    @Test("Encrypted image without thumbnail respects the size threshold")
    func encryptedFullFileThreshold() throws {
        let small = AttachmentThumbnailPlan.make(
            for: try item(kind: .image, encrypted: true, sizeBytes: 1_000_000),
            tilePixelSize: 384,
            fullFileThreshold: 8 * 1024 * 1024
        )
        guard case .fetch(let request, let reason) = small else {
            Issue.record("expected fetch, got \(small)")
            return
        }
        #expect(reason == .encryptedFullFile)
        #expect(request.sdkKeyTag == "file")

        let large = AttachmentThumbnailPlan.make(
            for: try item(kind: .image, encrypted: true, sizeBytes: 20 * 1024 * 1024),
            tilePixelSize: 384,
            fullFileThreshold: 8 * 1024 * 1024
        )
        #expect(large == .deferred(.tooLarge))
        #expect(large.isTapToLoad)

        let forced = AttachmentThumbnailPlan.make(
            for: try item(kind: .image, encrypted: true, sizeBytes: 20 * 1024 * 1024),
            tilePixelSize: 384,
            fullFileThreshold: 8 * 1024 * 1024,
            forceLoad: true
        )
        #expect(forced.request?.sdkKeyTag == "file")

        let unknown = AttachmentThumbnailPlan.make(
            for: try item(kind: .image, encrypted: true, sizeBytes: nil),
            tilePixelSize: 384
        )
        #expect(unknown == .deferred(.unknownSize))
    }

    @Test("Video without thumbnail never downloads video bytes")
    func videoWithoutThumbnail() throws {
        let encrypted = AttachmentThumbnailPlan.make(
            for: try item(kind: .video, encrypted: true, sizeBytes: 100), tilePixelSize: 384
        )
        let plain = AttachmentThumbnailPlan.make(
            for: try item(kind: .video, encrypted: false, sizeBytes: 100), tilePixelSize: 384
        )
        #expect(encrypted == .deferred(.videoWithoutThumbnail))
        #expect(plain == .deferred(.videoWithoutThumbnail))
    }

    @Test("Non-visual kinds are deferred")
    func nonVisual() throws {
        for kind in [AttachmentItem.Kind.file, .audio, .voice] {
            #expect(AttachmentThumbnailPlan.make(for: try item(kind: kind, encrypted: true, sizeBytes: 10), tilePixelSize: 384) == .deferred(.nonVisual))
        }
    }

    @Test("Fetch requests compare by mxc and SDK key")
    func requestIdentity() throws {
        let full = AttachmentFetchRequest.fullContent(source: try source("mxc://example.org/a"))
        let sameFull = AttachmentFetchRequest.fullContent(source: try source("mxc://example.org/a"))
        let thumb = AttachmentFetchRequest.serverThumbnail(source: try source("mxc://example.org/a"), width: 64, height: 64)
        #expect(full == sameFull)
        #expect(full != thumb)
        #expect(full.bytesKey == "mxc://example.org/a|file")
        #expect(thumb.bytesKey == "mxc://example.org/a|scale_64x64")
    }
}
