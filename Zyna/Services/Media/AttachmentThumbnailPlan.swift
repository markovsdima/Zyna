//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import MatrixRustSDK

/// Which SDK call fetches the bytes for a tile.
///
/// The SDK caches under `<mxc>_file` for `getMediaContent` and
/// `<mxc>_scale_WxH` for `getMediaThumbnail`; `bytesKey` mirrors that so
/// in-flight de-duplication lines up with cache rows. For an encrypted
/// source the thumbnail variant would download the full file anyway
/// (`crates/matrix-sdk/src/media.rs`, `MediaSource::Encrypted` arm), so
/// `AttachmentThumbnailPlan` never produces it for encrypted media.
enum AttachmentFetchRequest {
    case serverThumbnail(source: MediaSource, width: UInt64, height: UInt64)
    case fullContent(source: MediaSource)

    var source: MediaSource {
        switch self {
        case .serverThumbnail(let source, _, _): return source
        case .fullContent(let source): return source
        }
    }

    var mxc: String { source.url() }

    /// Same shape as the SDK's `MediaFormat::unique_key`.
    var sdkKeyTag: String {
        switch self {
        case .serverThumbnail(_, let width, let height): return "scale_\(width)x\(height)"
        case .fullContent: return "file"
        }
    }

    var bytesKey: String { "\(mxc)|\(sdkKeyTag)" }

    var label: String {
        switch self {
        case .serverThumbnail(_, let width, let height): return "thumbnail(\(width)x\(height))"
        case .fullContent: return "content"
        }
    }
}

extension AttachmentFetchRequest: Hashable {
    static func == (lhs: AttachmentFetchRequest, rhs: AttachmentFetchRequest) -> Bool {
        lhs.bytesKey == rhs.bytesKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bytesKey)
    }
}

/// Which gate a fetch queues behind. Originals of several MB must not hold
/// the slots that dozens of 30–100 KB thumbnail files wait for; user-driven
/// viewer loads bypass the grid's gates entirely.
enum AttachmentFetchLane {
    case thumbnail
    case original
    case interactive
}

struct AttachmentFetchStats: Equatable {
    /// `sdk` means this call went into the SDK; whether the SDK served it from
    /// its own SQLite cache or the network is not visible through the FFI.
    /// `coalesced` means another in-flight fetch was joined: no SDK call was
    /// made on this consumer's behalf, so its bytes must not be counted.
    enum Tier: String {
        case memory
        case disk
        case sdk
        case coalesced
    }

    let tier: Tier
    let bytes: Int
    /// Time spent waiting for a network-gate permit; under load this
    /// dominates and says nothing about the SDK or the network.
    let queueMs: Double
    /// The SDK call itself (cache or network, indistinguishable here).
    let fetchMs: Double
    let prepareMs: Double
    let request: String

    var coalesced: AttachmentFetchStats {
        AttachmentFetchStats(tier: .coalesced, bytes: 0, queueMs: 0, fetchMs: 0, prepareMs: 0, request: request)
    }
}

struct AttachmentThumbnail {
    let image: UIImage
    let sourcePixelSize: CGSize
    let stats: AttachmentFetchStats
}

/// The single place that decides how a tile gets its preview.
enum AttachmentThumbnailPlan: Hashable {

    enum FetchReason: String {
        case plainServerThumbnail
        case encryptedThumbnailFile
        case encryptedFullFile
    }

    enum DeferReason: String {
        case tooLarge
        case unknownSize
        case videoWithoutThumbnail
        case nonVisual
    }

    case fetch(AttachmentFetchRequest, reason: FetchReason)
    case deferred(DeferReason)

    /// Encrypted originals without a sender thumbnail are fetched
    /// automatically only under this size. 2 MiB covers photos re-encoded
    /// by Element; larger ones (4–7 MB originals measured at 11–65 s on a
    /// slow link) wait for a tap. `info.size` is sender-declared, so this
    /// is a policy, not a traffic guarantee — the SDK has no size-capped
    /// download.
    static let defaultFullFileThreshold: UInt64 = 2 * 1024 * 1024

    var request: AttachmentFetchRequest? {
        if case .fetch(let request, _) = self { return request }
        return nil
    }

    var lane: AttachmentFetchLane {
        if case .fetch(_, let reason) = self, reason == .encryptedFullFile { return .original }
        return .thumbnail
    }

    var isTapToLoad: Bool {
        switch self {
        case .deferred(.tooLarge), .deferred(.unknownSize): return true
        default: return false
        }
    }

    /// Rules:
    /// 1. Non-visual kinds get an icon, never bytes.
    /// 2. A sender-provided thumbnail wins: encrypted → full content of that
    ///    small file; plain → server-side thumbnail at tile size.
    /// 3. Plain image without thumbnail → server-side thumbnail.
    /// 4. Video without thumbnail → blurhash only. Video bytes are never
    ///    downloaded for a preview, and server-side video thumbnails are not
    ///    requested either: Synapse does not produce them and a failed
    ///    request per tile is worse than a placeholder. Other homeservers
    ///    may; verify against ours before relaxing this for plain video.
    /// 5. Encrypted image without thumbnail → the full original, but only
    ///    under `fullFileThreshold` or on explicit request.
    static func make(
        for item: AttachmentItem,
        tilePixelSize: Int,
        fullFileThreshold: UInt64 = defaultFullFileThreshold,
        forceLoad: Bool = false
    ) -> AttachmentThumbnailPlan {
        guard item.kind.isVisual else { return .deferred(.nonVisual) }
        let tile = UInt64(max(1, tilePixelSize))

        if let thumbnail = item.thumbnail {
            if thumbnail.isEncrypted {
                return .fetch(.fullContent(source: thumbnail.source), reason: .encryptedThumbnailFile)
            }
            return .fetch(
                .serverThumbnail(source: thumbnail.source, width: tile, height: tile),
                reason: .plainServerThumbnail
            )
        }

        guard item.kind == .image else { return .deferred(.videoWithoutThumbnail) }

        if !item.isSourceEncrypted {
            return .fetch(
                .serverThumbnail(source: item.source, width: tile, height: tile),
                reason: .plainServerThumbnail
            )
        }

        if forceLoad {
            return .fetch(.fullContent(source: item.source), reason: .encryptedFullFile)
        }
        guard let sizeBytes = item.sizeBytes else { return .deferred(.unknownSize) }
        if sizeBytes <= fullFileThreshold {
            return .fetch(.fullContent(source: item.source), reason: .encryptedFullFile)
        }
        return .deferred(.tooLarge)
    }
}
