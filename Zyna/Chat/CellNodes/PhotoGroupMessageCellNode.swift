//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class PhotoGroupMessageCellNode: MessageCellNode {

    var onPhotoTapped: ((Int) -> Void)?

    private var mediaItems: [MediaGroupItem]
    private let mediaContainerNode = ASDisplayNode()
    private let imageNodes: [RoundedImageNode]
    private let timeBadgeNode = ASDisplayNode()
    private let overflowNode = ASDisplayNode()
    private let overflowTextNode = ASTextNode()
    private let captionNode: ASTextNode?
    private var captionPlacement: CaptionPlacement?
    private let hasHeader: Bool
    private let mediaLayoutBounds: CGRect
    private let mediaHeight: CGFloat
    private var slotFrames: [CGRect] = []
    private var displayedSourceURLs: [String?]

    private var visibleItemCount: Int {
        PhotoGroupLayout.visibleItemCount(for: mediaItems.count)
    }

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        let presentation = message.mediaGroupPresentation
        let mediaItems = presentation?.items ?? []
        self.mediaItems = mediaItems
        self.hasHeader = message.replyInfo != nil || message.zynaAttributes.forwardedFrom != nil

        let captionText = presentation?.caption
        if let captionText {
            let node = ASTextNode()
            node.attributedText = NSAttributedString(
                string: captionText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: message.isOutgoing || message.zynaAttributes.color != nil
                        ? AppColor.bubbleForegroundOutgoing
                        : AppColor.bubbleForegroundIncoming
                ]
            )
            node.maximumNumberOfLines = 0
            self.captionNode = node
        } else {
            self.captionNode = nil
        }
        self.captionPlacement = captionText == nil ? nil : presentation?.captionPlacement

        let primaryAspectRatio: CGFloat? = {
            guard let first = mediaItems.first,
                  let width = first.width,
                  let height = first.height,
                  height > 0 else {
                return nil
            }
            return CGFloat(width) / CGFloat(height)
        }()

        let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        self.mediaHeight = PhotoGroupLayout.preferredMediaHeight(
            for: maxWidth,
            itemCount: mediaItems.count,
            primaryAspectRatio: primaryAspectRatio
        )
        self.mediaLayoutBounds = CGRect(x: 0, y: 0, width: maxWidth, height: mediaHeight)

        self.imageNodes = (0..<PhotoGroupLayout.maxVisibleItems).map { _ in
            let node = RoundedImageNode()
            node.radius = MessageCellHelpers.mediaBubbleCornerRadius
            node.imageContentMode = .scaleAspectFill
            return node
        }
        self.displayedSourceURLs = Array(repeating: nil, count: PhotoGroupLayout.maxVisibleItems)

        super.init(message: message, isGroupChat: isGroupChat)

        mediaContainerNode.clipsToBounds = false
        imageNodes.forEach(mediaContainerNode.addSubnode)
        overflowNode.backgroundColor = UIColor.black.withAlphaComponent(0.38)
        overflowNode.cornerRadius = MessageCellHelpers.mediaBubbleCornerRadius
        overflowNode.addSubnode(overflowTextNode)
        mediaContainerNode.addSubnode(overflowNode)

        timeBadgeNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        timeBadgeNode.cornerRadius = 8
        timeNode.attributedText = NSAttributedString(
            string: MessageCellHelpers.timeFormatter.string(from: message.timestamp),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.white
            ]
        )

        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }

            self.mediaContainerNode.style.preferredSize = CGSize(
                width: maxWidth,
                height: self.mediaHeight
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
            let mediaWithTime = ASOverlayLayoutSpec(child: self.mediaContainerNode, overlay: timeOverlay)

            var children: [ASLayoutElement] = []
            if let fwd = self.forwardedHeaderNode {
                children.append(ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 7, left: 12, bottom: 2, right: 12),
                    child: fwd
                ))
            }
            if let replyHeader = self.replyHeaderNode {
                children.append(ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 7, left: 12, bottom: 4, right: 12),
                    child: replyHeader
                ))
            }

            let captionInset = self.captionNode.map { captionNode in
                ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12),
                    child: captionNode
                )
            }

            if let captionInset, self.captionPlacement == .top {
                children.append(captionInset)
            }

            children.append(mediaWithTime)

            if let captionInset, self.captionPlacement != .top {
                children.append(captionInset)
            }

            return ASStackLayoutSpec(
                direction: .vertical,
                spacing: 0,
                justifyContent: .start,
                alignItems: .stretch,
                children: children
            )
        }

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

            if let tappedIndex = self.mediaIndex(at: point) {
                self.onPhotoTapped?(tappedIndex)
            }
        }

        loadImages()
    }

    override func layout() {
        super.layout()

        slotFrames = PhotoGroupLayout.frames(
            in: mediaLayoutBounds,
            itemCount: mediaItems.count
        )

        for (index, imageNode) in imageNodes.enumerated() {
            guard index < slotFrames.count else {
                imageNode.frame = .zero
                continue
            }
            let previousFrame = imageNode.frame
            imageNode.frame = slotFrames[index]
            imageNode.roundedCorners = PhotoGroupLayout.roundedCorners(
                for: index,
                itemCount: mediaItems.count,
                hasHeader: hasHeader,
                captionPlacement: captionNode == nil ? nil : captionPlacement
            )
            if imageNode.image != nil, previousFrame != imageNode.frame {
                imageNode.setNeedsDisplay()
            }
        }

        let overflowCount = mediaItems.count - visibleItemCount
        if overflowCount > 0, let lastFrame = slotFrames.last {
            overflowNode.isHidden = false
            overflowNode.frame = lastFrame
            overflowTextNode.attributedText = NSAttributedString(
                string: "+\(overflowCount)",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
            let textSize = overflowTextNode.calculateSizeThatFits(
                CGSize(width: lastFrame.width, height: lastFrame.height)
            )
            overflowTextNode.frame = CGRect(
                x: floor((lastFrame.width - textSize.width) / 2),
                y: floor((lastFrame.height - textSize.height) / 2),
                width: textSize.width,
                height: textSize.height
            )
        } else {
            overflowNode.isHidden = true
            overflowNode.frame = .zero
        }
    }

    func currentImage(at index: Int) -> UIImage? {
        guard index < imageNodes.count else { return nil }
        return imageNodes[index].image
    }

    override func didLoad() {
        super.didLoad()
        imageNodes.forEach { $0.setNeedsDisplay() }
        mediaContainerNode.setNeedsLayout()
        setNeedsLayout()
    }

    func mediaSource(at index: Int) -> MediaSource? {
        guard mediaItems.indices.contains(index) else { return nil }
        return mediaItems[index].source
    }

    func updateMediaGroupPresentation(_ presentation: MediaGroupPresentation?) {
        guard let presentation,
              presentation.rendersCompositeBubble else { return }

        mediaItems = presentation.items
        captionPlacement = presentation.captionPlacement
        if let captionNode {
            let captionText = presentation.caption ?? ""
            let foregroundColor = usesAccentBubbleStyle
                ? AppColor.bubbleForegroundOutgoing
                : AppColor.bubbleForegroundIncoming
            captionNode.attributedText = NSAttributedString(
                string: captionText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: foregroundColor
                ]
            )
        }
        loadImages()
        mediaContainerNode.setNeedsLayout()
        setNeedsLayout()
    }

    func imageFrameInWindow(at index: Int) -> CGRect? {
        guard mediaContainerNode.isNodeLoaded,
              index < slotFrames.count else { return nil }
        return mediaContainerNode.view.convert(slotFrames[index], to: nil)
    }

    private func mediaIndex(at point: CGPoint) -> Int? {
        guard mediaContainerNode.isNodeLoaded else { return nil }
        let converted = contextSourceNode.view.convert(point, to: mediaContainerNode.view)
        return slotFrames.firstIndex(where: { $0.contains(converted) })
    }

    private func loadImages() {
        let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        let scale = UIScreen.main.scale
        let maxPixelWidth = Int(round(maxWidth * scale))
        let maxPixelHeight = Int(round(mediaHeight * scale))

        for (index, item) in mediaItems.prefix(visibleItemCount).enumerated() {
            let sourceURL = item.source.url()
            let knownAspectRatio: CGFloat?
            if let width = item.width, let height = item.height, height > 0 {
                knownAspectRatio = CGFloat(width) / CGFloat(height)
            } else {
                knownAspectRatio = nil
            }

            if displayedSourceURLs.indices.contains(index),
               displayedSourceURLs[index] == sourceURL,
               imageNodes[index].image != nil {
                continue
            }
            if displayedSourceURLs.indices.contains(index) {
                displayedSourceURLs[index] = sourceURL
            }

            if let cached = MediaCache.shared.bubbleImage(
                for: item.source,
                maxPixelWidth: maxPixelWidth,
                maxPixelHeight: maxPixelHeight
            ) {
                applyImage(cached.image, at: index, expectedSourceURL: sourceURL)
                continue
            }

            Task { [weak self] in
                guard let self,
                      let bubbleImage = await MediaCache.shared.loadBubbleImage(
                        source: item.source,
                        maxPixelWidth: maxPixelWidth,
                        maxPixelHeight: maxPixelHeight,
                        knownAspectRatio: knownAspectRatio
                      ) else { return }
                await MainActor.run { [weak self] in
                    self?.applyImage(
                        bubbleImage.image,
                        at: index,
                        expectedSourceURL: sourceURL
                    )
                }
            }
        }

        if visibleItemCount < imageNodes.count {
            for index in visibleItemCount..<imageNodes.count {
                displayedSourceURLs[index] = nil
            }
        }
    }

    private func applyImage(_ image: UIImage, at index: Int, expectedSourceURL: String) {
        guard imageNodes.indices.contains(index),
              mediaItems.indices.contains(index),
              mediaItems[index].source.url() == expectedSourceURL else { return }
        let imageNode = imageNodes[index]
        imageNode.image = image
        imageNode.setNeedsDisplay()
        mediaContainerNode.setNeedsLayout()
        setNeedsLayout()
    }
}
