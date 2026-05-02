//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers

private let logVideoComposer = ScopedLog(.video, prefix: "[VideoComposer]")

struct ChatComposerState {
    var attachments: [ChatComposerAttachmentDraft] = []
    var photoGroupCaptionPlacement: CaptionPlacement = .bottom

    var hasAttachments: Bool {
        !attachments.isEmpty
    }

    var imageAttachments: [ChatComposerAttachmentDraft] {
        attachments.filter(\.isImage)
    }

    var fileAttachments: [ChatComposerAttachmentDraft] {
        attachments.filter { !$0.isImage }
    }
}

struct ChatComposerAttachmentDraft: Identifiable {
    enum Payload {
        case image(ProcessedImage)
        case video(ProcessedVideo)
        case file(URL)
    }

    let id: UUID
    let payload: Payload
    let previewImage: UIImage?
    let title: String
    let subtitle: String?
    let accessibilityLabel: String

    var isImage: Bool {
        if case .image = payload {
            return true
        }
        return false
    }

    func cleanupTemporaryResources() {
        switch payload {
        case .video(let video):
            Self.removeOwnedTemporaryDirectory(video.videoURL.deletingLastPathComponent())
        case .file(let url):
            Self.removeOwnedPickedTemporaryFile(url)
        case .image:
            break
        }
    }

