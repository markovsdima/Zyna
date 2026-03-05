//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class ImageMessageCellNode: ASCellNode {

    // MARK: - Subnodes

    private let bubbleNode = ASDisplayNode()
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

        super.init()

        automaticallyManagesSubnodes = true
        selectionStyle = .none

        // Image
        imageNode.contentMode = .scaleAspectFill
        imageNode.cornerRadius = 18
        imageNode.clipsToBounds = true
        imageNode.displaysAsynchronously = true

        // Bubble
        bubbleNode.backgroundColor = isOutgoing ? .systemBlue : .systemGray5
        bubbleNode.cornerRadius = 18
        bubbleNode.clipsToBounds = true

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
        let maxWidth = ScreenConstants.width * Self.maxBubbleWidthRatio
        let imageHeight = maxWidth / aspectRatio

        imageNode.style.preferredSize = CGSize(width: maxWidth, height: min(imageHeight, 400))

        // Time badge with padding
        let timePadded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6),
            child: timeNode
        )
        let timeBadge = ASBackgroundLayoutSpec(child: timePadded, background: timeBadgeNode)

        // Time overlay at bottom-right
        let timeOverlay = ASRelativeLayoutSpec(
            horizontalPosition: .end,
            verticalPosition: .end,
            sizingOption: .minimumSize,
            child: ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 8),
                child: timeBadge
            )
        )

        let imageWithTime = ASOverlayLayoutSpec(child: imageNode, overlay: timeOverlay)

        // Bubble behind image
        let bubble = ASBackgroundLayoutSpec(child: imageWithTime, background: bubbleNode)

        // Sender name above bubble
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
                children: [nameInset, bubble]
            )
        } else {
            bubbleWithName = bubble
        }

        // Spacer for alignment
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

    // MARK: - Helpers

    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
    }
}
