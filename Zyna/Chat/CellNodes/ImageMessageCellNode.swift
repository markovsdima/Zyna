//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class ImageMessageCellNode: MessageCellNode {

    // MARK: - Callbacks

    var onImageTapped: (() -> Void)?

    // MARK: - Subnodes

    private let imageNode = ASImageNode()
    private let timeBadgeNode = ASDisplayNode()

    /// Current thumbnail for the viewer transition.
    var currentImage: UIImage? { imageNode.image }

    /// The backing UIView of the image node, for frame conversion.
    var imageNodeView: UIView { imageNode.view }

    // MARK: - State

    private var aspectRatio: CGFloat
    private let mediaSource: MediaSource?
    private let hasSDKDimensions: Bool
    private let messageId: String

    // MARK: - Init

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        var source: MediaSource?
        var imageWidth: UInt64?
        var imageHeight: UInt64?

        if case .image(let src, let width, let height, _) = message.content {
            source = src
            imageWidth = width
            imageHeight = height
        }

        self.mediaSource = source
        self.messageId = message.id

        if let width = imageWidth, let height = imageHeight, height > 0 {
            self.aspectRatio = CGFloat(width) / CGFloat(height)
            self.hasSDKDimensions = true
        } else {
            self.aspectRatio = 4.0 / 3.0
            self.hasSDKDimensions = false
        }

        super.init(message: message, isGroupChat: isGroupChat)

        // Image
        imageNode.contentMode = .scaleAspectFill
        imageNode.cornerRadius = 18
        imageNode.clipsToBounds = true
        imageNode.displaysAsynchronously = true

        // Bubble layout
        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
            let imgHeight = maxWidth / self.aspectRatio

            self.imageNode.style.preferredSize = CGSize(width: maxWidth, height: min(imgHeight, 400))

            let timePadded = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6),
                child: self.timeNode
            )
            let timeBadge = ASBackgroundLayoutSpec(child: timePadded, background: self.timeBadgeNode)

            let timeOverlay = ASRelativeLayoutSpec(
                horizontalPosition: .end,
                verticalPosition: .end,
                sizingOption: .minimumSize,
                child: ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 8),
                    child: timeBadge
                )
            )

            let imageWithTime = ASOverlayLayoutSpec(child: self.imageNode, overlay: timeOverlay)

            if let replyHeader = self.replyHeaderNode {
                let replyInset = ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 7, left: 12, bottom: 4, right: 12),
                    child: replyHeader
                )
                return ASStackLayoutSpec(
                    direction: .vertical,
                    spacing: 0,
                    justifyContent: .start,
                    alignItems: .stretch,
                    children: [replyInset, imageWithTime]
                )
            }

            return imageWithTime
        }

        // Time badge
        timeBadgeNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        timeBadgeNode.cornerRadius = 8

        // Override timestamp color — always white on dark badge
        timeNode.attributedText = NSAttributedString(
            string: MessageCellHelpers.timeFormatter.string(from: message.timestamp),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.white
            ]
        )

        // Tap to open viewer
        contextSourceNode.onQuickTap = { [weak self] _ in
            self?.onImageTapped?()
        }

        // Load image
        if let source = mediaSource {
            if let cached = MediaCache.shared.image(for: source) {
                imageNode.image = cached
                if !hasSDKDimensions, cached.size.height > 0 {
                    aspectRatio = cached.size.width / cached.size.height
                    persistDimensions(cached.size)
                }
            } else {
                loadThumbnailAsync(source: source)
            }
        }
    }

    // MARK: - Async Loading

    private func loadThumbnailAsync(source: MediaSource) {
        let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        let scale = UIScreen.main.scale

        // When SDK didn't provide dimensions, request a large
        // square thumbnail so the server returns the image at its
        // natural aspect ratio. Otherwise request the exact size.
        let thumbWidth: UInt64
        let thumbHeight: UInt64
        if hasSDKDimensions {
            thumbWidth = UInt64(maxWidth * scale)
            thumbHeight = UInt64(maxWidth / aspectRatio * scale)
        } else {
            let dim = UInt64(maxWidth * scale)
            thumbWidth = dim
            thumbHeight = dim
        }

        Task { [weak self] in
            guard let self,
                  let image = await MediaCache.shared.loadThumbnail(
                    source: source,
                    width: thumbWidth,
                    height: thumbHeight
                  ) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.imageNode.image = image
                if !self.hasSDKDimensions, image.size.height > 0 {
                    let realRatio = image.size.width / image.size.height
                    if abs(realRatio - self.aspectRatio) > 0.01 {
                        self.aspectRatio = realRatio
                        self.persistDimensions(image.size)
                        self.setNeedsLayout()
                    }
                }
            }
        }
    }

    /// Write discovered dimensions to GRDB so next time the cell
    /// is created it gets the correct ratio from the database
    /// without waiting for the image to load.
    private func persistDimensions(_ size: CGSize) {
        let id = messageId
        let w = Int64(size.width)
        let h = Int64(size.height)
        DispatchQueue.global(qos: .utility).async {
            try? DatabaseService.shared.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE storedMessage SET contentImageWidth = ?, contentImageHeight = ? WHERE id = ?",
                    arguments: [w, h, id]
                )
            }
        }
    }
}