    private static func removeOwnedTemporaryDirectory(_ url: URL) {
        let directory = url.standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent() == temporaryDirectory,
              directory.lastPathComponent.hasPrefix("zyna-video-")
        else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func removeOwnedPickedTemporaryFile(_ url: URL) {
        let fileURL = url.standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard fileURL.deletingLastPathComponent() == temporaryDirectory,
              fileURL.lastPathComponent.hasPrefix("zyna-picked-")
        else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    var isVideo: Bool {
        if case .video = payload {
            return true
        }
        return false
    }
}

enum ChatComposerMediaDraftInput {
    case imageData(Data)
    case videoURL(URL)
}

@MainActor
final class ChatComposerController: ObservableObject {
    @Published private(set) var state = ChatComposerState()

    private let maxAttachmentCount: Int

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    init(maxAttachmentCount: Int = 10) {
        self.maxAttachmentCount = maxAttachmentCount
    }

    static func byteCountString(for bytes: UInt64) -> String {
        byteCountFormatter.string(fromByteCount: Int64(bytes))
    }

    func addImageData(_ imageDataItems: [Data]) async {
        guard availableSlots > 0 else { return }

        var newDrafts: [ChatComposerAttachmentDraft] = []
        for data in imageDataItems.prefix(availableSlots) {
            guard let draft = await buildImageDraft(from: data) else { continue }
            newDrafts.append(draft)
        }

        state.attachments.append(contentsOf: newDrafts)
    }

    func addImages(_ images: [UIImage]) async {
        guard availableSlots > 0 else { return }

        var newDrafts: [ChatComposerAttachmentDraft] = []
        for image in images.prefix(availableSlots) {
            guard let draft = await buildImageDraft(from: image) else { continue }
            newDrafts.append(draft)
        }

        state.attachments.append(contentsOf: newDrafts)
    }

    func addMediaItems(_ items: [ChatComposerMediaDraftInput]) async {
        guard availableSlots > 0 else { return }
        logVideoComposer("addMediaItems count=\(items.count) availableSlots=\(availableSlots)")

        var newDrafts: [ChatComposerAttachmentDraft] = []
        for item in items.prefix(availableSlots) {
            switch item {
            case .imageData(let data):
                guard let draft = await buildImageDraft(from: data) else { continue }
                newDrafts.append(draft)
            case .videoURL(let url):
                if let draft = await buildVideoDraft(from: url) {
                    newDrafts.append(draft)
                } else {
                    logVideoComposer("video fallbackToFile url=\(url.lastPathComponent)")
                    newDrafts.append(buildFileDraft(from: url))
                }
            }
        }

        state.attachments.append(contentsOf: newDrafts)
    }

    func addVideoURLs(_ urls: [URL]) async {
        guard availableSlots > 0 else { return }
        logVideoComposer("addVideoURLs count=\(urls.count) availableSlots=\(availableSlots)")

        var newDrafts: [ChatComposerAttachmentDraft] = []
        for url in urls.prefix(availableSlots) {
            if let draft = await buildVideoDraft(from: url) {
                newDrafts.append(draft)
            } else {
                logVideoComposer("video fallbackToFile url=\(url.lastPathComponent)")
                newDrafts.append(buildFileDraft(from: url))
            }
        }

        state.attachments.append(contentsOf: newDrafts)
    }

    func addFileURLs(_ urls: [URL]) async {
        guard availableSlots > 0 else { return }
        logVideoComposer("addFileURLs count=\(urls.count) availableSlots=\(availableSlots)")

        var drafts: [ChatComposerAttachmentDraft] = []
        for url in urls.prefix(availableSlots) {
            if Self.isVideoURL(url), let draft = await buildVideoDraft(from: url) {
                drafts.append(draft)
            } else {
                drafts.append(buildFileDraft(from: url))
            }
        }

        state.attachments.append(contentsOf: drafts)
    }

    func addFileURL(
        _ url: URL,
        previewImage: UIImage? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        accessibilityLabel: String? = nil
    ) {
        guard availableSlots > 0 else { return }
        state.attachments.append(buildFileDraft(
            from: url,
            previewImage: previewImage,
            title: title,
            subtitle: subtitle,
            accessibilityLabel: accessibilityLabel
        ))
    }

    func clearAttachments(preservingTemporaryResourcesFor preservedAttachmentIDs: Set<UUID> = []) {
        for attachment in state.attachments where !preservedAttachmentIDs.contains(attachment.id) {
            attachment.cleanupTemporaryResources()
        }
        state.attachments.removeAll()
        state.photoGroupCaptionPlacement = .bottom
    }

    private var availableSlots: Int {
        max(0, maxAttachmentCount - state.attachments.count)
    }

    private func buildImageDraft(from data: Data) async -> ChatComposerAttachmentDraft? {
        guard let processed = try? await MediaPreprocessor.processImage(from: data),
              let previewImage = UIImage(data: processed.imageData) else {
            return nil
        }

        return makeImageDraft(processed: processed, previewImage: previewImage)
    }

    private func buildImageDraft(from image: UIImage) async -> ChatComposerAttachmentDraft? {
        guard let processed = try? await MediaPreprocessor.processImage(from: image),
              let previewImage = UIImage(data: processed.imageData) else {
            return nil
        }

        return makeImageDraft(processed: processed, previewImage: previewImage)
    }

    private func makeImageDraft(
        processed: ProcessedImage,
        previewImage: UIImage
    ) -> ChatComposerAttachmentDraft {
        let dimensions = "\(processed.width)\u{00D7}\(processed.height)"
        return ChatComposerAttachmentDraft(
            id: UUID(),
            payload: .image(processed),
            previewImage: previewImage,
            title: "Photo",
            subtitle: dimensions,
            accessibilityLabel: "Photo attachment, \(dimensions)"
        )
    }

    private func buildVideoDraft(from url: URL) async -> ChatComposerAttachmentDraft? {
        logVideoComposer("video draft start url=\(url.lastPathComponent)")
        let processed: ProcessedVideo
        do {
            processed = try await MediaPreprocessor.processVideo(from: url)
        } catch {
            logVideoComposer(
                "video draft preprocess failed url=\(url.lastPathComponent) errorType=\(String(describing: type(of: error))) error=\(error)"
            )
            return nil
        }

        guard let previewImage = UIImage(data: processed.thumbnailData) else {
            logVideoComposer(
                "video draft thumbnail decode failed output=\(processed.filename) thumbBytes=\(processed.thumbnailSize)"
            )
            return nil
        }
        Self.removePickedTemporaryVideoIfNeeded(url)

        let subtitleParts = [
            MediaDurationFormatter.shortString(for: processed.duration),
            Self.byteCountFormatter.string(fromByteCount: Int64(processed.size))
        ]

        let draft = ChatComposerAttachmentDraft(
            id: UUID(),
            payload: .video(processed),
            previewImage: previewImage,
            title: processed.filename,
            subtitle: subtitleParts.joined(separator: " · "),
            accessibilityLabel: "Video attachment, \(processed.filename)"
        )
        logVideoComposer(
            "video draft ready output=\(processed.filename) bytes=\(processed.size) size=\(processed.width)x\(processed.height) duration=\(MediaDurationFormatter.shortString(for: processed.duration))"
        )
        return draft
    }

    private func buildFileDraft(
        from url: URL,
        previewImage: UIImage? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        accessibilityLabel: String? = nil
    ) -> ChatComposerAttachmentDraft {
        let size = (try? FileManager.default.attributesOfItem(
            atPath: url.path
        )[.size] as? UInt64) ?? 0

        return ChatComposerAttachmentDraft(
            id: UUID(),
            payload: .file(url),
            previewImage: previewImage,
            title: title ?? url.lastPathComponent,
            subtitle: subtitle ?? Self.byteCountFormatter.string(fromByteCount: Int64(size)),
            accessibilityLabel: accessibilityLabel ?? "File attachment, \(url.lastPathComponent)"
        )
    }

    private static func isVideoURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private static func removePickedTemporaryVideoIfNeeded(_ url: URL) {
        guard url.deletingLastPathComponent() == FileManager.default.temporaryDirectory,
              url.lastPathComponent.hasPrefix("zyna-picked-")
        else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}
