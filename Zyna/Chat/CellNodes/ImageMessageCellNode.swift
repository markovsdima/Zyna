//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class ImageMessageCellNode: MessageCellNode {

    // MARK: - Callbacks

    var onImageTapped: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onImageTapped?()
        return true
    }

    // MARK: - Subnodes

    private let imageNode = RoundedImageNode()
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
    private let usesDirectImageContent: Bool

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
        let usesAccentBubbleStyle = message.isOutgoing || message.zynaAttributes.color != nil
        if let captionText {
            let node = ASTextNode()
            node.attributedText = NSAttributedString(
                string: captionText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: usesAccentBubbleStyle
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
        if let width = imageWidth, let height = imageHeight, height > 0 {
            self.aspectRatio = CGFloat(width) / CGFloat(height)
            self.hasSDKDimensions = true
        } else {
            self.aspectRatio = 4.0 / 3.0
            self.hasSDKDimensions = false
        }
        let hasHeader = message.replyInfo != nil || message.zynaAttributes.forwardedFrom != nil
        let hasCaption = self.captionNode != nil
        self.usesDirectImageContent = !hasHeader && !hasCaption

        super.init(message: message, isGroupChat: isGroupChat)

        // Image — precomposited per-corner rounding via RoundedImageNode
        imageNode.radius = 18
        imageNode.imageContentMode = .scaleAspectFill

        var corners: UIRectCorner = .allCorners
        if hasHeader {
            corners.remove(.topLeft)
            corners.remove(.topRight)
        }
        if hasCaption {
            corners.remove(.bottomLeft)
            corners.remove(.bottomRight)
        }
        imageNode.roundedCorners = corners
        setShowsBubbleChrome(!usesDirectImageContent)
        setUsesBareBubbleContent(usesDirectImageContent)

        let buildImageWithTime: () -> ASLayoutSpec = { [weak self] in
            guard let self else { return ASLayoutSpec() }

            let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
            let imgHeight = maxWidth / self.aspectRatio

            self.imageNode.style.preferredSize = CGSize(
                width: maxWidth,
                height: min(imgHeight, MessageCellHelpers.maxImageBubbleHeight)
            )

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

            return ASOverlayLayoutSpec(child: self.imageNode, overlay: timeOverlay)
        }

        // Bubble layout
        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            let imageWithTime = buildImageWithTime()

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

        directBubbleContentNode.layoutSpecBlock = { _, _ in
            buildImageWithTime()
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
            let recipe = bubbleCacheRecipe()
            if let cached = MediaCache.shared.bubbleImage(
                for: source,
                maxPixelWidth: recipe.maxPixelWidth,
                maxPixelHeight: recipe.maxPixelHeight
            ) {
                imageNode.image = cached.image
                applyLoadedSourcePixelSize(cached.sourcePixelSize, relayout: false)
            } else {
                loadBubbleImageAsync(source: source)
            }
        }
    }

    // MARK: - Async Loading

    override func didLoad() {
        super.didLoad()
        assignProbeName("imageMessage.imageNode", to: imageNode)
        assignProbeName("imageMessage.timeBadge", to: timeBadgeNode)
        if let captionNode {
            assignProbeName("imageMessage.caption", to: captionNode)
        }
    }

    override func highlightBubble() {
        guard usesDirectImageContent else {
            super.highlightBubble()
            return
        }
        guard imageNode.isNodeLoaded else { return }

        let highlight = CAShapeLayer()
        highlight.frame = imageNode.bounds
        let path = UIBezierPath(
            roundedRect: imageNode.bounds,
            byRoundingCorners: imageNode.roundedCorners,
            cornerRadii: CGSize(width: imageNode.radius, height: imageNode.radius)
        )
        highlight.path = path.cgPath
        highlight.fillColor = bubbleForegroundColor.withAlphaComponent(0.3).cgColor
        highlight.opacity = 0
        imageNode.layer.addSublayer(highlight)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak highlight] in
            highlight?.removeFromSuperlayer()
        }

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 1, 1, 0]
        anim.keyTimes = [0, 0.2, 0.6, 1.0]
        anim.duration = 0.8
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        highlight.add(anim, forKey: "highlight")

        CATransaction.commit()
    }

    /// Fixed chat-bubble display recipe. The cache stores a bitmap
    /// already normalized to this width plus the shared max-height cap.
    private func bubbleCacheRecipe() -> (maxPixelWidth: Int, maxPixelHeight: Int) {
        let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        let scale = UIScreen.main.scale
        return (
            maxPixelWidth: Int(round(maxWidth * scale)),
            maxPixelHeight: Int(round(MessageCellHelpers.maxImageBubbleHeight * scale))
        )
    }

    private func loadBubbleImageAsync(source: MediaSource) {
        let recipe = bubbleCacheRecipe()
        let knownAspectRatio = hasSDKDimensions ? aspectRatio : nil
        Task { [weak self] in
            guard let self,
                  let bubbleImage = await MediaCache.shared.loadBubbleImage(
                    source: source,
                    maxPixelWidth: recipe.maxPixelWidth,
                    maxPixelHeight: recipe.maxPixelHeight,
                    knownAspectRatio: knownAspectRatio
                  ) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.imageNode.image = bubbleImage.image
                self.applyLoadedSourcePixelSize(bubbleImage.sourcePixelSize, relayout: true)
            }
        }
    }

    private func applyLoadedSourcePixelSize(_ sourcePixelSize: CGSize, relayout: Bool) {
        guard !hasSDKDimensions, sourcePixelSize.height > 0 else { return }

        let realRatio = sourcePixelSize.width / sourcePixelSize.height
        persistDimensions(sourcePixelSize)

        guard abs(realRatio - aspectRatio) > 0.01 else { return }
        aspectRatio = realRatio
        if relayout {
            setNeedsLayout()
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
