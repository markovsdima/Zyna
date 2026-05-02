//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class VideoMessageCellNode: MessageCellNode {

    // MARK: - Callbacks

    var onVideoTapped: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard allowsInteractiveActions else { return false }
        onVideoTapped?()
        return true
    }

    // MARK: - Subnodes

    private let thumbnailNode = RoundedImageNode()
    private let placeholderNode = RoundedBackgroundNode()
    private let timeBadgeNode = ASDisplayNode()
    private let durationBadgeNode = ASDisplayNode()
    private let durationNode = ASTextNode()
    private let playBackgroundNode = ASDisplayNode()
    private let playIconNode = ASImageNode()
    private let downloadBadgeNode = ASDisplayNode()
    private let downloadTextNode = ASTextNode()
    private let captionNode: ASTextNode?

    // MARK: - State

    /// Current thumbnail for the viewer transition.
    var currentThumbnail: UIImage? { thumbnailNode.image }

    private var aspectRatio: CGFloat
    private let mediaSource: MediaSource?
    private let thumbnailSource: MediaSource?
    private let previewThumbnailData: Data?
    private let hasSDKDimensions: Bool
    private let usesDirectVideoContent: Bool

    enum DownloadState {
        case idle
        case downloading(progress: Double)
        case downloaded
    }

    private(set) var downloadState: DownloadState = .idle {
        didSet { updateDownloadDisplay() }
    }

    // MARK: - Init

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        var source: MediaSource?
        var thumbSource: MediaSource?
        var videoWidth: UInt64?
        var videoHeight: UInt64?
        var duration: TimeInterval?
        var previewData: Data?
        let captionText = message.content.visibleVideoCaption

        if case .video(let src, let thumbnailSrc, let width, let height, let videoDuration, _, _, _, _, let thumbnailData) = message.content {
            source = src
            thumbSource = thumbnailSrc
            videoWidth = width
            videoHeight = height
            duration = videoDuration
            previewData = thumbnailData
        }

        let usesAccentBubbleStyle = message.isOutgoing || message.zynaAttributes.color != nil
        let captionInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let captionMaxWidth = max(
            1,
            ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
                - captionInsets.left - captionInsets.right
        )

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
            node.style.maxWidth = ASDimension(unit: .points, value: captionMaxWidth)
            node.style.flexShrink = 1
            self.captionNode = node
        } else {
            self.captionNode = nil
        }

        self.mediaSource = source
        self.thumbnailSource = thumbSource
        self.previewThumbnailData = previewData
        if let width = videoWidth, let height = videoHeight, height > 0 {
            self.aspectRatio = CGFloat(width) / CGFloat(height)
            self.hasSDKDimensions = true
        } else {
            self.aspectRatio = 16.0 / 9.0
            self.hasSDKDimensions = false
        }

        let hasHeader = message.replyInfo != nil || message.zynaAttributes.forwardedFrom != nil
        let hasCaption = self.captionNode != nil
        self.usesDirectVideoContent = !hasHeader && !hasCaption

        super.init(message: message, isGroupChat: isGroupChat)

        thumbnailNode.radius = MessageCellHelpers.mediaBubbleCornerRadius
        var thumbnailCorners: UIRectCorner = .allCorners
        if hasHeader {
            thumbnailCorners.remove(.topLeft)
            thumbnailCorners.remove(.topRight)
        }
        if hasCaption {
            thumbnailCorners.remove(.bottomLeft)
            thumbnailCorners.remove(.bottomRight)
        }
        thumbnailNode.roundedCorners = thumbnailCorners
        thumbnailNode.imageContentMode = .scaleAspectFill

        placeholderNode.radius = MessageCellHelpers.mediaBubbleCornerRadius
        placeholderNode.roundedCorners = thumbnailNode.roundedCorners
        placeholderNode.fillColor = UIColor.black.withAlphaComponent(0.18)

        timeBadgeNode.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        timeBadgeNode.cornerRadius = 8
        durationBadgeNode.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        durationBadgeNode.cornerRadius = 8
        playBackgroundNode.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        playBackgroundNode.cornerRadius = 24
        downloadBadgeNode.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        downloadBadgeNode.cornerRadius = 15
        downloadBadgeNode.isHidden = true
        downloadTextNode.isHidden = true

        let playConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        playIconNode.image = UIImage(systemName: "play.fill", withConfiguration: playConfig)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        playIconNode.style.preferredSize = CGSize(width: 22, height: 22)

        if let duration, duration.isFinite, duration > 0 {
            durationNode.attributedText = NSAttributedString(
                string: MediaDurationFormatter.shortString(for: duration),
                attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: UIColor.white
                ]
            )
        }

        timeNode.attributedText = NSAttributedString(
            string: MessageCellHelpers.timeFormatter.string(from: message.timestamp),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.white
            ]
        )
        statusIconNode?.tintColour = .white

        setShowsBubbleChrome(!usesDirectVideoContent)
        setUsesBareBubbleContent(usesDirectVideoContent)

        let buildVideoWithOverlays: () -> ASLayoutSpec = { [weak self] in
            guard let self else { return ASLayoutSpec() }
            return self.buildVideoSurface()
        }

        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            let videoWithOverlays = buildVideoWithOverlays()

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

            let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
            let captionInset = self.captionNode.map {
                let spec = ASInsetLayoutSpec(
                    insets: captionInsets,
                    child: $0
                )
                spec.style.maxWidth = ASDimension(unit: .points, value: maxWidth)
                return spec
            }

            var stackChildren: [ASLayoutElement] = headerChildren
            stackChildren.append(videoWithOverlays)
            if let captionInset {
                stackChildren.append(captionInset)
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

            return videoWithOverlays
        }

        directBubbleContentNode.layoutSpecBlock = { _, _ in
            buildVideoWithOverlays()
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
            self.onVideoTapped?()
        }

        if let previewData,
           let previewImage = UIImage(data: previewData) {
            thumbnailNode.image = previewImage
        }

        // TODO(video): Verify third-party m.video events that arrive without
        // thumbnail/source sizing and tune the placeholder fallback if needed.
        if let source = thumbSource ?? source {
            let recipe = bubbleCacheRecipe()
            if let cached = MediaCache.shared.bubbleImage(
                for: source,
                maxPixelWidth: recipe.maxPixelWidth,
                maxPixelHeight: recipe.maxPixelHeight
            ) {
                thumbnailNode.image = cached.image
                applyLoadedThumbnailPixelSize(cached.sourcePixelSize, relayout: false)
            } else {
                loadBubbleImageAsync(source: source)
            }
        }
    }

    override func didLoad() {
        super.didLoad()
        assignProbeName("videoMessage.thumbnail", to: thumbnailNode)
        assignProbeName("videoMessage.play", to: playBackgroundNode)
        if let captionNode {
            assignProbeName("videoMessage.caption", to: captionNode)
        }
    }

    // MARK: - Progress

    func setDownloadState(_ state: DownloadState) {
        self.downloadState = state
    }

    func viewerSourceFrameInWindow() -> CGRect? {
        guard isNodeLoaded, thumbnailNode.isNodeLoaded else { return nil }
        return thumbnailNode.view.convert(thumbnailNode.bounds, to: nil)
    }

    private func updateDownloadDisplay() {
        switch downloadState {
        case .idle, .downloaded:
            downloadBadgeNode.isHidden = true
            downloadTextNode.isHidden = true
            playBackgroundNode.isHidden = false
            playIconNode.isHidden = false
        case .downloading(let progress):
            let text: String
            if progress >= 0 {
                text = "\(Int((progress * 100).rounded()))%"
            } else {
                text = "Loading"
            }
            downloadTextNode.attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: UIColor.white
                ]
            )
            downloadBadgeNode.isHidden = false
            downloadTextNode.isHidden = false
            playBackgroundNode.isHidden = true
            playIconNode.isHidden = true
        }
        setNeedsLayout()
    }

    // MARK: - Layout

    private func buildVideoSurface() -> ASLayoutSpec {
        let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        let rawHeight = maxWidth / max(0.1, aspectRatio)
        let size = CGSize(
            width: maxWidth,
            height: min(rawHeight, MessageCellHelpers.maxImageBubbleHeight)
        )
        thumbnailNode.style.preferredSize = size

        let thumbnail = ASBackgroundLayoutSpec(
            child: thumbnailNode,
            background: placeholderNode
        )

        let playPadded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 13, left: 15, bottom: 13, right: 13),
            child: playIconNode
        )
        let playBadge = ASBackgroundLayoutSpec(
            child: playPadded,
            background: playBackgroundNode
        )
        let playOverlay = ASCenterLayoutSpec(
            centeringOptions: .XY,
            sizingOptions: .minimumXY,
            child: playBadge
        )
        var surface: ASLayoutSpec = ASOverlayLayoutSpec(
            child: thumbnail,
            overlay: playOverlay
        )

        let downloadPadded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12),
            child: downloadTextNode
        )
        let downloadBadge = ASBackgroundLayoutSpec(
            child: downloadPadded,
            background: downloadBadgeNode
        )
        let downloadOverlay = ASCenterLayoutSpec(
            centeringOptions: .XY,
            sizingOptions: .minimumXY,
            child: downloadBadge
        )
        surface = ASOverlayLayoutSpec(child: surface, overlay: downloadOverlay)

        if durationNode.attributedText?.length ?? 0 > 0 {
            let durationPadded = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6),
                child: durationNode
            )
            let durationBadge = ASBackgroundLayoutSpec(
                child: durationPadded,
                background: durationBadgeNode
            )
            let durationOverlay = ASRelativeLayoutSpec(
                horizontalPosition: .start,
                verticalPosition: .end,
                sizingOption: .minimumSize,
                child: ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 0, left: 8, bottom: 8, right: 0),
                    child: durationBadge
                )
            )
            surface = ASOverlayLayoutSpec(child: surface, overlay: durationOverlay)
        }

        let timeBadgeContent: ASLayoutElement
        if let statusIconNode = statusIconNode {
            timeBadgeContent = ASStackLayoutSpec(
                direction: .horizontal,
                spacing: 4,
                justifyContent: .start,
                alignItems: .center,
                children: [timeNode, statusIconNode]
            )
        } else {
            timeBadgeContent = timeNode
        }

        let timePadded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6),
            child: timeBadgeContent
        )
        let timeBadge = ASBackgroundLayoutSpec(
            child: timePadded,
            background: timeBadgeNode
        )
        let timeOverlay = ASRelativeLayoutSpec(
            horizontalPosition: .end,
            verticalPosition: .end,
            sizingOption: .minimumSize,
            child: ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 8),
                child: timeBadge
            )
        )
        surface = ASOverlayLayoutSpec(child: surface, overlay: timeOverlay)

        return surface
    }

    private func bubbleCacheRecipe() -> (maxPixelWidth: Int, maxPixelHeight: Int) {
        let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        let scale = ScreenConstants.scale
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
                self.thumbnailNode.image = bubbleImage.image
                self.applyLoadedThumbnailPixelSize(bubbleImage.sourcePixelSize, relayout: true)
            }
        }
    }

    private func applyLoadedThumbnailPixelSize(_ sourcePixelSize: CGSize, relayout: Bool) {
        guard !hasSDKDimensions, sourcePixelSize.height > 0 else { return }
        let realRatio = sourcePixelSize.width / sourcePixelSize.height
        guard abs(realRatio - aspectRatio) > 0.01 else { return }
        aspectRatio = realRatio
        if relayout {
            setNeedsLayout()
        }
    }

}
