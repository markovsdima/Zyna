//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

private final class ContextMenuSelectionNode: ASDisplayNode {

    private let shapeLayer = CAShapeLayer()

    var radius: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    var roundedCorners: UIRectCorner = .allCorners {
        didSet { setNeedsLayout() }
    }

    var isHighlightedSelection: Bool = false {
        didSet {
            if oldValue != isHighlightedSelection {
                alpha = isHighlightedSelection ? 1 : 0
            }
        }
    }

    override init() {
        super.init()
        isOpaque = false
        alpha = 0
        isUserInteractionEnabled = false
    }

    override func didLoad() {
        super.didLoad()
        shapeLayer.fillColor = UIColor.white.withAlphaComponent(0.10).cgColor
        shapeLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        shapeLayer.lineWidth = 2
        shapeLayer.shadowColor = UIColor.black.withAlphaComponent(0.28).cgColor
        shapeLayer.shadowOpacity = 1
        shapeLayer.shadowRadius = 8
        shapeLayer.shadowOffset = .zero
        view.layer.addSublayer(shapeLayer)
    }

    override func layout() {
        super.layout()
        guard isNodeLoaded else { return }
        shapeLayer.frame = bounds

        let inset = max(1, shapeLayer.lineWidth / 2)
        let pathBounds = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(
            roundedRect: pathBounds,
            byRoundingCorners: roundedCorners,
            cornerRadii: CGSize(width: max(0, radius - inset), height: max(0, radius - inset))
        )
        shapeLayer.path = path.cgPath
        shapeLayer.shadowPath = path.cgPath
    }
}

final class PhotoGroupMessageCellNode: MessageCellNode {

    var onPhotoTapped: ((Int) -> Void)?

    private var mediaItems: [MediaGroupItem]
    private let mediaContainerNode = ASDisplayNode()
    private let imageNodes: [RoundedImageNode]
    private let selectionNodes: [ContextMenuSelectionNode]
    private let timeBadgeNode = ASDisplayNode()
    private let overflowNode = ASDisplayNode()
    private let overflowTextNode = ASTextNode()
    private let captionNode: ASTextNode?
    private var captionPlacement: CaptionPlacement?
    private var layoutOverride: MediaGroupLayoutOverride?
    private let hasHeader: Bool
    private let mediaLayoutBounds: CGRect
    private let mediaHeight: CGFloat
    private var slotFrames: [CGRect] = []
    private var displayedItemIdentities: [String?]
    private var contextMenuHighlightedIndex: Int?

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
        self.layoutOverride = presentation?.layoutOverride

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
        self.selectionNodes = (0..<PhotoGroupLayout.maxVisibleItems).map { _ in
            let node = ContextMenuSelectionNode()
            node.radius = MessageCellHelpers.mediaBubbleCornerRadius
            return node
        }
        self.displayedItemIdentities = Array(repeating: nil, count: PhotoGroupLayout.maxVisibleItems)

        super.init(message: message, isGroupChat: isGroupChat)

