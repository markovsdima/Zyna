//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import UIKit

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

    func addFileURLs(_ urls: [URL]) {
        guard availableSlots > 0 else { return }

        let drafts = urls
            .prefix(availableSlots)
            .map { buildFileDraft(from: $0) }

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

    func clearAttachments() {
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
}
