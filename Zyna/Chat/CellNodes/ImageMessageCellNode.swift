//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class ImageMessageCellNode: MessageCellNode {

    // MARK: - Subnodes

    private let imageNode = ASImageNode()
    private let timeBadgeNode = ASDisplayNode()

    // MARK: - State

    private let aspectRatio: CGFloat
    private let mediaSource: MediaSource?

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

        if let width = imageWidth, let height = imageHeight, height > 0 {
            self.aspectRatio = CGFloat(width) / CGFloat(height)
        } else {
            self.aspectRatio = 4.0 / 3.0
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

        // Load image
        if let source = mediaSource {
            if let cached = MediaCache.shared.image(for: source) {
                imageNode.image = cached
            } else {
                loadThumbnailAsync(source: source)
            }
        }
    }

    // MARK: - Async Loading

    private func loadThumbnailAsync(source: MediaSource) {
        let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        let thumbWidth = UInt64(maxWidth * UIScreen.main.scale)
        let thumbHeight = UInt64(maxWidth / aspectRatio * UIScreen.main.scale)

        Task { [weak self] in
            guard let image = await MediaCache.shared.loadThumbnail(
                source: source,
                width: thumbWidth,
                height: thumbHeight
            ) else { return }
            await MainActor.run { [weak self] in
                self?.imageNode.image = image
            }
        }
    }
}