        mediaContainerNode.clipsToBounds = false
        imageNodes.forEach(mediaContainerNode.addSubnode)
        overflowNode.backgroundColor = UIColor.black.withAlphaComponent(0.38)
        overflowNode.cornerRadius = MessageCellHelpers.mediaBubbleCornerRadius
        overflowNode.addSubnode(overflowTextNode)
        mediaContainerNode.addSubnode(overflowNode)
        selectionNodes.forEach(mediaContainerNode.addSubnode)

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
            itemCount: mediaItems.count,
            layoutOverride: layoutOverride
        )

        for (index, imageNode) in imageNodes.enumerated() {
            guard index < slotFrames.count else {
                imageNode.frame = .zero
                imageNode.alpha = 1
                continue
            }
            let previousFrame = imageNode.frame
            imageNode.frame = slotFrames[index]
            imageNode.alpha = 1
            imageNode.roundedCorners = PhotoGroupLayout.roundedCorners(
                for: index,
                itemCount: mediaItems.count,
                hasHeader: hasHeader,
                captionPlacement: captionNode == nil ? nil : captionPlacement
            )
            if imageNode.image != nil, previousFrame != imageNode.frame {
                imageNode.setNeedsDisplay()
            }

            let selectionNode = selectionNodes[index]
            selectionNode.frame = slotFrames[index]
            selectionNode.radius = MessageCellHelpers.mediaBubbleCornerRadius
            selectionNode.roundedCorners = imageNode.roundedCorners
            selectionNode.isHighlightedSelection = contextMenuHighlightedIndex == index
        }

        if slotFrames.count < selectionNodes.count {
            for index in slotFrames.count..<selectionNodes.count {
                selectionNodes[index].frame = .zero
                selectionNodes[index].isHighlightedSelection = false
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

    func contextMenuMediaItem(at point: CGPoint) -> MediaGroupItem? {
        guard let index = mediaIndex(at: point),
              mediaItems.indices.contains(index) else {
            return nil
        }
        // The overflow tile represents multiple hidden items, so it
        // cannot safely map to one specific photo deletion target.
        if mediaItems.count > visibleItemCount, index == visibleItemCount - 1 {
            return nil
        }
        return mediaItems[index]
    }

    func prepareContextMenuSelection(at point: CGPoint) -> MediaGroupItem? {
        let item = contextMenuMediaItem(at: point)
        if let index = mediaIndex(at: point), item != nil {
            contextMenuHighlightedIndex = index
        } else {
            contextMenuHighlightedIndex = nil
        }
        mediaContainerNode.setNeedsLayout()
        setNeedsLayout()
        return item
    }

    func clearContextMenuSelection() {
        guard contextMenuHighlightedIndex != nil else { return }
        contextMenuHighlightedIndex = nil
        mediaContainerNode.setNeedsLayout()
        setNeedsLayout()
    }

    func updateMediaGroupPresentation(_ presentation: MediaGroupPresentation?) {
        guard let presentation,
              presentation.rendersCompositeBubble else { return }

        mediaItems = presentation.items
        captionPlacement = presentation.captionPlacement
        layoutOverride = presentation.layoutOverride
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

    func viewerSourceFrameInWindow(at index: Int) -> CGRect? {
        guard mediaContainerNode.isNodeLoaded else { return nil }
        if index < slotFrames.count {
            return mediaContainerNode.view.convert(slotFrames[index], to: nil)
        }
        guard let overflowFrame = slotFrames.last else { return nil }
        return mediaContainerNode.view.convert(overflowFrame, to: nil)
    }

    var mediaItemCount: Int {
        mediaItems.count
    }

    private func mediaIndex(at point: CGPoint) -> Int? {
        guard mediaContainerNode.isNodeLoaded else { return nil }
        let converted = contextSourceNode.view.convert(point, to: mediaContainerNode.view)
        return slotFrames.firstIndex(where: { $0.contains(converted) })
    }

    func paintSplashTarget(
        for itemMessageId: String,
        frameInScreen overrideFrameInScreen: CGRect? = nil
    ) -> PaintSplashTrigger.SnapshotTarget? {
        guard mediaContainerNode.isNodeLoaded,
              let index = mediaItems.firstIndex(where: { $0.messageId == itemMessageId }),
              index < imageNodes.count,
              index < slotFrames.count
        else {
            return nil
        }

        let sourceView = imageNodes[index].view
        guard sourceView.bounds.width > 0, sourceView.bounds.height > 0 else {
            return nil
        }

        let image = UIGraphicsImageRenderer(bounds: sourceView.bounds).image { ctx in
            sourceView.layer.render(in: ctx.cgContext)
        }
        guard image.cgImage != nil else { return nil }

        return PaintSplashTrigger.SnapshotTarget(
            sourceView: sourceView,
            frameInScreen: overrideFrameInScreen ?? mediaContainerNode.view.convert(
                slotFrames[index],
                to: mediaContainerNode.view.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
            ),
            image: image,
            hideSource: { sourceView.alpha = 0 }
        )
    }

    func imageFrameInScreen(at index: Int) -> CGRect? {
        guard mediaContainerNode.isNodeLoaded,
              index < slotFrames.count
        else {
            return nil
        }
        return mediaContainerNode.view.convert(
            slotFrames[index],
            to: mediaContainerNode.view.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
        )
    }

    func partialReflowPreviewImageData(excluding itemMessageId: String) -> [String: Data] {
        var previews: [String: Data] = [:]

        for (index, item) in mediaItems.enumerated() {
            guard item.messageId != itemMessageId,
                  index < imageNodes.count
            else {
                continue
            }

            if let image = imageNodes[index].image,
               let imageData = image.pngData() {
                previews[item.messageId] = imageData
                continue
            }

            let sourceView = imageNodes[index].view
            guard sourceView.bounds.width > 0, sourceView.bounds.height > 0 else {
                continue
            }

            let image = UIGraphicsImageRenderer(bounds: sourceView.bounds).image { ctx in
                sourceView.layer.render(in: ctx.cgContext)
            }
            if let imageData = image.pngData() {
                previews[item.messageId] = imageData
            }
        }

        return previews
    }

    private func loadImages() {
        let scale = ScreenConstants.scale
        let layoutFrames = PhotoGroupLayout.frames(
            in: mediaLayoutBounds,
            itemCount: mediaItems.count,
            layoutOverride: layoutOverride
        )

        for (index, item) in mediaItems.prefix(visibleItemCount).enumerated() {
            guard layoutFrames.indices.contains(index) else { continue }

            let slotFrame = layoutFrames[index]
            let recipe = bubbleRecipe(for: slotFrame, scale: scale)
            let renderIdentity = renderIdentity(for: item, recipe: recipe)
            let knownAspectRatio: CGFloat?
            if let width = item.width, let height = item.height, height > 0 {
                knownAspectRatio = CGFloat(width) / CGFloat(height)
            } else {
                knownAspectRatio = nil
            }

            if displayedItemIdentities.indices.contains(index),
               displayedItemIdentities[index] == renderIdentity,
               imageNodes[index].image != nil {
                continue
            }
            if displayedItemIdentities.indices.contains(index) {
                displayedItemIdentities[index] = renderIdentity
            }

            if let source = item.source,
               let cached = MediaCache.shared.bubbleImage(
                for: source,
                maxPixelWidth: recipe.maxPixelWidth,
                maxPixelHeight: recipe.maxPixelHeight
               ) {
                applyImage(cached.image, at: index, expectedRenderIdentity: renderIdentity)
                continue
            }

            if let previewImageData = item.previewImageData,
               let previewIdentity = item.previewIdentity {
                if let cached = MediaCache.shared.previewBubbleImage(
                    previewIdentity: previewIdentity,
                    maxPixelWidth: recipe.maxPixelWidth,
                    maxPixelHeight: recipe.maxPixelHeight
                ) {
                    applyImage(cached.image, at: index, expectedRenderIdentity: renderIdentity)
                } else {
                    if imageNodes[index].image == nil,
                       let previewPlaceholder = UIImage(data: previewImageData) {
                        imageNodes[index].image = previewPlaceholder
                    }
                    Task { [weak self] in
                        guard let self,
                              let bubbleImage = await MediaCache.shared.loadPreviewBubbleImage(
                                previewIdentity: previewIdentity,
                                imageData: previewImageData,
                                maxPixelWidth: recipe.maxPixelWidth,
                                maxPixelHeight: recipe.maxPixelHeight
                              ) else { return }
                        await MainActor.run { [weak self] in
                            self?.applyImage(
                                bubbleImage.image,
                                at: index,
                                expectedRenderIdentity: renderIdentity
                            )
                        }
                    }
                }
            }

            guard let source = item.source else { continue }

            Task { [weak self] in
                guard let self,
                      let bubbleImage = await MediaCache.shared.loadBubbleImage(
                        source: source,
                        maxPixelWidth: recipe.maxPixelWidth,
                        maxPixelHeight: recipe.maxPixelHeight,
                        knownAspectRatio: knownAspectRatio
                      ) else { return }
                await MainActor.run { [weak self] in
                    self?.applyImage(
                        bubbleImage.image,
                        at: index,
                        expectedRenderIdentity: renderIdentity
                    )
                }
            }
        }

        if visibleItemCount < imageNodes.count {
            for index in visibleItemCount..<imageNodes.count {
                displayedItemIdentities[index] = nil
            }
        }
    }

    private func bubbleRecipe(for slotFrame: CGRect, scale: CGFloat) -> (maxPixelWidth: Int, maxPixelHeight: Int) {
        (
            maxPixelWidth: max(1, Int(round(slotFrame.width * scale))),
            maxPixelHeight: max(1, Int(round(slotFrame.height * scale)))
        )
    }

    private func renderIdentity(
        for item: MediaGroupItem,
        recipe: (maxPixelWidth: Int, maxPixelHeight: Int)
    ) -> String {
        "\(item.displayIdentity)|\(recipe.maxPixelWidth)x\(recipe.maxPixelHeight)"
    }

    private func applyImage(_ image: UIImage, at index: Int, expectedRenderIdentity: String) {
        guard imageNodes.indices.contains(index),
              displayedItemIdentities.indices.contains(index),
              displayedItemIdentities[index] == expectedRenderIdentity else { return }
        let imageNode = imageNodes[index]
        imageNode.image = image
        imageNode.setNeedsDisplay()
        mediaContainerNode.setNeedsLayout()
        setNeedsLayout()
    }
}
