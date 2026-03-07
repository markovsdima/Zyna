//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class ImageMessageCellNode: ASCellNode, ContextMenuCellNode {

    // MARK: - Context Menu

    var onContextMenuActivated: (() -> Void)?

    var onDragChanged: ((CGPoint) -> Void)? {
        get { contextSourceNode.onDragChanged }
        set { contextSourceNode.onDragChanged = newValue }
    }

    var onDragEnded: ((CGPoint) -> Void)? {
        get { contextSourceNode.onDragEnded }
        set { contextSourceNode.onDragEnded = newValue }
    }

    var onInteractionLockChanged: ((Bool) -> Void)? {
        get { contextSourceNode.onInteractionLockChanged }
        set { contextSourceNode.onInteractionLockChanged = newValue }
    }

    // MARK: - Subnodes

    private let bubbleNode = ASDisplayNode()
    private let contextSourceNode: ContextSourceNode
    private let imageNode = ASImageNode()
    private let timeNode = ASTextNode()
    private let timeBadgeNode = ASDisplayNode()
    private let senderNameNode = ASTextNode()

    // MARK: - State

    private let isOutgoing: Bool
    private let showSenderName: Bool
    private let aspectRatio: CGFloat
    private let mediaSource: MediaSource?

    // MARK: - Constants

    private static let maxBubbleWidthRatio: CGFloat = 0.75
    private static let cellInsets = UIEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let senderColors: [UIColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange,
        .systemPurple, .systemTeal, .systemIndigo, .systemPink
    ]

    // MARK: - Init

    init(message: ChatMessage, isGroupChat: Bool = false) {
        self.isOutgoing = message.isOutgoing
        self.showSenderName = !message.isOutgoing && isGroupChat

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

        self.contextSourceNode = ContextSourceNode(contentNode: bubbleNode)
        super.init()

        contextSourceNode.activated = { [weak self] _ in
            self?.onContextMenuActivated?()
        }

        automaticallyManagesSubnodes = true
        selectionStyle = .none

        // Image
        imageNode.contentMode = .scaleAspectFill
        imageNode.cornerRadius = 18
        imageNode.clipsToBounds = true
        imageNode.displaysAsynchronously = true

        // Bubble — self-contained with all content
        bubbleNode.backgroundColor = isOutgoing ? .systemBlue : .systemGray5
        bubbleNode.cornerRadius = 18
        bubbleNode.clipsToBounds = true
        bubbleNode.automaticallyManagesSubnodes = true
        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            let maxWidth = ScreenConstants.width * Self.maxBubbleWidthRatio
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

            return ASOverlayLayoutSpec(child: self.imageNode, overlay: timeOverlay)
        }

        // Time badge
        timeBadgeNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        timeBadgeNode.cornerRadius = 8

        // Timestamp
        timeNode.attributedText = NSAttributedString(
            string: Self.timeFormatter.string(from: message.timestamp),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.white
            ]
        )

        // Sender name
        if showSenderName, let name = message.senderDisplayName {
            let colorIndex = Self.stableHash(message.senderId) % Self.senderColors.count
            senderNameNode.attributedText = NSAttributedString(
                string: name,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: Self.senderColors[colorIndex]
                ]
            )
        }

        // Load image: cache hit → instant, miss → async
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
        let maxWidth = ScreenConstants.width * Self.maxBubbleWidthRatio
        let thumbWidth = UInt64(maxWidth * UIScreen.main.scale)
        let thumbHeight = UInt64(maxWidth / aspectRatio * UIScreen.main.scale)

        Task {
            guard let image = await MediaCache.shared.loadThumbnail(
                source: source,
                width: thumbWidth,
                height: thumbHeight
            ) else { return }
            await MainActor.run {
                self.imageNode.image = image
            }
        }
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let bubbleWithName: ASLayoutElement
        if showSenderName {
            let nameInset = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 0, left: 12, bottom: 2, right: 0),
                child: senderNameNode
            )
            bubbleWithName = ASStackLayoutSpec(
                direction: .vertical,
                spacing: 0,
                justifyContent: .start,
                alignItems: .start,
                children: [nameInset, contextSourceNode]
            )
        } else {
            bubbleWithName = contextSourceNode
        }

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        let hStack = ASStackLayoutSpec.horizontal()
        hStack.spacing = 4
        hStack.alignItems = .start
        hStack.children = isOutgoing
            ? [spacer, bubbleWithName]
            : [bubbleWithName, spacer]

        return ASInsetLayoutSpec(insets: Self.cellInsets, child: hStack)
    }

    // MARK: - Context Menu Reparenting

    func extractBubbleForMenu(in coordinateSpace: UICoordinateSpace) -> (node: ASDisplayNode, frame: CGRect)? {
        guard isNodeLoaded else { return nil }
        return contextSourceNode.extractContentForMenu(in: coordinateSpace)
    }

    func restoreBubbleFromMenu() {
        contextSourceNode.restoreContentFromMenu()
    }

    // MARK: - Helpers

    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
    }
}
