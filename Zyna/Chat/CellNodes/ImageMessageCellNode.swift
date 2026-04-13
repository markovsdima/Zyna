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
    private let captionNode: ASTextNode?

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
        var captionText: String?

        if case .image(let src, let width, let height, let caption) = message.content {
            source = src
            imageWidth = width
            imageHeight = height
            // Filter zero-width caption (carrier for Zyna span)
            if let c = caption {
                let visible = c.replacingOccurrences(of: "\u{200B}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !visible.isEmpty { captionText = visible }
            }
        }

        // Caption node
        if let captionText {
            let node = ASTextNode()
            node.attributedText = NSAttributedString(
                string: captionText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: message.isOutgoing
                        ? AppColor.bubbleForegroundOutgoing
                        : AppColor.bubbleForegroundIncoming
                ]
            )
            node.maximumNumberOfLines = 0
            self.captionNode = node
        } else {
            self.captionNode = nil
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

        // Flatten image corners adjacent to header/caption so
        // the photo fills the bubble edge-to-edge on those sides.
        let hasHeader = forwardedHeaderNode != nil || replyHeaderNode != nil
        let hasCaption = captionNode != nil
        if hasHeader || hasCaption {
            imageNode.onDidLoad { node in
                var corners: CACornerMask = []
                if !hasHeader {
                    corners.insert(.layerMinXMinYCorner)
                    corners.insert(.layerMaxXMinYCorner)
                }
                if !hasCaption {
                    corners.insert(.layerMinXMaxYCorner)
                    corners.insert(.layerMaxXMaxYCorner)
                }
                node.layer.maskedCorners = corners
            }
        }

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

            var headerChildren: [ASLayoutElement] = []
            if let fwd = self.forwardedHeaderNode {
                headerChildren.append(ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 7, left: 12, bottom: 2, right: 12),
                    child: fwd
                ))
            }
            if let replyHeader = self.replyHeaderNode {
                headerChildren.append(ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 7, left: 12, bottom: 4, right: 12),
                    child: replyHeader
                ))
            }

            // Build vertical stack: [headers] + image + [caption]
            var stackChildren: [ASLayoutElement] = headerChildren
            stackChildren.append(imageWithTime)

            if let captionNode = self.captionNode {
                stackChildren.append(ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12),
                    child: captionNode
                ))
            }

            if stackChildren.count > 1 {
                return ASStackLayoutSpec(
                    direction: .vertical,
                    spacing: 0,
                    justifyContent: .start,
                    alignItems: .stretch,
                    children: stackChildren
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

        // Tap to open viewer (preserving reply header tap from super)
        contextSourceNode.onQuickTap = { [weak self] point in
            guard let self else { return }
            if self.isNodeLoaded,
               let replyView = self.replyHeaderNode?.view {
                let converted = self.contextSourceNode.view.convert(point, to: replyView)
                if replyView.bounds.contains(converted) {
                    self.onReplyHeaderTapped?(message.replyInfo?.eventId ?? "")
                    return
                }
            }
            self.onImageTapped?()
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
